import Foundation
import CryptoKit
import Darwin

@main @MainActor struct BackupRegression {
    static var checks = 0
    static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw BackupFailure("TEST FAILED: " + message) }; checks += 1
    }
    static func rejects(_ message: String, _ action: () throws -> Void) throws {
        do { try action() } catch { checks += 1; return }
        throw BackupFailure("TEST FAILED (expected rejection): " + message)
    }
    struct Fixture {
        let root: URL
        let engine: BackupEngine
        let defaults: UserDefaults
        let suite: String
        init(_ root: URL, constrained: Bool = false) throws {
            self.root = root
            suite = "org.nomad.backup.tests." + root.lastPathComponent
            defaults = UserDefaults(suiteName: suite)!
            let locations = BackupLocations(support: root.appendingPathComponent("Support"), documents: root.appendingPathComponent("Documents"))
            try BackupFileIO.prepare(locations.support); try BackupFileIO.prepare(locations.documents)
            let capacity: @Sendable () throws -> UInt64 = { constrained ? 10 : 20_000_000_000_000 }
            engine = BackupEngine(locations: locations, defaults: defaults, availableBytes: capacity)
        }
        func put(_ component: String, _ path: String, _ data: Data) throws {
            let folder = try BackupCatalog.component(component).directory(in: engine.locations)
            try BackupFileIO.prepare(folder)
            try data.write(to: BackupFileIO.child(path, in: folder, createParents: true), options: .atomic)
        }
        func data(_ component: String, _ path: String) throws -> Data {
            let folder = try BackupCatalog.component(component).directory(in: engine.locations)
            return try Data(contentsOf: BackupFileIO.child(path, in: folder))
        }
        func cleanDefaults() { defaults.removePersistentDomain(forName: suite) }
    }
    static func notes(_ title: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["formatVersion": 1, "notes": [["id": "00000000-0000-0000-0000-000000000001", "title": title, "body": "TEST ONLY " + title, "createdAt": 10, "updatedAt": 20]]], options: [.sortedKeys])
    }
    static func mutation(_ folder: URL, _ edit: (inout [String: Any]) -> Void) throws {
        let url = folder.appendingPathComponent("manifest.json")
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        edit(&json)
        try JSONSerialization.data(withJSONObject: json).write(to: url, options: .atomic)
    }
    static func stage(_ source: URL, into fixture: Fixture, selected: Set<String>? = nil) throws -> BackupReview {
        try fixture.engine.stageSelected(source, selected: selected)
    }
    static func conversation() -> [String: Any] {
        let id = UUID().uuidString
        return ["version": 1, "selectedID": id, "conversations": [["id": id, "title": "TEST ONLY conversation", "createdAt": 10, "updatedAt": 20,
            "settings": ["instructions": "", "historyMessages": 6, "responseTokens": 128, "temperature": 0.4, "useLibrary": false, "semantic": false],
            "messages": [["id": UUID().uuidString, "role": "user", "text": "TEST ONLY question", "sources": []]]]]]
    }
    static func main() async throws {
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--crash" {
            let fixture = try Fixture(URL(fileURLWithPath: CommandLine.arguments[2]))
            let target = CommandLine.arguments[3]
            _ = try BackupRestoreCoordinator.activatePendingRestore(engine: fixture.engine) { point in
                if point == target { _exit(77) }
            }
            throw BackupFailure("Crash boundary was not reached.")
        }
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--cleanup-crash" {
            let fixture = try Fixture(URL(fileURLWithPath: CommandLine.arguments[2]))
            try BackupRestoreCoordinator.discardRecovery(locations: fixture.engine.locations) { point in
                if point == CommandLine.arguments[3] { _exit(77) }
            }
            throw BackupFailure("Cleanup crash boundary was not reached.")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nomad-backup-regression-\(UUID().uuidString)")
        try BackupFileIO.prepare(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try Fixture(root.appendingPathComponent("source"))
        defer { source.cleanDefaults() }
        let oldNotes = try notes("original"), newNotes = try notes("backup")
        try source.put("notes", "notes.json", newNotes)
        try source.put("workspace", "folder/user.txt", Data("TEST ONLY workspace".utf8))
        try source.put("workspace", "empty", Data())
        source.defaults.set("A local custom prompt", forKey: "assistant.customPrompt")
        source.defaults.set("title", forKey: "notes.sort")
        source.defaults.set("#سفر OR title:Water", forKey: "notes.homeQuery")
        source.defaults.set("SECRET SENTINEL", forKey: "unrelated.keychain.password")
        let download = source.engine.locations.support.appendingPathComponent("NomadPad/Downloads/Pending/live.download")
        try BackupFileIO.prepare(download.deletingLastPathComponent())
        try Data("LIVE TRANSFER SENTINEL".utf8).write(to: download)
        let selections = [BackupSelection(component: "notes", includeContent: false), .init(component: "workspace", includeContent: false), .init(component: "preferences", includeContent: false)]
        let backup = try source.engine.export(selections: selections)
        let manifest = try source.engine.readManifest(backup)
        try check(manifest.entries.count == 5, "files, folders and preference entry captured")
        try check(manifest.entries.allSatisfy { !$0.key.contains("Downloads") }, "live downloads excluded")
        let prefs = try source.engine.decodePreferences(Data(contentsOf: backup.appendingPathComponent("Payload/preferences/preferences.plist")))
        try check(prefs["unrelated.keychain.password"] == nil, "unapproved secret preference excluded")
        try check(prefs["assistant.customPrompt"] as? String == "A local custom prompt", "allowlisted preferences captured")
        try check(prefs["notes.sort"] as? String == "title" && prefs["notes.homeQuery"] as? String == "#سفر OR title:Water", "bounded note sort and home query included")
        for values: [String: Any] in [["notes.sort": "invalid"], ["notes.homeQuery": "title:Water OR"], ["notes.homeQuery": String(repeating: "x", count: 1_025)]] {
            try rejects("invalid notes preferences rejected") {
                _ = try source.engine.decodePreferences(PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0))
            }
        }
        try check(try source.data("notes", "notes.json") == newNotes, "export leaves source unchanged")
        try check(try Data(contentsOf: download) == Data("LIVE TRANSFER SENTINEL".utf8), "export preserves live transfer")
        try check(BackupCatalog.components.contains { $0.id == "assistant" && $0.stateFiles?.contains("assistant-conversations.json") == true }, "new Apple conversations registered")
        try check(BackupCatalog.components.contains { $0.id == "gguf" && $0.stateFiles?.contains("conversations.json") == true }, "new GGUF conversations registered")

        let target = try Fixture(root.appendingPathComponent("target"))
        defer { target.cleanDefaults() }
        try target.put("notes", "notes.json", oldNotes)
        try target.put("workspace", "untouched.txt", Data("keep".utf8))
        target.defaults.set("before", forKey: "assistant.customPrompt")
        target.defaults.set("created", forKey: "notes.sort")
        target.defaults.set("#old", forKey: "notes.homeQuery")
        target.defaults.set("unrelated", forKey: "system.unrelated")
        let review = try stage(backup, into: target)
        try check(review.issues.isEmpty, "valid metadata review")
        try check(try target.data("notes", "notes.json") == oldNotes, "staging never mutates active notes")
        try BackupRestoreCoordinator.schedule(review, selected: Set(selections.map(\.component)), engine: target.engine)
        try check(try target.data("notes", "notes.json") == oldNotes, "scheduling never activates mid-use")
        _ = try BackupRestoreCoordinator.activatePendingRestore(engine: target.engine)
        try check(try target.data("notes", "notes.json") == newNotes, "startup activates selected notes")
        try check(try target.data("workspace", "untouched.txt") == Data("keep".utf8), "files absent from backup remain")
        try check(target.defaults.string(forKey: "assistant.customPrompt") == "A local custom prompt", "startup preferences restored")
        try check(target.defaults.string(forKey: "notes.sort") == "title" && target.defaults.string(forKey: "notes.homeQuery") == "#سفر OR title:Water", "note settings restored")
        try check(target.defaults.string(forKey: "system.unrelated") == "unrelated", "unapproved preferences preserved")
        try check(!BackupRestoreCoordinator.hasPendingRestore(locations: target.engine.locations), "intent removed after commit")
        try check(BackupRestoreCoordinator.hasRecovery(locations: target.engine.locations), "old state retained for rollback")
        try BackupRestoreCoordinator.requestRollback(locations: target.engine.locations)
        _ = try BackupRestoreCoordinator.activatePendingRestore(engine: target.engine)
        try check(try target.data("notes", "notes.json") == oldNotes, "explicit rollback restores old notes")
        try check(target.defaults.string(forKey: "assistant.customPrompt") == "before", "rollback restores preferences")
        try check(target.defaults.string(forKey: "notes.sort") == "created" && target.defaults.string(forKey: "notes.homeQuery") == "#old", "rollback restores earlier note settings")
        try check(!BackupFileIO.exists(try BackupFileIO.child("folder/user.txt", in: BackupCatalog.component("workspace").directory(in: target.engine.locations))), "new restored file quarantined during rollback")
        try BackupRestoreCoordinator.discardRecovery(locations: target.engine.locations)
        try check(!BackupRestoreCoordinator.hasRecovery(locations: target.engine.locations), "explicit recovery cleanup")
        try check(!BackupFileIO.exists(review.directory), "explicit recovery cleanup frees staged payload")

        let selective = try Fixture(root.appendingPathComponent("selective"))
        defer { selective.cleanDefaults() }
        let selected = try stage(backup, into: selective, selected: ["notes"])
        try check(selected.manifest.entries.allSatisfy { $0.component == "notes" }, "unselected payloads are not copied")
        try check(!BackupFileIO.exists(selected.directory.appendingPathComponent("Payload/workspace")), "workspace bytes absent from selective stage")
        try BackupRestoreCoordinator.schedule(selected, selected: ["notes"], engine: selective.engine)
        try BackupRestoreCoordinator.cancelPending(locations: selective.engine.locations)
        try check(!BackupFileIO.exists(selected.directory), "cancel removes only scheduled staging")
        try check(!BackupRestoreCoordinator.hasPendingRestore(locations: selective.engine.locations), "cancel removes intent")

        let concurrent = try Fixture(root.appendingPathComponent("concurrent-schedule"))
        defer { concurrent.cleanDefaults() }
        let candidates = try [stage(backup, into: concurrent, selected: ["notes"]), stage(backup, into: concurrent, selected: ["notes"])]
        let concurrentEngine = concurrent.engine
        let winnerCount = await withTaskGroup(of: Int.self) { group in
            for candidate in candidates {
                group.addTask {
                    do { try BackupRestoreCoordinator.schedule(candidate, selected: ["notes"], engine: concurrentEngine); return 1 }
                    catch { return 0 }
                }
            }
            var successes = 0
            for await result in group { successes += result }
            return successes
        }
        try check(winnerCount == 1, "concurrent windows cannot replace another scheduled plan")
        try BackupRestoreCoordinator.cancelPending(locations: concurrent.engine.locations)
        try check(candidates.filter { BackupFileIO.exists($0.directory) }.count == 1, "cancellation removes only winning stage")
        for candidate in candidates { try BackupRestoreCoordinator.discard(candidate, locations: concurrent.engine.locations) }

        for boundary in ["after-old:notes/notes.json", "after-new:notes/notes.json", "after-preferences", "before-commit", "after-commit"] {
            let fixture = try Fixture(root.appendingPathComponent("crash-\(UUID().uuidString)"))
            defer { fixture.cleanDefaults() }
            try fixture.put("notes", "notes.json", oldNotes)
            fixture.defaults.set("before crash", forKey: "assistant.customPrompt")
            let staged = try stage(backup, into: fixture, selected: ["notes", "preferences"])
            try BackupRestoreCoordinator.schedule(staged, selected: ["notes", "preferences"], engine: fixture.engine)
            let child = Process(); child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            child.arguments = ["--crash", fixture.root.path, boundary]
            try child.run(); child.waitUntilExit()
            try check(child.terminationStatus == 77, "child terminates at actual \(boundary) boundary")
            _ = try BackupRestoreCoordinator.activatePendingRestore(engine: fixture.engine)
            try check(try fixture.data("notes", "notes.json") == (boundary == "after-commit" ? newNotes : oldNotes), "restart recovers actual interrupted rename boundary")
            try check(!BackupRestoreCoordinator.hasPendingRestore(locations: fixture.engine.locations), "recovered intent cleared")
        }
        for boundary in ["cleanup-intent", "cleanup-stage", "cleanup-recovery"] {
            let fixture = try Fixture(root.appendingPathComponent("cleanup-\(UUID().uuidString)"))
            defer { fixture.cleanDefaults() }
            try fixture.put("notes", "notes.json", oldNotes)
            let staged = try stage(backup, into: fixture)
            let unrelated = fixture.engine.locations.control.appendingPathComponent("staged-" + UUID().uuidString)
            try BackupFileIO.prepare(unrelated)
            try Data("UNRELATED STAGE".utf8).write(to: unrelated.appendingPathComponent("keep.txt"))
            try BackupRestoreCoordinator.schedule(staged, selected: ["notes"], engine: fixture.engine)
            _ = try BackupRestoreCoordinator.activatePendingRestore(engine: fixture.engine)
            try check(try BackupRestoreCoordinator.recoveryPhase(locations: fixture.engine.locations) == "committed", "committed recovery is eligible for rollback")
            let child = Process(); child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            child.arguments = ["--cleanup-crash", fixture.root.path, boundary]
            try child.run(); child.waitUntilExit()
            try check(child.terminationStatus == 77, "child exits at real \(boundary) boundary")
            try check(try BackupRestoreCoordinator.recoveryPhase(locations: fixture.engine.locations) == "discarding", "cleanup intent persists before file deletion")
            _ = try BackupRestoreCoordinator.activatePendingRestore(engine: fixture.engine)
            try check(!BackupFileIO.exists(staged.directory), "restart finishes staged payload cleanup")
            try check(!BackupRestoreCoordinator.hasRecovery(locations: fixture.engine.locations), "restart finishes journal cleanup")
            try check(try fixture.data("notes", "notes.json") == newNotes, "cleanup never changes active restored data")
            try check(try Data(contentsOf: unrelated.appendingPathComponent("keep.txt")) == Data("UNRELATED STAGE".utf8), "cleanup preserves unrelated stage")
            try check(BackupFileIO.exists(backup.appendingPathComponent("Payload/workspace/folder/user.txt")), "cleanup preserves source backup")
        }

        let failure = try Fixture(root.appendingPathComponent("injected-failure"))
        defer { failure.cleanDefaults() }
        try failure.put("notes", "notes.json", oldNotes)
        let failedReview = try stage(backup, into: failure, selected: ["notes"])
        try BackupRestoreCoordinator.schedule(failedReview, selected: ["notes"], engine: failure.engine)
        try rejects("write/move failure rolls back") {
            _ = try BackupRestoreCoordinator.activatePendingRestore(engine: failure.engine) { point in
                if point == "after-new:notes/notes.json" { throw BackupFailure("TEST ONLY injected I/O failure") }
            }
        }
        try check(try failure.data("notes", "notes.json") == oldNotes, "failure keeps original data")
        let low = try Fixture(root.appendingPathComponent("low-space"), constrained: true)
        defer { low.cleanDefaults() }
        try low.put("notes", "notes.json", oldNotes)
        try rejects("export capacity preflight") { _ = try low.engine.export(selections: [.init(component: "notes", includeContent: false)]) }
        try rejects("restore capacity preflight") { _ = try stage(backup, into: low) }
        try check(try low.data("notes", "notes.json") == oldNotes, "capacity failures preserve active data")

        let damaged = root.appendingPathComponent("damaged.nomadbackup")
        try FileManager.default.copyItem(at: backup, to: damaged)
        try Data("tampered".utf8).write(to: damaged.appendingPathComponent("Payload/notes/notes.json"))
        try rejects("tampered bytes rejected") { _ = try stage(damaged, into: selective) }
        try FileManager.default.removeItem(at: damaged)
        try FileManager.default.copyItem(at: backup, to: damaged)
        var sameLength = newNotes; sameLength[sameLength.startIndex] ^= 1
        try sameLength.write(to: damaged.appendingPathComponent("Payload/notes/notes.json"))
        try rejects("same-length checksum tampering rejected") { _ = try stage(damaged, into: selective) }
        try FileManager.default.removeItem(at: damaged)
        try FileManager.default.copyItem(at: backup, to: damaged)
        try mutation(damaged) { json in
            var entries = json["entries"] as! [[String: Any]]; entries[0]["path"] = "../../escape"; json["entries"] = entries
        }
        try rejects("manifest traversal rejected") { _ = try stage(damaged, into: selective) }
        try FileManager.default.removeItem(at: damaged)
        try FileManager.default.copyItem(at: backup, to: damaged)
        try mutation(damaged) { json in let entries = json["entries"] as! [[String: Any]]; json["entries"] = entries + [entries[0]] }
        try rejects("duplicate paths rejected") { _ = try stage(damaged, into: selective) }
        try FileManager.default.removeItem(at: damaged)
        try FileManager.default.copyItem(at: backup, to: damaged)
        try mutation(damaged) { $0["formatVersion"] = 100 }
        try rejects("future manifest refused") { _ = try stage(damaged, into: selective) }
        try FileManager.default.removeItem(at: damaged)
        try FileManager.default.copyItem(at: backup, to: damaged)
        let substituted = damaged.appendingPathComponent("Payload/notes/notes.json")
        try FileManager.default.removeItem(at: substituted)
        try FileManager.default.createSymbolicLink(at: substituted, withDestinationURL: download)
        try rejects("symlink payload refused") { _ = try stage(damaged, into: selective) }
        try check(try Data(contentsOf: download) == Data("LIVE TRANSFER SENTINEL".utf8), "malicious backup cannot modify transfer")

        let changing = try Fixture(root.appendingPathComponent("changing"))
        defer { changing.cleanDefaults() }
        try changing.put("notes", "notes.json", newNotes)
        let noteURL = try BackupFileIO.child("notes.json", in: BackupCatalog.component("notes").directory(in: changing.engine.locations))
        try rejects("concurrent snapshot mutation") {
            _ = try changing.engine.export(selections: [.init(component: "notes", includeContent: false)]) { _ in
                try? oldNotes.write(to: noteURL, options: .atomic)
            }
        }
        try check(try changing.data("notes", "notes.json") == oldNotes, "snapshot mutation not overwritten")
        let streaming = try Fixture(root.appendingPathComponent("streaming-cancel"))
        defer { streaming.cleanDefaults() }
        try streaming.put("workspace", "large.bin", Data(repeating: 7, count: 3 * 1_024 * 1_024))
        let cancellationEngine = streaming.engine
        let cancelled = Task.detached { () throws -> URL in
            try cancellationEngine.export(selections: [.init(component: "workspace", includeContent: false)]) { value in
                if value.completedBytes >= 1_024 * 1_024 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do { _ = try await cancelled.value; throw BackupFailure("TEST FAILED: cancellation") }
        catch is CancellationError { checks += 1 }
        try check(try FileManager.default.contentsOfDirectory(atPath: streaming.engine.locations.exports.path).isEmpty, "mid-stream cancellation removes partial export")
        try check(try streaming.data("workspace", "large.bin").count == 3 * 1_024 * 1_024, "mid-stream cancellation preserves source bytes")

        let conversations = try Fixture(root.appendingPathComponent("conversations"))
        defer { conversations.cleanDefaults() }
        func checkArchive(_ archive: [String: Any], valid: Bool, _ label: String) throws {
            try conversations.put("assistant", "assistant-conversations.json", JSONSerialization.data(withJSONObject: archive))
            let file = try conversations.engine.export(selections: [.init(component: "assistant", includeContent: false)])
            let result = try selective.engine.inspect(file)
            try check((result.issues["assistant"] == nil) == valid, label)
        }
        let validArchive = conversation()
        try checkArchive(validArchive, valid: true, "valid native conversation archive accepted")
        for field in ["version", "selectedID", "empty", "duplicate", "title", "messages", "role", "source", "settings", "boolean"] {
            var archive = validArchive
            var rows = archive["conversations"] as! [[String: Any]]
            var row = rows[0]
            var settings = row["settings"] as! [String: Any]
            var messages = row["messages"] as! [[String: Any]]
            switch field {
            case "version": archive["version"] = 2
            case "selectedID": archive["selectedID"] = UUID().uuidString
            case "empty": rows = []
            case "duplicate": rows.append(row)
            case "title": row["title"] = String(repeating: "x", count: 121)
            case "messages": messages.append(messages[0]); row["messages"] = messages
            case "role": messages[0]["role"] = "system"; row["messages"] = messages
            case "source": messages[0]["sources"] = [["id": "source", "documentID": "invalid", "title": "TEST", "excerpt": "TEST"]]; row["messages"] = messages
            case "settings": settings["responseTokens"] = 513; row["settings"] = settings
            default: settings["useLibrary"] = 1; row["settings"] = settings
            }
            if !["empty", "duplicate"].contains(field) { rows[0] = row }
            archive["conversations"] = rows
            try checkArchive(archive, valid: false, "invalid conversation \(field) blocked before scheduling")
        }
        try conversations.put("assistant", "assistant-conversations.json", JSONSerialization.data(withJSONObject: validArchive))
        try conversations.put("assistant", "assistant.json", JSONSerialization.data(withJSONObject: [["id": UUID().uuidString, "role": "system", "text": "TEST", "sources": []]]))
        let invalidLegacy = try conversations.engine.export(selections: [.init(component: "assistant", includeContent: false)])
        try check(try selective.engine.inspect(invalidLegacy).issues["assistant"] != nil, "invalid legacy role also blocked")

        let stagedTamper = try Fixture(root.appendingPathComponent("staged-tamper"))
        defer { stagedTamper.cleanDefaults() }
        try stagedTamper.put("notes", "notes.json", oldNotes)
        let stagedReview = try stage(backup, into: stagedTamper, selected: ["notes"])
        try BackupRestoreCoordinator.schedule(stagedReview, selected: ["notes"], engine: stagedTamper.engine)
        try sameLength.write(to: stagedReview.directory.appendingPathComponent("Payload/notes/notes.json"))
        try rejects("private staging rechecked before activation") { _ = try BackupRestoreCoordinator.activatePendingRestore(engine: stagedTamper.engine) }
        try check(try stagedTamper.data("notes", "notes.json") == oldNotes, "invalid private staging preserves active data")

        let unsafeDestination = try Fixture(root.appendingPathComponent("unsafe-destination"))
        defer { unsafeDestination.cleanDefaults() }
        let unsafeReview = try stage(backup, into: unsafeDestination, selected: ["notes"])
        try BackupRestoreCoordinator.schedule(unsafeReview, selected: ["notes"], engine: unsafeDestination.engine)
        let unsafeNotes = try BackupCatalog.component("notes").directory(in: unsafeDestination.engine.locations)
        try BackupFileIO.prepare(unsafeNotes)
        try FileManager.default.createSymbolicLink(at: unsafeNotes.appendingPathComponent("notes.json"), withDestinationURL: download)
        try rejects("symlink destination rejected before restore") { _ = try BackupRestoreCoordinator.activatePendingRestore(engine: unsafeDestination.engine) }
        try check(try Data(contentsOf: download) == Data("LIVE TRANSFER SENTINEL".utf8), "unsafe destination cannot overwrite external transfer")

        let inventory = try Fixture(root.appendingPathComponent("inventory"))
        defer { inventory.cleanDefaults() }
        let attachmentBytes = Data("TEST ONLY attachment bytes, not a real PDF".utf8)
        let attachment = InventoryAttachment(id: UUID(), name: "TEST ONLY receipt", fileExtension: "pdf", byteCount: attachmentBytes.count,
            sha256: InventoryValidation.hash(attachmentBytes), addedAt: Date())
        var item = InventoryItem(name: "TEST ONLY equipment", location: "TEST", quantity: 2, notes: "TEST")
        item.attachments = [attachment]; item.tags = ["test"]; item.purchasePrice = "12.50"
        try inventory.put("inventory", "inventory.json", JSONEncoder().encode(InventoryArchive(items: [item])))
        try inventory.put("inventory", "attachments/" + attachment.filename, attachmentBytes)
        let inventoryBackup = try inventory.engine.export(selections: [.init(component: "inventory", includeContent: false)])
        try check(try selective.engine.inspect(inventoryBackup).issues["inventory"] == nil, "inventory v2 validator and attachment hash accepted")
        var badItem = item; badItem.purchasePrice = "-1"
        try inventory.put("inventory", "inventory.json", JSONEncoder().encode(InventoryArchive(items: [badItem])))
        let invalidInventory = try inventory.engine.export(selections: [.init(component: "inventory", includeContent: false)])
        try check(try selective.engine.inspect(invalidInventory).issues["inventory"] != nil, "inventory native metadata constraints enforced")
        try inventory.put("inventory", "inventory.json", JSONEncoder().encode(InventoryArchive(items: [item])))
        try inventory.put("inventory", "attachments/" + attachment.filename, Data(repeating: 1, count: attachmentBytes.count))
        let invalidAttachment = try inventory.engine.export(selections: [.init(component: "inventory", includeContent: false)])
        try check(try selective.engine.inspect(invalidAttachment).issues["inventory"] != nil, "inventory attachment semantic checksum enforced")
        for values: [String: Any] in [["NomadGGUFUseGPU": "true"], ["epub.reader.zoom": Double.infinity], ["epub.position.test": Data("{}".utf8)]] {
            let data = try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
            try rejects("malformed typed preference blocked") { _ = try selective.engine.decodePreferences(data) }
        }
        let position = try JSONSerialization.data(withJSONObject: ["path": "OEBPS/chapter.xhtml", "fraction": 0.5])
        let preference = try PropertyListSerialization.data(fromPropertyList: ["epub.position.test": position], format: .binary, options: 0)
        try check(try selective.engine.decodePreferences(preference).count == 1, "valid EPUB reading position accepted")
        conversations.defaults.set("invalid boolean", forKey: "NomadGGUFUseGPU")
        try check(try conversations.engine.export(selections: [.init(component: "workspace", includeContent: false)]).isFileURL, "unselected corrupt preferences do not block unrelated export")
        try rejects("selected malformed preferences refused") { _ = try conversations.engine.export(selections: [.init(component: "preferences", includeContent: false)]) }

        let malformedJournal = try Fixture(root.appendingPathComponent("malformed-journal"))
        defer { malformedJournal.cleanDefaults() }
        try malformedJournal.put("notes", "notes.json", oldNotes)
        try BackupFileIO.prepare(malformedJournal.engine.locations.control)
        let corruptJournal = Data("{TEST ONLY corrupt journal}".utf8)
        let journalURL = malformedJournal.engine.locations.control.appendingPathComponent("activation.json")
        try corruptJournal.write(to: journalURL)
        try rejects("corrupt journal blocks startup") { _ = try BackupRestoreCoordinator.activatePendingRestore(engine: malformedJournal.engine) }
        try check(try Data(contentsOf: journalURL) == corruptJournal, "corrupt journal preserved for recovery")
        try check(try malformedJournal.data("notes", "notes.json") == oldNotes, "corrupt journal cannot modify data")

        let annotations = try Fixture(root.appendingPathComponent("annotations"))
        defer { annotations.cleanDefaults() }
        let mark = ReadingMark(id: UUID(), bookKey: "TEST.epub", bookTitle: "TEST ONLY book", chapterPath: "Text/chapter.xhtml", fragment: nil,
            fraction: 0.25, title: "TEST ONLY bookmark", quote: "TEST", note: "TEST", createdAt: Date(), updatedAt: Date())
        try annotations.put("annotations", "marks.json", JSONEncoder().encode([mark]))
        let validMarks = try annotations.engine.export(selections: [.init(component: "annotations", includeContent: false)])
        try check(try selective.engine.inspect(validMarks).issues["annotations"] == nil, "reading marks remain portable without deleted book")
        var longNote = mark; longNote.note = String(repeating: "x", count: 8_001)
        for invalid in [[mark, mark], [longNote]] {
            try annotations.put("annotations", "marks.json", JSONEncoder().encode(invalid))
            let file = try annotations.engine.export(selections: [.init(component: "annotations", includeContent: false)])
            try check(try selective.engine.inspect(file).issues["annotations"] != nil, "native reading mark validation enforced")
        }

        let library = try Fixture(root.appendingPathComponent("library"))
        defer { library.cleanDefaults() }
        let id = UUID(), filename = id.uuidString + ".txt", text = Data("TEST ONLY library".utf8)
        let libraryJSON = try JSONSerialization.data(withJSONObject: ["formatVersion": 1, "records": [["document": ["id": id.uuidString, "title": "test", "filename": filename, "kind": "text", "byteCount": text.count, "importedAt": 10, "indexingStatus": "indexed"], "searchableText": "TEST ONLY library"]]])
        try library.put("library", "library.json", libraryJSON)
        try library.put("library", "Files/" + filename, text)
        let metadataOnly = try library.engine.export(selections: [.init(component: "library", includeContent: false)])
        let missing = try stage(metadataOnly, into: selective)
        try check(missing.issues["library"] != nil, "state-only missing content visibly blocks component")
        try rejects("dangling library restore not scheduled") { try BackupRestoreCoordinator.schedule(missing, selected: ["library"], engine: selective.engine) }
        let complete = try library.engine.export(selections: [.init(component: "library", includeContent: true)])
        let full = try stage(complete, into: selective)
        try check(full.issues.isEmpty, "included assets satisfy restore dependencies")
        try BackupRestoreCoordinator.schedule(full, selected: ["library"], engine: selective.engine)
        _ = try BackupRestoreCoordinator.activatePendingRestore(engine: selective.engine)
        try check(try selective.data("library", "Files/" + filename) == text, "full library payload restored")

        let notebook = try Fixture(root.appendingPathComponent("notes-with-trash"))
        defer { notebook.cleanDefaults() }
        let activeNote = LocalNote(title: "TEST ONLY active", body: "TEST ONLY body")
        let trashedNote = LocalNote(title: "TEST ONLY trash", body: "TEST ONLY retained deleted note")
        let notebookData = try JSONEncoder().encode(NotesArchive(notes: [activeNote], trash: [trashedNote]))
        try notebook.put("notes", "notes.json", notebookData)
        let notebookBackup = try notebook.engine.export(selections: [.init(component: "notes", includeContent: false)])
        let notebookReview = try notebook.engine.inspect(notebookBackup)
        try check(notebookReview.issues.isEmpty, "native notes validator accepts active and recoverable trash")
        let notebookTarget = try Fixture(root.appendingPathComponent("notes-trash-target"))
        defer { notebookTarget.cleanDefaults() }
        let notebookStage = try stage(notebookBackup, into: notebookTarget)
        try BackupRestoreCoordinator.schedule(notebookStage, selected: ["notes"], engine: notebookTarget.engine)
        _ = try BackupRestoreCoordinator.activatePendingRestore(engine: notebookTarget.engine)
        let restoredNotebook = try NotesArchive.decode(notebookTarget.data("notes", "notes.json"))
        try check(restoredNotebook.notes == [activeNote] && restoredNotebook.trash == [trashedNote], "restore preserves both active notes and trash exactly")
        for invalid in [NotesArchive(notes: [activeNote], trash: [activeNote]),
                        NotesArchive(notes: [], trash: [LocalNote(title: "TEST", body: String(repeating: "x", count: NotesArchive.maximumNoteBytes + 1))]),
                        NotesArchive(notes: [], trash: [LocalNote(title: "TEST", body: "bad\0text")])] {
            try notebook.put("notes", "notes.json", JSONEncoder().encode(invalid))
            let file = try notebook.engine.export(selections: [.init(component: "notes", includeContent: false)])
            try check(try notebook.engine.inspect(file).issues["notes"] != nil, "invalid native notes/trash rejected before scheduling")
        }
        try notebook.put("notes", "notes.json", JSONSerialization.data(withJSONObject: ["formatVersion": 1, "notes": [], "trash": "invalid"]))
        let badTrash = try notebook.engine.export(selections: [.init(component: "notes", includeContent: false)])
        try check(try notebook.engine.inspect(badTrash).issues["notes"] != nil, "malformed optional trash cannot replace valid notes")

        // Case-insensitive Apple volumes can already contain Nomad while legacy roots request NOMAD.
        let spelling = root.appendingPathComponent("case-spelling")
        try BackupFileIO.prepare(spelling.appendingPathComponent("Nomad"))
        try BackupFileIO.prepare(spelling.appendingPathComponent("NOMAD/Collections/inventory"))
        try check(try BackupFileIO.fingerprint(spelling.appendingPathComponent("NOMAD/Collections/inventory")).directory, "component-wise backup mkdir handles an existing alternate-spelling ancestor")

        let legacy = try Fixture(root.appendingPathComponent("legacy-spelling"))
        defer { legacy.cleanDefaults() }
        try legacy.put("notes", "notes.json", oldNotes) // Creates the existing historical Nomad root.
        let inventoryRoot = try BackupCatalog.component("inventory").directory(in: legacy.engine.locations)
        try check(!BackupFileIO.exists(inventoryRoot), "registered-directory resolution is read-only")
        let caseSensitive = try legacy.engine.locations.support.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames
        if caseSensitive == false {
            try check(inventoryRoot.path == legacy.engine.locations.support.appendingPathComponent("Nomad/Collections/inventory").path, "case-insensitive catalog lookup preserves actual ancestor spelling")
        }
        let legacyInventoryBytes = try JSONEncoder().encode(InventoryArchive(items: [InventoryItem(name: "TEST ONLY compass", location: "Test", quantity: 1, notes: "Isolated fixture")]))
        try legacy.put("inventory", "inventory.json", legacyInventoryBytes)
        let exportedLegacy = try legacy.engine.export(selections: [.init(component: "inventory", includeContent: false)])
        try check(try legacy.engine.readManifest(exportedLegacy).entries.contains { $0.key == "inventory/inventory.json" }, "existing inventory cannot be silently omitted by root spelling")
        let legacyTarget = try Fixture(root.appendingPathComponent("legacy-target"))
        defer { legacyTarget.cleanDefaults() }
        try legacyTarget.put("notes", "notes.json", oldNotes)
        let emptyInventory = try JSONEncoder().encode(InventoryArchive(items: []))
        try legacyTarget.put("inventory", "inventory.json", emptyInventory)
        let legacyReview = try stage(exportedLegacy, into: legacyTarget)
        try check(legacyReview.issues.isEmpty, "alternate-spelling inventory validates before scheduling")
        try BackupRestoreCoordinator.schedule(legacyReview, selected: ["inventory"], engine: legacyTarget.engine)
        _ = try BackupRestoreCoordinator.activatePendingRestore(engine: legacyTarget.engine)
        try check(try legacyTarget.data("inventory", "inventory.json") == legacyInventoryBytes, "inventory activation retains registered existing root")
        try BackupRestoreCoordinator.requestRollback(locations: legacyTarget.engine.locations)
        _ = try BackupRestoreCoordinator.activatePendingRestore(engine: legacyTarget.engine)
        try check(try legacyTarget.data("inventory", "inventory.json") == emptyInventory, "inventory rollback restores bytes through existing spelling")
        try check(try legacyTarget.data("notes", "notes.json") == oldNotes, "inventory restore leaves sibling notes untouched")
        let badRoot = try Fixture(root.appendingPathComponent("symbolic-registered-root"))
        defer { badRoot.cleanDefaults() }
        try FileManager.default.createSymbolicLink(at: badRoot.engine.locations.support.appendingPathComponent("NOMAD"), withDestinationURL: legacy.engine.locations.support.appendingPathComponent("Nomad"))
        try rejects("registered root symlink rejected during lookup") { _ = try BackupCatalog.component("inventory").directory(in: badRoot.engine.locations) }
        print("PASS: \(checks) native backup checks; real streaming/integrity, selective staging, preferences, rename interruption recovery and live-download exclusion.")
    }
}
