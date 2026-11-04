import Foundation
import SQLite3

struct DrugDatasetInfo: Codable, Identifiable, Sendable {
    let id: UUID
    let fileName: String
    let labelCount: Int
    let source: String
    let sourceURL: String?
    let exportDate: String?
    let importedAt: Date
    let originalFiles: [String]
    let importNote: String?
}

struct DrugLabelSummary: Identifiable, Sendable {
    let id: Int64
    let brand: String
    let generic: String
    let manufacturer: String
    let productType: String
    let labelCount: Int
    var title: String { brand.isEmpty ? (generic.isEmpty ? "Label \(id)" : generic) : brand }
}

struct DrugLabelDetail: Identifiable, Sendable {
    let id: Int64
    let fields: [String: String]
    var title: String {
        [fields["brand_name"], fields["generic_name"], fields["set_id"]]
            .compactMap { $0 }.first { !$0.isEmpty } ?? "Drug label"
    }
    static let sections: [(key: String, title: String)] = [
        ("boxed_warning", "Boxed warning"), ("indications", "Indications and usage"),
        ("dosage", "Dosage and administration"), ("warnings", "Warnings"),
        ("contraindications", "Contraindications"), ("drug_interactions", "Drug interactions — label text"),
        ("when_using", "When using this product"), ("stop_use", "Stop use")
    ]
}

struct DrugCondition: Identifiable, Sendable {
    let id: String
    let label: String
    let category: String
    let searchTerms: [String]
}

enum DrugReferenceError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

private final class DrugQueryDeadline {
    let ends = Date().addingTimeInterval(30)
    let progress: (@Sendable () -> Void)?
    init(progress: (@Sendable () -> Void)?) { self.progress = progress }
}

/// SQLite connections never leave the repository actor or an individual import.
private final class DrugSQLite {
    var handle: OpaquePointer?
    static let columns = ["set_id", "spl_id", "version", "brand_name", "generic_name", "manufacturer",
        "product_ndc", "route", "product_type", "searchable_name", "indications", "dosage", "warnings",
        "boxed_warning", "drug_interactions", "contraindications", "when_using", "stop_use", "source_updated_at"]

