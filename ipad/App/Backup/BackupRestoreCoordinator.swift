import Foundation

enum BackupActivationOutcome: Sendable {
    case none
    case restored(String)
    case rolledBack(String)
    var message: String? {
        switch self { case .none: nil; case .restored(let text), .rolledBack(let text): text }
    }
}

/// Call once at cold startup, before creating ANY app data store or workspace view.
/// UI operations below only stage/schedule; they never activate against running stores.
enum BackupRestoreCoordinator {
    // A second window may finish private staging on another worker. Serialize intent,
    // activation and cleanup mutations so check-before-write cannot replace another plan.
    private static let mutationLock = NSRecursiveLock()
    private struct Pending: Codable {
        var version = 1
        let stage: String
        let selected: [String]
        let manifestID: UUID
    }
    private struct Change: Codable {
        let component: String
        let path: String
        let existed: Bool
        var key: String { component + "/" + path }
    }
    private struct Journal: Codable {
        var version = 1
        let id: UUID
        let stage: String
        var phase: String
        let changes: [Change]
        let preferences: Bool
    }
    static func hasPendingRestore(locations: BackupLocations = .live) -> Bool {
        BackupFileIO.exists(locations.control.appendingPathComponent("pending.json"))
    }
    static func hasRecovery(locations: BackupLocations = .live) -> Bool {
        BackupFileIO.exists(locations.control.appendingPathComponent("activation.json"))
    }
    static func recoveryPhase(locations: BackupLocations = .live) throws -> String? {
        hasRecovery(locations: locations) ? try readJournal(locations).phase : nil
    }
    static func schedule(_ review: BackupReview, selected: Set<String>, engine: BackupEngine = BackupEngine()) throws {
        mutationLock.lock(); defer { mutationLock.unlock() }
        try validStage(review.directory.lastPathComponent)
        guard review.directory.deletingLastPathComponent().standardizedFileURL == engine.locations.control.standardizedFileURL,
              !selected.isEmpty, selected.isSubset(of: Set(review.manifest.selections.map(\.component))) else { throw BackupFailure("Choose valid staged components to restore.") }
        try BackupFileIO.prepare(engine.locations.control)
        guard !hasPendingRestore(locations: engine.locations), !hasRecovery(locations: engine.locations) else {
            throw BackupFailure("A scheduled restore or retained recovery already exists. Cancel the pending restore or finish recovery management first.")
        }
        let manifest = try engine.readManifest(review.directory)
        guard manifest.id == review.manifest.id else { throw BackupFailure("The staged backup changed.") }
        let payload = try BackupFileIO.child("Payload", in: review.directory)
        let issues = try BackupMetadata.issues(manifest: manifest, payload: payload, locations: engine.locations)
        for id in selected { if let issue = issues[id] { throw BackupFailure("\(id): \(issue)") } }
        try BackupFileIO.write(Pending(stage: review.directory.lastPathComponent, selected: selected.sorted(), manifestID: manifest.id),
                               to: engine.locations.control.appendingPathComponent("pending.json"))
    }
    static func discard(_ review: BackupReview, locations: BackupLocations = .live) throws {
        mutationLock.lock(); defer { mutationLock.unlock() }
        try validStage(review.directory.lastPathComponent)
        guard review.directory.deletingLastPathComponent().standardizedFileURL == locations.control.standardizedFileURL,
              !hasPendingRestore(locations: locations), !hasRecovery(locations: locations) else { throw BackupFailure("Cancel the pending restore before discarding staged files.") }
        if BackupFileIO.exists(review.directory) { try FileManager.default.removeItem(at: review.directory) }
    }
    static func cancelPending(locations: BackupLocations = .live) throws {
        mutationLock.lock(); defer { mutationLock.unlock() }
        guard !hasRecovery(locations: locations) else { throw BackupFailure("An activation journal exists. Restart to recover before changing its plan.") }
        let url = locations.control.appendingPathComponent("pending.json")
        guard BackupFileIO.exists(url) else { return }
        let pending = try readPending(locations)
        // Remove the intent first. An interrupted cleanup only leaves an unused staging folder.
        try FileManager.default.removeItem(at: url)
        let stage = try BackupFileIO.child(pending.stage, in: locations.control)
        if BackupFileIO.exists(stage) { try FileManager.default.removeItem(at: stage) }
    }
    static func requestRollback(locations: BackupLocations = .live) throws {
        mutationLock.lock(); defer { mutationLock.unlock() }
        var journal = try readJournal(locations)
        guard journal.phase == "committed" else { throw BackupFailure("Restart to finish the existing recovery first.") }
        journal.phase = "rollbackRequested"
        try BackupFileIO.write(journal, to: locations.control.appendingPathComponent("activation.json"))
    }
    /// Explicitly discards this journal's staged and retained recovery files. Persist intent
    /// before removing either folder, so a subsequent startup can finish an interrupted cleanup.
    static func discardRecovery(locations: BackupLocations = .live, checkpoint: (String) throws -> Void = { _ in }) throws {
        mutationLock.lock(); defer { mutationLock.unlock() }
        var journal = try readJournal(locations)
        guard ["committed", "rolledBack", "discarding"].contains(journal.phase), !hasPendingRestore(locations: locations) else { throw BackupFailure("Recovery cannot be discarded while activation is pending.") }
        journal.phase = "discarding"
        try BackupFileIO.write(journal, to: locations.control.appendingPathComponent("activation.json"))
        try checkpoint("cleanup-intent")
        try finishDiscard(journal, locations: locations, checkpoint: checkpoint)
    }
    private static func finishDiscard(_ journal: Journal, locations: BackupLocations, checkpoint: (String) throws -> Void = { _ in }) throws {
        guard journal.phase == "discarding", !hasPendingRestore(locations: locations) else { throw BackupFailure("Invalid recovery cleanup state. All remaining files were preserved.") }
        let stage = try BackupFileIO.child(journal.stage, in: locations.control)
        if BackupFileIO.exists(stage) { try FileManager.default.removeItem(at: stage) }
        try checkpoint("cleanup-stage")
        let folder = try recoveryFolder(journal, locations: locations)
        if BackupFileIO.exists(folder) { try FileManager.default.removeItem(at: folder) }
        try checkpoint("cleanup-recovery")
        try FileManager.default.removeItem(at: locations.control.appendingPathComponent("activation.json"))
    }

