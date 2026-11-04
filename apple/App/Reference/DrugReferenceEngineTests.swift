#if NOMAD_REFERENCE_ENGINE_TESTS
// Standalone native-engine tests only. These fixtures are not clinical data and
// are excluded from the application unless this explicit test flag is defined.
import Foundation
import SQLite3
import Darwin

@main @MainActor
struct DrugReferenceEngineTests {
    enum Failure: Error { case assertion(String) }
    static var checks = 0
    static var phase = "setup"

    static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure.assertion(message) }
        checks += 1
    }

    static func reject(_ name: String, _ action: () async throws -> Void) async throws {
        var failed = false
        do { try await action() } catch { failed = true }
        try require(failed, "Expected rejection: \(name)")
    }

    static func execute(_ handle: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw Failure.assertion("Fixture SQL failed: \(String(cString: sqlite3_errmsg(handle)))")
        }
    }

    static func open(_ url: URL) throws -> OpaquePointer {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else { throw Failure.assertion("Fixture database open failed") }
        return database
    }

    static func label(_ id: String, brand: String, otc: Bool, warning: String) -> [String: Any] {
        ["set_id": id, "id": "TEST_ONLY_REVISION", "version": "1", "effective_time": "20260102",
         "openfda": ["brand_name": [brand], "generic_name": ["TEST-ONLY GENERIC"],
                     "manufacturer_name": ["TEST-ONLY MAKER"], "route": ["TEST-ONLY ROUTE"],
                     "product_type": [otc ? "HUMAN OTC DRUG" : "HUMAN PRESCRIPTION DRUG"]],
         "indications_and_usage": ["TEST-ONLY NEEDLE. This is not medical content."],
         "warnings": [warning], "drug_interactions": ["TEST-ONLY INTERACTION SECTION: NO CLINICAL MEANING."]]
    }

    static func writeEnvelope(_ url: URL, records: [[String: Any]]) throws {
        let envelope: [String: Any] = ["meta": ["last_updated": "2026-01-02"], "results": records,
            "test_only": "NONCLINICAL TEST FIXTURE: never ship as medical data."]
        try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]).write(to: url)
    }

    static func main() async {
        do { try await run() }
        catch {
            fputs("FAIL during \(phase): \(error)\n", stderr)
            exit(1)
        }
    }

    static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nomad-reference-engine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = root.appendingPathComponent("store", isDirectory: true)
        let repository = DrugReferenceRepository(storageRoot: storage)
        try require(try await repository.current() == nil, "New repository must be empty")

        let rawWarning = "TEST ONLY — braces {[]}, quotes \"abc\", slash \\, Unicode café العربية.\nNUL:\u{0000} preserved after NUL. NOT MEDICAL CONTENT."
        let first = root.appendingPathComponent("part-one.json")
        try writeEnvelope(first, records: [label("TEST_ONLY_A", brand: "TEST-ONLY ALPHA", otc: true, warning: "OLD TEST TEXT"),
            label("test_only_a", brand: "TEST-ONLY ALPHA", otc: true, warning: rawWarning),
            label("TEST_ONLY_B", brand: "TEST-ONLY BETA", otc: false, warning: "TEST-ONLY BETA WARNING")])
        let originalJSON = try Data(contentsOf: first)
        phase = "initial JSON preparation"
        let prepared = try await repository.prepareImport([first])
        try require(prepared.labelCount == 2, "Case-insensitive set_id deduplication")
        try require(prepared.exportDate == "2026-01-02", "Source metadata date preserved")
        try require(try await repository.current() == nil, "Preparation must not activate data")
        phase = "initial activation"
        _ = try await repository.activate(prepared)
        try require(try await repository.current()?.id == prepared.id, "Confirmed activation updates pointer")
        try require(try Data(contentsOf: first) == originalJSON, "JSON source not edited")

        phase = "search and detail"
        let alpha = try await repository.search("alpha", indications: false, otcOnly: false)
        try require(alpha.count == 1, "Case-insensitive drug name search")
        let alphaDetail = try await repository.detail(id: alpha[0].id)
        try require(alphaDetail.fields["warnings"] == rawWarning, "Label warning text including NUL preserved verbatim")
        try require(alphaDetail.fields["source_updated_at"] == "2026-01-02", "Label date mapping")
        try require(alphaDetail.fields["drug_interactions"] == "TEST-ONLY INTERACTION SECTION: NO CLINICAL MEANING.", "Comparison uses original text")
        let beta = try await repository.search("beta", indications: false, otcOnly: false)
        let betaDetail = try await repository.detail(id: beta[0].id)
        try require(betaDetail.fields["warnings"] != alphaDetail.fields["warnings"], "Comparison keeps distinct labels separate")
        let otc = try await repository.search("NEEDLE", indications: true, otcOnly: true)
        try require(otc.count == 1 && otc[0].id == alpha[0].id, "OTC filter applies to indication search")
        let byTerms = try await repository.search("", indications: true, otcOnly: true, terms: ["NONMATCH", "TEST-ONLY NEEDLE"])
        try require(byTerms.count == 1, "Condition term OR-matching uses real stored sections")
        try require(try await repository.search("%", indications: false, otcOnly: false).isEmpty, "LIKE wildcard escaped")
        try require(try await repository.search("' OR 1=1 --", indications: false, otcOnly: false).isEmpty, "SQL-looking input is literal")

        phase = "failed import retention"
        let manifest = storage.appendingPathComponent("dataset.json")
        let activeManifest = try Data(contentsOf: manifest)
        let activeDatabase = storage.appendingPathComponent(prepared.fileName)
        let activeBytes = try Data(contentsOf: activeDatabase)
        let broken = root.appendingPathComponent("truncated.json")
        try Data("{\"meta\":{},\"results\":[{\"set_id\":\"TEST_ONLY_C\"},".utf8).write(to: broken)
        try await reject("malformed JSON after valid records") { _ = try await repository.prepareImport([first, broken]) }
        try require(try Data(contentsOf: manifest) == activeManifest, "Failed JSON import preserves active manifest")
        try require(try Data(contentsOf: activeDatabase) == activeBytes, "Failed JSON import preserves active database")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: storage.path).filter { $0.hasPrefix("labels-") }
        try require(leftovers == [prepared.fileName], "Failed import staging is cleaned up")

        let empty = root.appendingPathComponent("empty.json")
        try writeEnvelope(empty, records: [])
        try await reject("empty dataset") { _ = try await repository.prepareImport([empty]) }
        let symlink = root.appendingPathComponent("linked.json")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: first)
        try await reject("selected symbolic link") { _ = try await repository.prepareImport([symlink]) }
        let folder = root.appendingPathComponent("directory.json", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try await reject("selected directory") { _ = try await repository.prepareImport([folder]) }

        phase = "invalid SQLite schemas"
        let invalid = root.appendingPathComponent("bad-schema.sqlite")
        let invalidHandle = try open(invalid)
        try execute(invalidHandle, "CREATE TABLE drug_labels(id INTEGER PRIMARY KEY, set_id TEXT); INSERT INTO drug_labels VALUES(1,'TEST_ONLY_INVALID');")
        sqlite3_close(invalidHandle)
        try await reject("missing SQLite columns") { _ = try await repository.prepareImport([invalid]) }
        let view = root.appendingPathComponent("view.sqlite")
        let viewHandle = try open(view)
        try execute(viewHandle, "CREATE VIEW drug_labels AS SELECT 1 AS id, 'TEST_ONLY_VIEW' AS set_id;")
        sqlite3_close(viewHandle)
        try await reject("view masquerading as drug_labels") { _ = try await repository.prepareImport([view]) }
        let virtual = root.appendingPathComponent("virtual.sqlite")
        let virtualHandle = try open(virtual)
        try execute(virtualHandle, "CREATE VIRTUAL TABLE drug_labels USING fts5(set_id,brand_name);")
        sqlite3_close(virtualHandle)
        try await reject("virtual source table") { _ = try await repository.prepareImport([virtual]) }
        let composite = root.appendingPathComponent("composite-key.sqlite")
        let compositeHandle = try open(composite)
        let columnNames = ["set_id", "spl_id", "version", "brand_name", "generic_name", "manufacturer", "product_ndc", "route", "product_type", "searchable_name", "indications", "dosage", "warnings", "boxed_warning", "drug_interactions", "contraindications", "when_using", "stop_use", "source_updated_at"]
        try execute(compositeHandle, "CREATE TABLE drug_labels(id INTEGER, \(columnNames.map { "\($0) TEXT" }.joined(separator: ",")), PRIMARY KEY(id,set_id)); INSERT INTO drug_labels(id,set_id) VALUES(1,'TEST_ONLY_COMPOSITE');")
        sqlite3_close(compositeHandle)
        try await reject("composite primary key with nonunique id") { _ = try await repository.prepareImport([composite]) }
        try require(try Data(contentsOf: manifest) == activeManifest, "Invalid SQLite imports preserve active data pointer")

        // A live source in WAL mode must produce a consistent standalone snapshot.
        phase = "WAL snapshot import"
        let wal = root.appendingPathComponent("wal-source.sqlite3")
        try FileManager.default.copyItem(at: activeDatabase, to: wal)
        let walHandle = try open(wal)
        try execute(walHandle, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; INSERT INTO drug_labels(set_id,brand_name,generic_name,searchable_name) VALUES('TEST_ONLY_WAL','TEST-ONLY WAL','TEST-ONLY GENERIC','test only wal');")
        let originalMain = try Data(contentsOf: wal)
        let walSnapshot = try await repository.prepareImport([wal])
        try require(walSnapshot.labelCount == 3, "SQLite backup includes uncheckpointed WAL rows")
        try require(try Data(contentsOf: wal) == originalMain, "Read-only source main database unchanged")
        let snapshotPath = storage.appendingPathComponent(walSnapshot.fileName).path
        try require(!FileManager.default.fileExists(atPath: snapshotPath + "-wal") && !FileManager.default.fileExists(atPath: snapshotPath + "-shm"), "Prepared snapshot is independent of WAL sidecars")
        try require(try await repository.current()?.id == prepared.id, "SQLite preparation also awaits approval")
        sqlite3_close(walHandle)
        try await repository.discard(walSnapshot)
        try require(!FileManager.default.fileExists(atPath: storage.appendingPathComponent(walSnapshot.fileName).path), "Discard removes only prepared snapshot")
        try require(FileManager.default.fileExists(atPath: activeDatabase.path), "Discard preserves active data")

        phase = "changed prepared database"
        let tampered = try await repository.prepareImport([first])
        try Data("not a database".utf8).write(to: storage.appendingPathComponent(tampered.fileName))
        try await reject("prepared file changed before approval") { _ = try await repository.activate(tampered) }
        try require(try Data(contentsOf: manifest) == activeManifest, "Failed activation preserves old manifest")
        try await repository.discard(tampered)

        phase = "path traversal rejection"
        let victim = root.appendingPathComponent("victim.sqlite")
        try Data("DO NOT MODIFY TEST SENTINEL".utf8).write(to: victim)
        var malformed = try JSONSerialization.jsonObject(with: activeManifest) as! [String: Any]
        malformed["fileName"] = "../victim.sqlite"
        try JSONSerialization.data(withJSONObject: malformed).write(to: manifest)
        try await reject("manifest path traversal") { _ = try await repository.current() }
        try require(try String(contentsOf: victim, encoding: .utf8) == "DO NOT MODIFY TEST SENTINEL", "Outside sentinel untouched")
        malformed["fileName"] = "dataset.json"
        try JSONSerialization.data(withJSONObject: malformed).write(to: manifest)
        try await reject("manifest points to another store file") { _ = try await repository.current() }
        try activeManifest.write(to: manifest, options: .atomic)

        let savedDatabase = root.appendingPathComponent("preserved.sqlite")
        try FileManager.default.moveItem(at: activeDatabase, to: savedDatabase)
        try FileManager.default.createSymbolicLink(at: activeDatabase, withDestinationURL: savedDatabase)
        try await reject("stored database symbolic link") { _ = try await repository.current() }
        try FileManager.default.removeItem(at: activeDatabase)
        try FileManager.default.moveItem(at: savedDatabase, to: activeDatabase)

        let replacement = try await repository.prepareImport([first])
        let corruptOriginalManifest = Data("broken old manifest".utf8)
        try corruptOriginalManifest.write(to: manifest)
        let recovery = try await repository.activate(replacement)
        try require(recovery != nil, "Confirmed recovery from corrupt manifest is disclosed")
        try require(FileManager.default.fileExists(atPath: activeDatabase.path), "Recovery preserves old unreferenced bytes")
        // Restore the original pointer for cancellation/uninstall assertions.
        try activeManifest.write(to: manifest, options: .atomic)
        try await repository.discard(replacement)

        phase = "cancellation and uninstall"
        let cancelTask = Task { try await repository.prepareImport([first]) }
        cancelTask.cancel()
        try await reject("cancelled import") { _ = try await cancelTask.value }
        try require(try await repository.current()?.id == prepared.id, "Cancellation keeps active data")
        try await repository.uninstall()
        try require(try await repository.current() == nil, "Uninstall clears current pointer")
        try require(!FileManager.default.fileExists(atPath: activeDatabase.path), "Uninstall removes app-owned snapshot")
        try require(FileManager.default.fileExists(atPath: first.path), "Uninstall preserves original user file")
        try await situationChecks(root)
        print("PASS: \(checks) native Drug Reference checks. All labels were synthetic TEST-ONLY fixtures; no clinical data or advice was generated.")
    }

    static func situationChecks(_ root: URL) async throws {
        phase = "multi-group situation search"
        let storage = root.appendingPathComponent("situation-store")
        let repository = DrugReferenceRepository(storageRoot: storage)
        func record(_ id: String, _ brand: String, _ text: String, otc: Bool = true) -> [String: Any] {
            var value = label("TEST_ONLY_" + id, brand: brand, otc: otc, warning: "TEST ONLY: no clinical meaning")
            value["indications_and_usage"] = ["SYNTHETIC TEST FIXTURE: " + text]
            return value
        }
        var rows = [record("BOTH1", "TEST BOTH", "ALPHA_MARKER BETA_MARKER"), record("BOTH2", "TEST BOTH", "ALPHA_MARKER BETA_MARKER"),
                    record("PARTIAL", "TEST BOTH", "ALPHA_MARKER"), record("SPLIT1", "TEST SPLIT", "ALPHA_MARKER"),
                    record("SPLIT2", "TEST SPLIT", "BETA_MARKER"), record("RX", "TEST RX", "ALPHA_MARKER BETA_MARKER", otc: false),
                    record("ALIAS", "TEST ALIAS", "GAMMA_MARKER BETA_MARKER"), record("LATE", "ZZZ TEST LATE", "ALPHA_MARKER BETA_MARKER"),
                    record("LITERAL", "TEST LITERAL", "literal% underscore_ slash\\ BETA_MARKER"), record("CURATED", "TEST CURATED", "headache fever")]
        for index in 0..<1_500 { rows.append(record("NOISE_\(index)", "AAA TEST NOISE \(index)", "ALPHA_MARKER")) }
        let file = root.appendingPathComponent("situation-test-only.json")
        try writeEnvelope(file, records: rows)
        let dataset = try await repository.prepareImport([file]); _ = try await repository.activate(dataset)
        var selection = DrugSituationSelection()
        try selection.addCustom(" ALPHA_MARKER "); try selection.addCustom("BETA_MARKER")
        let results = try await repository.searchSituations(selection)
        try require(Set(results.map(\.brand)) == ["TEST BOTH", "ZZZ TEST LATE"], "same label must match every selected group, before the result limit")
        try require(results.first(where: { $0.brand == "TEST BOTH" })?.labelCount == 2, "group count includes only labels satisfying all groups")
        try require(!results.contains(where: { $0.brand == "TEST SPLIT" }), "separate partial labels cannot imply a combined match")
        try require(!results.contains(where: { $0.brand == "TEST RX" }), "situation browser stays OTC-only")
        let detail = try await repository.detail(id: results[0].id)
        try require(detail.fields["indications"]?.contains("ALPHA_MARKER") == true && detail.fields["indications"]?.contains("BETA_MARKER") == true, "representative detail supplies both original terms")
        let aliases = try await repository.search("", indications: true, otcOnly: true, termGroups: [["ALPHA_MARKER", "GAMMA_MARKER"], ["BETA_MARKER"]])
        try require(Set(aliases.map(\.brand)) == ["TEST BOTH", "TEST ALIAS", "ZZZ TEST LATE"], "OR synonyms within groups, AND across groups")
        let wildcards = try await repository.search("", indications: true, otcOnly: true, termGroups: [["literal%"], ["underscore_"], ["slash\\"]])
        try require(wildcards.count == 1 && wildcards[0].brand == "TEST LITERAL", "literal percent underscore and backslash remain escaped in all groups")
        let injected = try await repository.search("", indications: true, otcOnly: true, termGroups: [["' OR 1=1 --"], ["BETA_MARKER"]])
        try require(injected.isEmpty, "multi-group SQL-looking input is bound as text")
        selection.customTerms.removeLast()
        try require(try await repository.searchSituations(selection).count == 100, "removing a group broadens search and keeps result bound")
        try require(try await repository.searchSituations(.init()).isEmpty, "cleared selection cannot reuse stale criteria")
        var curated = DrugSituationSelection()
        try curated.toggle("headache"); try curated.toggle("fever")
        let curatedResults = try await repository.searchSituations(curated)
        try require(curatedResults.count == 1 && curatedResults[0].brand == "TEST CURATED", "catalog selection uses pinned synonym groups")
        try curated.toggle("fever")
        try require(curated.conditionIDs == ["headache"], "selection toggle removes only requested group")
        try await reject("unknown condition") { var invalid = DrugSituationSelection(); try invalid.toggle("missing") }
        try await reject("invalid stored selection ID") { var invalid = DrugSituationSelection(); invalid.conditionIDs = ["missing"]; _ = try await repository.searchSituations(invalid) }
        try await reject("empty synonym group") { _ = try await repository.search("", indications: true, otcOnly: true, termGroups: [[]]) }
        try await reject("blank term") { _ = try await repository.search("", indications: true, otcOnly: true, termGroups: [[" "]]) }
        try await reject("too many groups") { _ = try await repository.search("", indications: true, otcOnly: true, termGroups: Array(repeating: ["TEST"], count: 9)) }
        try await reject("too many synonyms") { _ = try await repository.search("", indications: true, otcOnly: true, termGroups: [Array(repeating: "TEST", count: 21)]) }
        try await reject("overlong term") { _ = try await repository.search(String(repeating: "x", count: 201), indications: true, otcOnly: false) }
        try await reject("NUL term") { _ = try await repository.search("TEST\0suffix", indications: true, otcOnly: false) }
        try await reject("ambiguous query and groups") { _ = try await repository.search("TEST", indications: true, otcOnly: true, termGroups: [["TEST"]]) }
        try await reject("duplicate custom group") { var invalid = DrugSituationSelection(); try invalid.addCustom("TEST"); try invalid.addCustom("test") }
        var limit = DrugSituationSelection()
        for index in 0..<8 { try limit.addCustom("TEST \(index)") }
        try await reject("selection beyond group limit") { try limit.addCustom("NINTH") }
        try require(limit.count == 8, "failed selection does not mutate accepted groups")
        try require(try DrugSituationSelection.normalized([[" ALPHA ", "alpha", "BETA"]]) == [["ALPHA", "BETA"]], "synonym normalization trims and deduplicates")
        try require(DrugConditionCatalog.matching(indications: "TEST ONLY: headache and FEVER").map(\.id).contains("headache"), "reverse label-term browsing is case insensitive")
        try require(DrugConditionCatalog.matching(indications: "").isEmpty, "empty indications have no reverse matches")
        phase = "active SQLite scan cancellation"
        let cancelling = DrugReferenceRepository(storageRoot: storage, queryProgress: {
            // This runs inside SQLite's real VM progress callback, after the scan starts.
            withUnsafeCurrentTask { $0?.cancel() }
        })
        let task = Task { try await cancelling.search("", indications: true, otcOnly: true, termGroups: [["ABSENT1", "ABSENT2", "ABSENT3"]]) }
        do { _ = try await task.value; throw Failure.assertion("Expected active SQLite query cancellation") }
        catch is CancellationError { checks += 1 }
        try require(try await repository.current()?.id == dataset.id, "query cancellation preserves installed pointer")
        try require(try await repository.searchSituations(curated).count == 1, "fresh query succeeds after cancelled scan")
    }
}
#endif