    init(url: URL, writable: Bool = false) throws {
        let flags = (writable ? SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE : SQLITE_OPEN_READONLY) | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "The database could not be opened."
            if let handle { sqlite3_close(handle) }
            handle = nil
            throw DrugReferenceError.message(message)
        }
        sqlite3_busy_timeout(handle, 5000)
        sqlite3_limit(handle, SQLITE_LIMIT_LENGTH, 32 * 1024 * 1024)
        do {
            try execute("PRAGMA trusted_schema=OFF;")
            if !writable { try execute("PRAGMA query_only=ON;") }
        } catch { sqlite3_close(handle); handle = nil; throw error }
    }

    deinit { if let handle { sqlite3_close(handle) } }

    func close() throws {
        guard let handle else { return }
        guard sqlite3_close(handle) == SQLITE_OK else { throw failure() }
        self.handle = nil
    }

    func failure() -> DrugReferenceError {
        .message(handle.map { String(cString: sqlite3_errmsg($0)) } ?? "The database is closed.")
    }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }

    func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        return statement
    }

    func bind(_ values: [String?], to statement: OpaquePointer) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            let status: Int32
            if let value {
                guard value.utf8.count <= Int(Int32.max) else { throw DrugReferenceError.message("The text value is too large for SQLite.") }
                status = value.withCString { sqlite3_bind_text(statement, Int32(index + 1), $0, Int32(value.utf8.count), transient) }
            } else { status = sqlite3_bind_null(statement, Int32(index + 1)) }
            guard status == SQLITE_OK else { throw failure() }
        }
    }

    func rows(_ sql: String, values: [String?] = [], maximum: Int = 200, progress: (@Sendable () -> Void)? = nil) throws -> [[String: String]] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement)
        let deadline = Unmanaged.passRetained(DrugQueryDeadline(progress: progress))
        sqlite3_progress_handler(handle, 10_000, { pointer in
            guard let pointer else { return 0 }
            let context = Unmanaged<DrugQueryDeadline>.fromOpaque(pointer).takeUnretainedValue()
            context.progress?()
            return Task<Never, Never>.isCancelled || Date() > context.ends ? 1 : 0
        }, deadline.toOpaque())
        defer { sqlite3_progress_handler(handle, 0, nil, nil); deadline.release() }
        var result: [[String: String]] = []
        while true {
            try Task.checkCancellation()
            let status = sqlite3_step(statement)
            try Task.checkCancellation()
            if status == SQLITE_DONE { break }
            if status == SQLITE_INTERRUPT { throw DrugReferenceError.message("The query took too long. Try a more specific drug name or use name search.") }
            guard status == SQLITE_ROW else { throw failure() }
            var row: [String: String] = [:]
            for column in 0..<sqlite3_column_count(statement) {
                guard let name = sqlite3_column_name(statement, column), let bytes = sqlite3_column_text(statement, column) else { continue }
                row[String(cString: name)] = String(decoding: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(statement, column))), as: UTF8.self)
            }
            result.append(row)
            if result.count >= maximum { break }
        }
        return result
    }

    func validate() throws -> Int {
        let table = try rows("SELECT type, sql FROM sqlite_master WHERE name='drug_labels'", maximum: 1).first
        guard table?["type"] == "table", !(table?["sql"]?.uppercased().contains("VIRTUAL TABLE") ?? true) else {
            throw DrugReferenceError.message("A regular drug_labels table is required. Views and virtual tables are not accepted as the source table.")
        }
        let schema = try rows("PRAGMA table_info(drug_labels)")
        let names = Set(schema.compactMap { $0["name"] })
        let required = Set(Self.columns + ["id"])
        let primaryColumns = schema.filter { ($0["pk"] ?? "0") != "0" }
        guard required.isSubset(of: names), primaryColumns.count == 1, primaryColumns.first?["name"] == "id" else {
            throw DrugReferenceError.message("The SQLite file does not have the NOMAD drug_labels schema. Missing columns: \(required.subtracting(names).sorted().joined(separator: ", ")). The id column must be the primary key.")
        }
        guard try rows("PRAGMA quick_check(1)", maximum: 1).first?.values.first == "ok" else {
            throw DrugReferenceError.message("SQLite reported a damaged database. Your existing reference has not been replaced.")
        }
        guard let countText = try rows("SELECT COUNT(*) AS total FROM drug_labels", maximum: 1).first?["total"],
              let count = Int(countText), count > 0 else {
            throw DrugReferenceError.message("The database contains no drug labels.")
        }
        let invalid = try rows("SELECT id FROM drug_labels WHERE typeof(id) != 'integer' OR set_id IS NULL OR length(trim(set_id))=0 LIMIT 1", maximum: 1)
        guard invalid.isEmpty else { throw DrugReferenceError.message("The database contains labels with invalid identifiers.") }
        return count
    }

    func metadata() throws -> [String: String] {
        guard try rows("SELECT name FROM sqlite_master WHERE type='table' AND name='dataset_metadata'", maximum: 1).first != nil else { return [:] }
        return Dictionary(try rows("SELECT key, value FROM dataset_metadata LIMIT 100", maximum: 100)
            .compactMap { row -> (String, String)? in
                guard let key = row["key"], let value = row["value"] else { return nil }
                return (key, value)
            }, uniquingKeysWith: { _, last in last })
    }

    static func create(at url: URL) throws -> DrugSQLite {
        let db = try DrugSQLite(url: url, writable: true)
        let definitions = columns.map { $0 == "set_id" ? "set_id TEXT NOT NULL COLLATE NOCASE UNIQUE" : "\($0) TEXT" }.joined(separator: ",")
        try db.execute("PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL; CREATE TABLE drug_labels (id INTEGER PRIMARY KEY, \(definitions)); CREATE TABLE dataset_metadata (key TEXT PRIMARY KEY, value TEXT);")
        return db
    }
}

