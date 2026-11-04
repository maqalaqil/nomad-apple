import Foundation
import SQLite3
import CryptoKit

/// Reads the real Kolibri exported content schema. Original metadata databases are retained.
/// Schema reference: learningequality/kolibri da32925bce3cd216c4c5c0ecb7429314926f50c5,
/// kolibri/core/content/contentschema/columns/content_columns_6.py and utils/paths.py.
private final class CourseSQLite {
    var handle: OpaquePointer?
    init(_ url: URL, writable: Bool = false) throws {
        let flags = writable ? SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE : SQLITE_OPEN_READONLY
        guard sqlite3_open_v2(url.path, &handle, flags | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let handle { sqlite3_close(handle) }; handle = nil
            throw CourseError.invalid("The channel SQLite database could not be opened.")
        }
        sqlite3_busy_timeout(handle, 2_000)
        sqlite3_limit(handle, SQLITE_LIMIT_LENGTH, 16 * 1_024 * 1_024)
        do { try execute("PRAGMA trusted_schema=OFF;" + (writable ? "" : "PRAGMA query_only=ON;")) }
        catch { sqlite3_close(handle); handle = nil; throw error }
    }
    deinit { if let handle { sqlite3_close(handle) } }
    func close() throws {
        guard let handle else { return }
        guard sqlite3_close(handle) == SQLITE_OK else { throw CourseError.invalid("The channel database is still in use.") }
        self.handle = nil
    }
    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw CourseError.invalid("The channel database is damaged or uses an unsupported schema.") }
    }
    func rows(_ sql: String, maximum: Int = 100_000) throws -> [[String: String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw CourseError.invalid("A required channel metadata column is missing or unreadable.") }
        defer { sqlite3_finalize(statement) }
        let deadline = UnsafeMutablePointer<Double>.allocate(capacity: 1)
        deadline.initialize(to: Date.timeIntervalSinceReferenceDate + 15)
        sqlite3_progress_handler(handle, 10_000, { context in
            guard let context else { return 1 }
            return Date.timeIntervalSinceReferenceDate > context.assumingMemoryBound(to: Double.self).pointee ? 1 : 0
        }, deadline)
        defer { sqlite3_progress_handler(handle, 0, nil, nil); deadline.deinitialize(count: 1); deadline.deallocate() }
        var result: [[String: String]] = [], decodedBytes = 0
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            try Task.checkCancellation()
            guard result.count < maximum else { throw CourseError.invalid("This channel exceeds the native importer’s metadata size limit.") }
            var row: [String: String] = [:]
            for column in 0..<sqlite3_column_count(statement) {
                if let name = sqlite3_column_name(statement, column), let value = sqlite3_column_text(statement, column) {
                    let count = Int(sqlite3_column_bytes(statement, column))
                    guard count <= 256 * 1_024, count <= 64 * 1_024 * 1_024 - decodedBytes else { throw CourseError.invalid("The channel metadata exceeds the native reader’s memory limit.") }
                    decodedBytes += count
                    row[String(cString: name)] = String(decoding: UnsafeBufferPointer(start: value, count: count), as: UTF8.self)
                }
            }
            result.append(row); status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw CourseError.invalid("The channel database is damaged or its query exceeded the time limit.") }
        return result
    }
    func validateTable(_ name: String, required: Set<String>) throws {
        // Names are constants in this source, never values supplied by a package.
        let row = try rows("SELECT type,sql FROM sqlite_master WHERE name='\(name)'", maximum: 1).first
        guard row?["type"] == "table", !(row?["sql"]?.uppercased().contains("VIRTUAL TABLE") ?? true) else {
            throw CourseError.invalid("A regular \(name) table is required; views and virtual tables are not imported.")
        }
        let names = Set(try rows("PRAGMA table_info(\(name))", maximum: 200).compactMap { $0["name"] })
        guard required.isSubset(of: names) else { throw CourseError.invalid("The channel’s \(name) schema is missing required columns.") }
    }
    static func snapshot(_ source: URL, to destination: URL) throws {
        try CoursePaths.regularFile(source)
        guard let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 512 * 1_024 * 1_024 else {
            throw CourseError.invalid("Channel metadata databases must be at most 512 MB. Resource files are copied separately.")
        }
        let input = try CourseSQLite(source), output = try CourseSQLite(destination, writable: true)
        guard let backup = sqlite3_backup_init(output.handle, "main", input.handle, "main") else { throw CourseError.invalid("The channel metadata snapshot could not start.") }
        var finished = false
        defer { if !finished { sqlite3_backup_finish(backup) } }
        while true {
            try Task.checkCancellation()
            let status = sqlite3_backup_step(backup, 1280)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_OK else { throw CourseError.invalid("The channel metadata changed while it was being copied. Close its editor and retry.") }
        }
        let status = sqlite3_backup_finish(backup); finished = true
        guard status == SQLITE_OK else { throw CourseError.invalid("The channel snapshot could not finish.") }
        try output.close()
        let normalized = try CourseSQLite(destination, writable: true)
        try normalized.execute("PRAGMA journal_mode=DELETE;")
        try normalized.close()
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: destination.path + suffix)
            if FileManager.default.fileExists(atPath: sidecar.path) { try FileManager.default.removeItem(at: sidecar) }
        }
    }
}