    /// Synchronous by design; run on a startup worker while showing a gate screen. A thrown
    /// error MUST keep normal stores closed until recovery succeeds. DownloadStore is untouched.
    @discardableResult
    static func activatePendingRestore(engine: BackupEngine = BackupEngine(),
                                       checkpoint: (String) throws -> Void = { _ in }) throws -> BackupActivationOutcome {
        mutationLock.lock(); defer { mutationLock.unlock() }
        let locations = engine.locations
        guard BackupFileIO.exists(locations.control) else { return .none }
        if hasRecovery(locations: locations) {
            let journal = try readJournal(locations)
            if journal.phase == "discarding" {
                try finishDiscard(journal, locations: locations)
                return .none
            }
            if journal.phase == "applying" || journal.phase == "rollbackRequested" || journal.phase == "rollingBack" {
                try rollback(journal, engine: engine)
                return .rolledBack("The previous restore was rolled back. Earlier files and preferences were restored; displaced newer files remain in the recovery folder.")
            }
            if journal.phase == "committed" {
                // Crash after commit but before intent cleanup: keep the committed version.
                try removePendingAfter(journal, locations: locations)
            }
            return .none
        }
        guard hasPendingRestore(locations: locations) else { return .none }
        let pending = try readPending(locations)
        let stage = try BackupFileIO.child(pending.stage, in: locations.control)
        let manifest = try engine.readManifest(stage)
        guard manifest.id == pending.manifestID, Set(pending.selected).isSubset(of: Set(manifest.selections.map(\.component))) else { throw BackupFailure("The restore plan does not match its backup.") }
        let payload = try BackupFileIO.child("Payload", in: stage)
        try engine.validatePayloadShape(manifest, payload: payload)
        let selected = Set(pending.selected)
        let entries = manifest.entries.filter { selected.contains($0.component) }
        for entry in entries where !entry.directory {
            try Task.checkCancellation()
            let file = try BackupFileIO.child(entry.key, in: payload)
            guard try BackupFileIO.copyAndHash(file, to: nil, expected: entry.bytes) == entry.sha256 else { throw BackupFailure("Staged restore checksum changed. Live data has not been modified.") }
        }
        let issues = try BackupMetadata.issues(manifest: manifest, payload: payload, locations: locations)
        for id in selected { if let issue = issues[id] { throw BackupFailure("\(id): \(issue)") } }
        try BackupFileIO.capacity(locations.control, additional: 0, available: engine.availableBytes)
        var changes: [Change] = []
        // Preflight every destination before journal creation and before any file replacement.
        for entry in entries where entry.component != "preferences" {
            let component = try BackupCatalog.component(entry.component)
            let root = try component.directory(in: locations)
            try BackupFileIO.prepare(root)
            let destination = try BackupFileIO.child(entry.path, in: root)
            let exists = BackupFileIO.exists(destination)
            if exists, try BackupFileIO.fingerprint(destination).directory != entry.directory { throw BackupFailure("A restore destination has a conflicting file/folder type: \(entry.key)") }
            if !entry.directory { changes.append(Change(component: entry.component, path: entry.path, existed: exists)) }
        }
        var journal = Journal(id: UUID(), stage: pending.stage, phase: "applying", changes: changes,
                              preferences: selected.contains("preferences") && entries.contains { $0.key == "preferences/preferences.plist" })
        let recovery = try recoveryFolder(journal, locations: locations)
        try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: false)
        try BackupFileIO.prepare(recovery.appendingPathComponent("Old"))
        try BackupFileIO.prepare(recovery.appendingPathComponent("Displaced"))
        if journal.preferences { try engine.preferenceData().write(to: recovery.appendingPathComponent("preferences-before.plist"), options: .atomic) }
        try BackupFileIO.write(journal, to: locations.control.appendingPathComponent("activation.json"))
        do {
            for entry in entries where entry.directory && entry.component != "preferences" {
                let component = try BackupCatalog.component(entry.component)
                let folder = try BackupFileIO.child(entry.path, in: component.directory(in: locations), createParents: true)
                try BackupFileIO.prepare(folder)
            }
            for change in changes {
                try Task.checkCancellation()
                let component = try BackupCatalog.component(change.component)
                let destination = try BackupFileIO.child(change.path, in: component.directory(in: locations), createParents: true)
                let old = try BackupFileIO.child(change.key, in: recovery.appendingPathComponent("Old"), createParents: true)
                let incoming = try BackupFileIO.child(change.key, in: payload)
                if change.existed { try FileManager.default.moveItem(at: destination, to: old) }
                try checkpoint("after-old:" + change.key)
                try FileManager.default.moveItem(at: incoming, to: destination)
                try checkpoint("after-new:" + change.key)
            }
            if journal.preferences {
                try engine.installPreferences(BackupFileIO.read(BackupFileIO.child("preferences/preferences.plist", in: payload), maximum: 4 * 1_024 * 1_024))
                try checkpoint("after-preferences")
            }
            try checkpoint("before-commit")
            journal.phase = "committed"
            try BackupFileIO.write(journal, to: locations.control.appendingPathComponent("activation.json"))
        } catch {
            do { try rollback(journal, engine: engine) }
            catch { throw BackupFailure("Restore and rollback could not finish. Keep normal stores closed and retry startup recovery. All recovery files were preserved. \(error.localizedDescription)") }
            throw BackupFailure("Restore failed and was rolled back. Your previous data was preserved.")
        }
        try checkpoint("after-commit")
        try removePendingAfter(journal, locations: locations)
        return .restored("Selected backup components were restored. Previous files are retained for rollback. The download queue and vault were not changed.")
    }

    private static func rollback(_ original: Journal, engine: BackupEngine) throws {
        let locations = engine.locations
        var journal = original; journal.phase = "rollingBack"
        try BackupFileIO.write(journal, to: locations.control.appendingPathComponent("activation.json"))
        let recovery = try recoveryFolder(journal, locations: locations)
        let oldRoot = try BackupFileIO.child("Old", in: recovery)
        let displacedRoot = try BackupFileIO.child("Displaced", in: recovery)
        let stage = try BackupFileIO.child(journal.stage, in: locations.control)
        for change in journal.changes.reversed() {
            let component = try BackupCatalog.component(change.component)
            let destination = try BackupFileIO.child(change.path, in: component.directory(in: locations), createParents: true)
            let old = try BackupFileIO.child(change.key, in: oldRoot, createParents: true)
            let displaced = try BackupFileIO.child(change.key, in: displacedRoot, createParents: true)
            if BackupFileIO.exists(old) {
                if BackupFileIO.exists(destination) {
                    guard !BackupFileIO.exists(displaced) else { throw BackupFailure("Recovery contains conflicting displaced files; all copies were preserved.") }
                    try FileManager.default.moveItem(at: destination, to: displaced)
                }
                try FileManager.default.moveItem(at: old, to: destination)
            } else if change.existed {
                // Either not yet changed, or already restored in an interrupted rollback.
                guard BackupFileIO.exists(destination) else { throw BackupFailure("An original file is missing from both live and recovery storage.") }
            } else if BackupFileIO.exists(destination) {
                let incoming = try BackupFileIO.child("Payload/" + change.key, in: stage)
                if !BackupFileIO.exists(incoming) {
                    guard !BackupFileIO.exists(displaced) else { throw BackupFailure("Conflicting rollback data was preserved.") }
                    try FileManager.default.moveItem(at: destination, to: displaced)
                }
            }
        }
        if journal.preferences { try engine.installPreferences(BackupFileIO.read(recovery.appendingPathComponent("preferences-before.plist"), maximum: 4 * 1_024 * 1_024)) }
        journal.phase = "rolledBack"
        try BackupFileIO.write(journal, to: locations.control.appendingPathComponent("activation.json"))
        try removePendingAfter(journal, locations: locations)
    }
    private static func readPending(_ locations: BackupLocations) throws -> Pending {
        let result = try JSONDecoder().decode(Pending.self, from: BackupFileIO.read(locations.control.appendingPathComponent("pending.json"), maximum: 64 * 1_024))
        try validStage(result.stage)
        guard result.version == 1, !result.selected.isEmpty, Set(result.selected).count == result.selected.count else { throw BackupFailure("Invalid restore intent.") }
        for id in result.selected { _ = try BackupCatalog.component(id) }
        return result
    }
    private static func readJournal(_ locations: BackupLocations) throws -> Journal {
        let result = try JSONDecoder().decode(Journal.self, from: BackupFileIO.read(locations.control.appendingPathComponent("activation.json"), maximum: BackupFileIO.maximumManifest))
        try validStage(result.stage)
        guard result.version == 1, ["applying", "committed", "rollingBack", "rolledBack", "rollbackRequested", "discarding"].contains(result.phase),
              result.changes.count <= BackupFileIO.maximumFiles,
              Set(result.changes.map(\.key)).count == result.changes.count else { throw BackupFailure("Invalid restore journal. Recovery files were preserved.") }
        for change in result.changes {
            let component = try BackupCatalog.component(change.component)
            guard change.component != "preferences", BackupFileIO.validPath(change.path), component.accepts(change.path, includingContent: true),
                  !BackupFileIO.isWorkingPath(change.path) else { throw BackupFailure("Unsafe restore journal path.") }
        }
        return result
    }
    private static func validStage(_ name: String) throws {
        guard name.hasPrefix("staged-"), UUID(uuidString: String(name.dropFirst(7))) != nil else { throw BackupFailure("Invalid restore staging location.") }
    }
    private static func recoveryFolder(_ journal: Journal, locations: BackupLocations) throws -> URL {
        try BackupFileIO.child("recovery-" + journal.id.uuidString, in: locations.control)
    }
    private static func removePendingAfter(_ journal: Journal, locations: BackupLocations) throws {
        let pending = locations.control.appendingPathComponent("pending.json")
        if BackupFileIO.exists(pending) {
            let existing = try readPending(locations)
            guard existing.stage == journal.stage else { throw BackupFailure("Another pending restore exists; preserved for review.") }
            try FileManager.default.removeItem(at: pending)
        }
        // Staged files that were not selected remain until explicit recovery cleanup. Never
        // delete the source backup package or an unrelated stage during startup recovery.
    }
}