/// Operates only on immutable, locally owned database snapshots after import.
actor DrugReferenceRepository {
    private let storageRoot: URL?
    private let queryProgress: (@Sendable () -> Void)?

    /// An explicit root lets engine tests use an isolated temporary directory.
    init(storageRoot: URL? = nil, queryProgress: (@Sendable () -> Void)? = nil) {
        self.storageRoot = storageRoot; self.queryProgress = queryProgress
    }

    private func directory() throws -> URL {
        if let storageRoot {
            try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
            return storageRoot
        }
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return try CollectionStorageDirectory.directory(in: base, components: ["NOMAD", "Reference"])
    }

    private func file(_ name: String) throws -> URL {
        guard !name.isEmpty, !name.contains("/"), !name.contains("\\"), name != ".", name != ".." else {
            throw DrugReferenceError.message("Invalid stored database filename.")
        }
        return try directory().appendingPathComponent(name)
    }

    private func databaseURL(for info: DrugDatasetInfo) throws -> URL {
        guard info.fileName == "labels-\(info.id.uuidString).sqlite", info.labelCount > 0 else {
            throw DrugReferenceError.message("The saved dataset metadata is invalid.")
        }
        let url = try file(info.fileName)
        if FileManager.default.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw DrugReferenceError.message("The stored database must be a regular file inside NOMAD's storage.")
            }
        }
        return url
    }

    func current() throws -> DrugDatasetInfo? {
        let manifest = try file("dataset.json")
        guard FileManager.default.fileExists(atPath: manifest.path) else { return nil }
        let info = try JSONDecoder().decode(DrugDatasetInfo.self, from: Data(contentsOf: manifest))
        guard FileManager.default.fileExists(atPath: try databaseURL(for: info).path) else {
            throw DrugReferenceError.message("The installed database file is missing. Import a new dataset to restore the reference.")
        }
        return info
    }

    func prepareImport(_ sources: [URL]) throws -> DrugDatasetInfo {
        guard !sources.isEmpty else { throw DrugReferenceError.message("Choose at least one dataset file.") }
        let id = UUID()
        let name = "labels-\(id.uuidString).sqlite"
        let destination = try file(name)
        do {
            let isDatabase = sources.count == 1 && ["sqlite", "sqlite3", "db"].contains(sources[0].pathExtension.lowercased())
            var note: String?
            if isDatabase {
                try withSelectedFile(sources[0]) { url in try snapshot(url, to: destination) }
                note = "Imported SQLite snapshot; declared provenance is supplied by the file and has not been independently verified."
            } else {
                guard sources.allSatisfy({ $0.pathExtension.lowercased() == "json" }) else {
                    throw DrugReferenceError.message("Select extracted openFDA drug-label .json parts together, or one compatible .sqlite/.sqlite3/.db file. Unzip official .json.zip downloads in Files first.")
                }
                let skipped = try ingestJSON(sources, at: destination)
                note = "Imported \(sources.count) JSON file(s). \(skipped) records without a usable set_id were skipped. This may be only part of the full FDA dataset."
            }
            let database = try DrugSQLite(url: destination)
            let count = try database.validate()
            let meta = try database.metadata()
            return DrugDatasetInfo(id: id, fileName: name, labelCount: count,
                source: meta["source"] ?? "User-supplied SQLite drug_labels dataset",
                sourceURL: meta["source_url"], exportDate: meta["export_date"], importedAt: Date(),
                originalFiles: sources.map(\.lastPathComponent), importNote: note)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.removeItem(atPath: destination.path + "-journal")
            throw error
        }
    }

    func activate(_ info: DrugDatasetInfo) throws -> String? {
        let preparedURL = try databaseURL(for: info)
        guard FileManager.default.fileExists(atPath: preparedURL.path) else { throw DrugReferenceError.message("The prepared database is no longer available.") }
        let check = try DrugSQLite(url: preparedURL)
        guard try check.validate() == info.labelCount else {
            throw DrugReferenceError.message("The prepared dataset has changed since import. Import it again; the current reference was kept.")
        }
        var previous: DrugDatasetInfo?
        var recoveryNotice: String?
        do { previous = try current() }
        catch { recoveryNotice = "The previous installation's metadata could not be read. The newly confirmed dataset is active; older unreferenced files were preserved." }
        try JSONEncoder().encode(info).write(to: file("dataset.json"), options: .atomic)
        if let previous, previous.fileName != info.fileName {
            do { try FileManager.default.removeItem(at: file(previous.fileName)) }
            catch { return "The new reference is active, but the previous database could not be removed: \(error.localizedDescription)" }
        }
        return recoveryNotice
    }

    func discard(_ info: DrugDatasetInfo) throws {
        guard (try? current())?.fileName != info.fileName else { return }
        let url = try databaseURL(for: info)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    func uninstall() throws {
        guard let info = try current() else { return }
        try FileManager.default.removeItem(at: file("dataset.json"))
        do { try FileManager.default.removeItem(at: file(info.fileName)) }
        catch {
            try JSONEncoder().encode(info).write(to: file("dataset.json"), options: .atomic)
            throw error
        }
    }

    func searchSituations(_ selection: DrugSituationSelection) throws -> [DrugLabelSummary] {
        let groups = try selection.termGroups()
        guard !groups.isEmpty else { return [] }
        return try search("", indications: true, otcOnly: true, termGroups: groups)
    }

    func search(_ query: String, indications: Bool, otcOnly: Bool, terms: [String] = [], termGroups: [[String]] = []) throws -> [DrugLabelSummary] {
        try Task.checkCancellation()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard termGroups.isEmpty || (terms.isEmpty && trimmed.isEmpty && indications) else { throw DrugReferenceError.message("Situation groups require an indications search without a separate query.") }
        let requested = termGroups.isEmpty ? (terms.isEmpty ? (trimmed.isEmpty ? [] : [[trimmed]]) : [terms]) : termGroups
        let groups = try DrugSituationSelection.normalized(requested)
        guard !groups.isEmpty, let info = try current() else { return [] }
        let db = try DrugSQLite(url: file(info.fileName))
        let column = indications ? "indications" : "COALESCE(searchable_name,'') || ' ' || COALESCE(brand_name,'') || ' ' || COALESCE(generic_name,'')"
        // Every group must match the SAME label before brand/generic grouping or LIMIT.
        // Synonyms within one group remain OR alternatives, as in upstream's LIKE fallback.
        let clauses = groups.map { group in "(" + group.map { _ in "(\(column)) LIKE ? ESCAPE '\\'" }.joined(separator: " OR ") + ")" }.joined(separator: " AND ")
        var values: [String?] = groups.flatMap { $0 }.map { "%" + $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%" }
        var grouped = "SELECT MIN(id) AS id, COUNT(*) AS label_count FROM drug_labels WHERE (\(clauses))"
        if otcOnly { grouped += " AND product_type=?"; values.append("HUMAN OTC DRUG") }
        grouped += " GROUP BY brand_name,generic_name"
        let sql = "SELECT d.id,d.brand_name,d.generic_name,d.manufacturer,d.product_type,g.label_count FROM drug_labels AS d JOIN (\(grouped)) AS g ON d.id=g.id ORDER BY COALESCE(d.brand_name,d.generic_name) COLLATE NOCASE,d.generic_name COLLATE NOCASE,d.id LIMIT 100"
        return try db.rows(sql, values: values, maximum: 100, progress: queryProgress).compactMap { row in
            guard let id = Int64(row["id"] ?? "") else { return nil }
            return DrugLabelSummary(id: id, brand: row["brand_name"] ?? "", generic: row["generic_name"] ?? "",
                manufacturer: row["manufacturer"] ?? "", productType: row["product_type"] ?? "", labelCount: Int(row["label_count"] ?? "1") ?? 1)
        }
    }

    func detail(id: Int64) throws -> DrugLabelDetail {
        guard let info = try current() else { throw DrugReferenceError.message("Import a dataset first.") }
        let db = try DrugSQLite(url: file(info.fileName))
        guard let row = try db.rows("SELECT * FROM drug_labels WHERE id=? LIMIT 1", values: [String(id)], maximum: 1).first else {
            throw DrugReferenceError.message("This label is no longer in the installed dataset.")
        }
        return DrugLabelDetail(id: id, fields: row)
    }

    private func withSelectedFile<T>(_ source: URL, operation: (URL) throws -> T) throws -> T {
        guard source.isFileURL else { throw DrugReferenceError.message("Choose a local file from Files.") }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        var result: Result<T, Error>?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { url in
            result = Result {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw DrugReferenceError.message("Select a regular JSON or SQLite file, not a folder or symbolic link.")
                }
                return try operation(url)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw DrugReferenceError.message("The selected file could not be read.") }
        return try result.get()
    }

    private func snapshot(_ source: URL, to destination: URL) throws {
        try copySQLiteSnapshot(source, to: destination)
        // Reopen after the backup handle closes: its cached empty-database
        // journal mode may differ from the copied WAL header.
        let normalized = try DrugSQLite(url: destination, writable: true)
        try normalized.execute("PRAGMA journal_mode=DELETE;")
        try normalized.close()
        // Apple SQLite may retain a stale SHM file after leaving WAL mode.
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: destination.path + suffix)
            if FileManager.default.fileExists(atPath: sidecar.path) { try FileManager.default.removeItem(at: sidecar) }
        }
    }

    private func copySQLiteSnapshot(_ source: URL, to destination: URL) throws {
        let input = try DrugSQLite(url: source)
        _ = try input.validate()
        let output = try DrugSQLite(url: destination, writable: true)
        guard let backup = sqlite3_backup_init(output.handle, "main", input.handle, "main") else { throw output.failure() }
        var finished = false
        defer { if !finished { sqlite3_backup_finish(backup) } }
        while true {
            try Task.checkCancellation()
            let status = sqlite3_backup_step(backup, 1280)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_OK else { throw output.failure() }
        }
        let result = sqlite3_backup_finish(backup)
        finished = true
        guard result == SQLITE_OK else { throw output.failure() }
    }

    private func ingestJSON(_ sources: [URL], at destination: URL) throws -> Int {
        let db = try DrugSQLite.create(at: destination)
        let columns = DrugSQLite.columns
        let fields = columns.joined(separator: ",")
        let marks = columns.map { _ in "?" }.joined(separator: ",")
        let changes = columns.filter { $0 != "set_id" }.map { "\($0)=excluded.\($0)" }.joined(separator: ",")
        let statement = try db.prepare("INSERT INTO drug_labels (\(fields)) VALUES (\(marks)) ON CONFLICT(set_id) DO UPDATE SET \(changes)")
        defer { sqlite3_finalize(statement) }
        var skipped = 0
        var total = 0
        var dates = Set<String>()
        try db.execute("BEGIN IMMEDIATE;")
        do {
            for source in sources {
                try Task.checkCancellation()
                let metadata = try withSelectedFile(source) { url in
                    let reader = try OpenFDALabelStream(url: url)
                    return try reader.read { record in
                        if total.isMultiple(of: 100) { try Task.checkCancellation() }
                        guard let setID = (record["set_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !setID.isEmpty, setID.count <= 64 else { skipped += 1; return }
                        let fda = record["openfda"] as? [String: Any] ?? [:]
                        func list(_ key: String) -> [String] { fda[key] as? [String] ?? [] }
                        func section(_ key: String) -> String? {
                            let value = (record[key] as? [String])?.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
                            return value?.isEmpty == false ? value : nil
                        }
                        let brand = list("brand_name").first
                        let generic = list("generic_name").joined(separator: ", ")
                        let normalized = ((brand ?? "") + " " + generic).lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
                        let effective = record["effective_time"] as? String ?? ""
                        let year = Int(effective.prefix(4)) ?? 0
                        let month = Int(effective.dropFirst(4).prefix(2)) ?? 0
                        let day = Int(effective.suffix(2)) ?? 0
                        let date: String? = effective.count == 8 && effective.allSatisfy(\.isNumber)
                            && (1900...2100).contains(year) && (1...12).contains(month) && (1...31).contains(day)
                            ? "\(effective.prefix(4))-\(effective.dropFirst(4).prefix(2))-\(effective.suffix(2))" : nil
                        let values: [String?] = [setID, record["id"] as? String, record["version"] as? String,
                            brand, generic, list("manufacturer_name").first, list("product_ndc").joined(separator: ", "),
                            list("route").joined(separator: ", "), list("product_type").first, normalized,
                            section("indications_and_usage"), section("dosage_and_administration"), section("warnings"),
                            section("boxed_warning"), section("drug_interactions"), section("contraindications"),
                            section("when_using"), section("stop_use"), date]
                        sqlite3_reset(statement)
                        sqlite3_clear_bindings(statement)
                        try db.bind(values, to: statement)
                        guard sqlite3_step(statement) == SQLITE_DONE else { throw db.failure() }
                        total += 1
                    }
                }
                if let date = metadata["last_updated"] as? String { dates.insert(date) }
            }
            guard total > 0 else { throw DrugReferenceError.message("No usable openFDA drug-label records were found in the selected JSON.") }
            let metadata = ["source": "openFDA drug labeling (user-selected JSON)",
                "source_url": "https://open.fda.gov/apis/drug/label/", "export_date": dates.sorted().joined(separator: ", "),
                "imported_at": ISO8601DateFormatter().string(from: Date())]
            for (key, value) in metadata {
                let insert = try db.prepare("INSERT INTO dataset_metadata (key,value) VALUES (?,?)")
                do {
                    try db.bind([key, value], to: insert)
                    guard sqlite3_step(insert) == SQLITE_DONE else { throw db.failure() }
                    sqlite3_finalize(insert)
                } catch { sqlite3_finalize(insert); throw error }
            }
            try db.execute("CREATE INDEX idx_drug_labels_searchable_name ON drug_labels(searchable_name); CREATE INDEX idx_drug_labels_product_type ON drug_labels(product_type); COMMIT;")
        } catch { try? db.execute("ROLLBACK;"); throw error }
        return skipped
    }
}

/// Streams the official {meta:..., results:[...]} envelope, holding one label at a time.
private final class OpenFDALabelStream {
    private let stream: InputStream
    private var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    private var offset = 0
    private var available = 0
    private var pushed: UInt8?

    init(url: URL) throws {
        guard let stream = InputStream(url: url) else { throw DrugReferenceError.message("The JSON file could not be opened.") }
        self.stream = stream
        stream.open()
    }
    deinit { stream.close() }

    private func byte() throws -> UInt8? {
        if let value = pushed { pushed = nil; return value }
        if offset == available {
            available = stream.read(&buffer, maxLength: buffer.count)
            offset = 0
            if available < 0 { throw stream.streamError ?? DrugReferenceError.message("Reading the JSON failed.") }
            if available == 0 { return nil }
        }
        defer { offset += 1 }
        return buffer[offset]
    }

    private func next() throws -> UInt8? {
        while let value = try byte() { if ![9, 10, 13, 32].contains(value) { return value } }
        return nil
    }

    private func expect(_ expected: UInt8) throws {
        guard try next() == expected else { throw DrugReferenceError.message("The openFDA JSON is incomplete or has an unexpected structure.") }
    }

    private func value(maximum: Int = 32 * 1024 * 1024) throws -> Data {
        guard let first = try next() else { throw DrugReferenceError.message("The JSON ends unexpectedly.") }
        var data = Data([first])
        var depth = (first == 123 || first == 91) ? 1 : 0
        var quoted = first == 34
        var escaped = false
        if depth == 0 && !quoted {
            while let b = try byte() {
                if [9, 10, 13, 32, 44, 93, 125].contains(b) { pushed = b; break }
                data.append(b)
                guard data.count <= maximum else { throw DrugReferenceError.message("A JSON value exceeds the supported size.") }
            }
            return data
        }
        while let b = try byte() {
            data.append(b)
            guard data.count <= maximum else { throw DrugReferenceError.message("A single label exceeds the 32 MB import limit. No existing data was replaced.") }
            if quoted {
                if escaped { escaped = false }
                else if b == 92 { escaped = true }
                else if b == 34 { quoted = false; if depth == 0 { return data } }
            } else if b == 34 { quoted = true }
            else if b == 123 || b == 91 { depth += 1 }
            else if b == 125 || b == 93 { depth -= 1; if depth == 0 { return data } }
            guard depth <= 64 else { throw DrugReferenceError.message("The JSON nesting exceeds the supported limit.") }
        }
        throw DrugReferenceError.message("The JSON file is truncated. No existing data was replaced.")
    }

    func read(record: ([String: Any]) throws -> Void) throws -> [String: Any] {
        try expect(123)
        var metadata: [String: Any] = [:]
        var sawResults = false
        while true {
            guard let key = try JSONSerialization.jsonObject(with: value(maximum: 4096), options: [.fragmentsAllowed]) as? String else {
                throw DrugReferenceError.message("The JSON must contain an openFDA results array.")
            }
            try expect(58)
            if key == "results" {
                guard !sawResults else { throw DrugReferenceError.message("The JSON contains duplicate results arrays.") }
                sawResults = true
                try expect(91)
                let first = try next()
                if first != 93 {
                    pushed = first
                    while true {
                        try autoreleasepool {
                            // Parsing and normalization bridge through Foundation objects.
                            // Release each label after SQLite has copied its bound values,
                            // rather than retaining every record until the part finishes.
                            guard let object = try JSONSerialization.jsonObject(with: value()) as? [String: Any] else {
                                throw DrugReferenceError.message("Each results entry must be an openFDA drug label object.")
                            }
                            try record(object)
                        }
                        let separator = try next()
                        if separator == 93 { break }
                        guard separator == 44 else { throw DrugReferenceError.message("The results array is malformed or incomplete.") }
                    }
                }
            } else {
                let data = try value(maximum: 4 * 1024 * 1024)
                let decoded = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
                if key == "meta" { metadata = decoded as? [String: Any] ?? [:] }
            }
            let separator = try next()
            if separator == 125 { break }
            guard separator == 44 else { throw DrugReferenceError.message("The JSON envelope is malformed or incomplete.") }
        }
        guard sawResults, try next() == nil else { throw DrugReferenceError.message("Expected one complete openFDA drug-label JSON document.") }
        return metadata
    }
}