enum CourseChannelImporter {
    static func prepare(selected: URL, storageRoot: URL = CoursePaths.root) throws -> [StagedCourse] {
        guard selected.isFileURL else { throw CourseError.invalid("Select an exported Kolibri folder in Files.") }
        let scoped = selected.startAccessingSecurityScopedResource()
        defer { if scoped { selected.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var result: Result<[StagedCourse], Error>?
        NSFileCoordinator().coordinate(readingItemAt: selected, options: [], error: &coordinationError) { directory in
            result = Result { try prepareFolder(directory, storageRoot: storageRoot) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CourseError.invalid("The exported folder could not be accessed.") }
        return try result.get()
    }

    private static func prepareFolder(_ selected: URL, storageRoot: URL) throws -> [StagedCourse] {
        let values = try selected.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw CourseError.invalid("Select a regular exported folder, not a symbolic link.") }
        let candidates = [selected, selected.appendingPathComponent("content"), selected.appendingPathComponent("KOLIBRI_DATA")]
        guard let folder = candidates.first(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent("databases").path) && FileManager.default.fileExists(atPath: $0.appendingPathComponent("storage").path) }) else {
            throw CourseError.invalid("Choose KOLIBRI_DATA (or Kolibri’s content folder) containing databases and storage folders.")
        }
        let root = folder.resolvingSymlinksInPath().standardizedFileURL
        guard try folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw CourseError.invalid("The selected content folder contains a symbolic link.") }
        let databases = root.appendingPathComponent("databases")
        guard databases.resolvingSymlinksInPath() == databases else { throw CourseError.invalid("The databases folder may not be a symbolic link.") }
        let urls = try FileManager.default.contentsOfDirectory(at: databases, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
            .filter { $0.pathExtension.lowercased() == "sqlite3" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !urls.isEmpty, urls.count <= 100 else { throw CourseError.invalid("The folder must contain between 1 and 100 exported channel databases.") }
        var staged: [StagedCourse] = []
        do {
            for url in urls {
                try Task.checkCancellation()
                let candidate = try prepareChannel(database: url, sourceRoot: root, storageRoot: storageRoot)
                guard !staged.contains(where: { $0.course.channelID == candidate.course.channelID }) else {
                    try? FileManager.default.removeItem(at: candidate.directory)
                    throw CourseError.invalid("The export contains duplicate channel identifiers.")
                }
                staged.append(candidate)
            }
            return staged
        } catch { staged.forEach { try? FileManager.default.removeItem(at: $0.directory) }; throw error }
    }

    private static func prepareChannel(database source: URL, sourceRoot: URL, storageRoot: URL) throws -> StagedCourse {
        let channelID = source.deletingPathExtension().lastPathComponent
        guard CoursePaths.validID(channelID) else { throw CourseError.invalid("Channel database filenames must be 32-character hexadecimal channel IDs.") }
        let id = UUID(), directory = storageRoot.appendingPathComponent(".import-\(UUID().uuidString)")
        var success = false
        defer { if !success { try? FileManager.default.removeItem(at: directory) } }
        let databases = directory.appendingPathComponent("databases")
        try FileManager.default.createDirectory(at: databases, withIntermediateDirectories: true)
        let snapshot = databases.appendingPathComponent(source.lastPathComponent)
        try CourseSQLite.snapshot(source, to: snapshot)
        let db = try CourseSQLite(snapshot)
        try db.validateTable("content_channelmetadata", required: ["id", "name", "description", "author", "version", "min_schema_version", "root_id"])
        try db.validateTable("content_contentnode", required: ["id", "parent_id", "content_id", "channel_id", "title", "description", "kind", "author", "license_name", "license_owner", "license_description", "sort_order"])
        try db.validateTable("content_file", required: ["contentnode_id", "local_file_id", "preset", "thumbnail", "supplementary", "priority"])
        try db.validateTable("content_localfile", required: ["id", "extension"])
        guard try db.rows("PRAGMA quick_check(1)", maximum: 1).first?.values.first == "ok" else { throw CourseError.invalid("SQLite reported damage in the channel metadata.") }
        let channelRows = try db.rows("SELECT id,name,description,author,version,min_schema_version,root_id FROM content_channelmetadata", maximum: 2)
        guard channelRows.count == 1, let channel = channelRows.first, channel["id"] == channelID,
              let name = channel["name"], !name.isEmpty, let rootID = channel["root_id"], CoursePaths.validID(rootID),
              let version = Int(channel["version"] ?? ""), version >= 0 else { throw CourseError.invalid("The exported channel identity is invalid.") }
        let nodeColumns = Set(try db.rows("PRAGMA table_info(content_contentnode)", maximum: 200).compactMap { $0["name"] })
        let languageColumn = nodeColumns.contains("lang_id") ? "lang_id" : "NULL AS lang_id"
        let nodeRows = try db.rows("SELECT id,parent_id,content_id,channel_id,title,description,kind,author,license_name,license_owner,license_description,sort_order,\(languageColumn) FROM content_contentnode ORDER BY sort_order,id", maximum: 50_000)
        guard !nodeRows.isEmpty else { throw CourseError.invalid("The channel has no topic or resource metadata.") }
        var resourceMap: [String: [CourseResource]] = [:]
        let resourceRows = try db.rows("SELECT f.contentnode_id,f.preset,f.thumbnail,f.supplementary,l.id AS checksum,l.extension FROM content_file f LEFT JOIN content_localfile l ON l.id=f.local_file_id ORDER BY f.priority,f.id", maximum: 100_000)
        var copied: [String: Int64] = [:], missing: Set<String> = []
        for row in resourceRows {
            try Task.checkCancellation()
            guard let nodeID = row["contentnode_id"], CoursePaths.validID(nodeID), let checksum = row["checksum"], CoursePaths.validID(checksum),
                  let ext = row["extension"], CoursePaths.validExtension(ext) else { throw CourseError.invalid("A course resource has an unsafe identifier or file extension.") }
            var resource = CourseResource(checksum: checksum, fileExtension: ext, preset: row["preset"] ?? "", thumbnail: row["thumbnail"] == "1", supplementary: row["supplementary"] == "1", byteCount: 0, available: false)
            let sourceFile = sourceRoot.appendingPathComponent(resource.relativePath)
            let destination = directory.appendingPathComponent(resource.relativePath)
            if copied[resource.filename] == nil && !missing.contains(resource.filename) {
                guard sourceFile.resolvingSymlinksInPath().standardizedFileURL == sourceFile.standardizedFileURL else { throw CourseError.invalid("A course resource path contains a symbolic link.") }
                if FileManager.default.fileExists(atPath: sourceFile.path) {
                    copied[resource.filename] = try copyVerified(sourceFile, to: destination, checksum: checksum)
                } else { missing.insert(resource.filename) }
            }
            resource = CourseResource(checksum: checksum, fileExtension: ext, preset: resource.preset, thumbnail: resource.thumbnail, supplementary: resource.supplementary, byteCount: copied[resource.filename] ?? 0, available: copied[resource.filename] != nil)
            resourceMap[nodeID, default: []].append(resource)
        }
        var assessmentCounts: [String: Int] = [:], assessments: [String: CourseAssessment] = [:]
        if try db.rows("SELECT name FROM sqlite_master WHERE name='content_assessmentmetadata'", maximum: 1).first != nil {
            try db.validateTable("content_assessmentmetadata", required: ["contentnode_id", "number_of_assessments"])
            let assessmentColumns = Set(try db.rows("PRAGMA table_info(content_assessmentmetadata)", maximum: 200).compactMap { $0["name"] })
            let extraColumns = ["assessment_item_ids", "mastery_model", "randomize"].map { assessmentColumns.contains($0) ? $0 : "NULL AS \($0)" }.joined(separator: ",")
            for row in try db.rows("SELECT contentnode_id,number_of_assessments,\(extraColumns) FROM content_assessmentmetadata", maximum: 50_000) {
                if let node = row["contentnode_id"], let count = Int(row["number_of_assessments"] ?? ""), count >= 0 { assessmentCounts[node] = count }
                if let node = row["contentnode_id"], let text = row["assessment_item_ids"], !text.isEmpty {
                    guard let bytes = text.data(using: .utf8), let ids = try? JSONDecoder().decode([String].self, from: bytes), ids.count <= 10_000,
                          Set(ids).count == ids.count, ids.allSatisfy(CoursePaths.validItemID) else { throw CourseError.invalid("The channel contains an unsafe or invalid assessment item catalog.") }
                    assessments[node] = CourseAssessment(itemIDs: ids, masteryModelJSON: row["mastery_model"] ?? "{}", randomize: row["randomize"] == "1")
                }
            }
        }
        var languages: [String: String] = [:]
        if try db.rows("SELECT name FROM sqlite_master WHERE name='content_language'", maximum: 1).first != nil {
            try db.validateTable("content_language", required: ["id", "lang_code", "lang_subcode"])
            for row in try db.rows("SELECT id,lang_code,lang_subcode FROM content_language", maximum: 10_000) {
                if let id = row["id"], let code = row["lang_code"], !code.isEmpty {
                    let subcode = row["lang_subcode"] ?? ""
                    languages[id] = code + (subcode.isEmpty ? "" : "-" + subcode)
                }
            }
        }
        var nodes: [CourseNode] = []
        for row in nodeRows {
            guard let nodeID = row["id"], CoursePaths.validID(nodeID), let contentID = row["content_id"], CoursePaths.validID(contentID), row["channel_id"] == channelID,
                  let title = row["title"], !title.isEmpty, let kind = row["kind"], let order = Double(row["sort_order"] ?? "0"), order.isFinite else {
                throw CourseError.invalid("A channel node has invalid identifiers or metadata.")
            }
            let parentID = row["parent_id"].flatMap { $0.isEmpty ? nil : $0 }
            if let parentID, !CoursePaths.validID(parentID) { throw CourseError.invalid("A channel parent identifier is invalid.") }
            nodes.append(CourseNode(id: nodeID, contentID: contentID, parentID: parentID, title: title, summary: row["description"] ?? "", kind: kind, author: row["author"] ?? "", licenseName: row["license_name"] ?? "", licenseOwner: row["license_owner"] ?? "", licenseDescription: row["license_description"] ?? "", order: order, assessmentCount: assessmentCounts[nodeID] ?? 0, resources: resourceMap[nodeID] ?? [], assessment: assessments[nodeID], languageCode: row["lang_id"].flatMap { languages[$0] } ?? row["lang_id"]))
        }
        try validateTree(nodes, rootID: rootID)
        guard Set(resourceMap.keys).isSubset(of: Set(nodes.map(\.id))) else { throw CourseError.invalid("A resource refers to a missing channel node.") }
        let metadata = InstalledCourse(id: id, channelID: channelID, name: name, summary: channel["description"] ?? "", author: channel["author"] ?? "", version: version, schemaVersion: channel["min_schema_version"] ?? "", rootID: rootID, importedAt: Date(), resourceCount: nodes.filter { $0.kind != "topic" }.count, copiedFileCount: copied.count, missingFileCount: missing.count, byteCount: copied.values.reduce(0, +))
        let data = try JSONEncoder().encode(CoursePackage(formatVersion: 1, course: metadata, nodes: nodes))
        guard data.count <= 64 * 1_024 * 1_024 else { throw CourseError.invalid("The derived channel catalog exceeds 64 MB.") }
        try data.write(to: directory.appendingPathComponent("course.json"), options: .atomic)
        try db.close()
        success = true
        return StagedCourse(course: metadata, directory: directory)
    }

    static func validateTree(_ nodes: [CourseNode], rootID: String) throws {
        let byID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard byID.count == nodes.count, let root = byID[rootID], root.parentID == nil, root.kind == "topic" else { throw CourseError.invalid("The channel tree contains duplicate IDs or an invalid root topic.") }
        var verified: Set<String> = [rootID]
        for node in nodes {
            var pending: Set<String> = [], current = node.id
            while !verified.contains(current) {
                guard pending.insert(current).inserted, let parent = byID[current]?.parentID, byID[parent]?.kind == "topic" else {
                    throw CourseError.invalid("The channel tree contains a cycle, missing parent, or disconnected topic.")
                }
                current = parent
            }
            verified.formUnion(pending)
        }
    }

    private static func copyVerified(_ source: URL, to destination: URL, checksum: String) throws -> Int64 {
        try CoursePaths.regularFile(source)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let input = try FileHandle(forReadingFrom: source), output = try FileHandle(forWritingTo: destination)
        defer { try? input.close(); try? output.close() }
        var digest = Insecure.MD5(), count: Int64 = 0
        while try autoreleasepool(invoking: { () throws -> Bool in
            try Task.checkCancellation()
            guard let data = try input.read(upToCount: 1_024 * 1_024), !data.isEmpty else { return false }
            digest.update(data: data); try output.write(contentsOf: data); count += Int64(data.count)
            return true
        }) {
            // FileHandle bridges autoreleased NSData. Drain each complete read/hash/write
            // iteration so importing a large video retains only the current chunk.
        }
        try output.synchronize()
        let actual = digest.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == checksum else { throw CourseError.invalid("\(source.lastPathComponent) failed Kolibri’s content checksum. The source export has not been changed.") }
        return count
    }
}
