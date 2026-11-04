import Foundation
import CryptoKit
import CoreFoundation

/// File-only engine. All inputs/outputs are injectable for isolated regression tests.
struct BackupEngine: @unchecked Sendable {
    let locations: BackupLocations
    let defaults: UserDefaults
    let availableBytes: (@Sendable () throws -> UInt64)?
    init(locations: BackupLocations = .live, defaults: UserDefaults = .standard,
         availableBytes: (@Sendable () throws -> UInt64)? = nil) {
        self.locations = locations; self.defaults = defaults; self.availableBytes = availableBytes
    }
    private final class Counter: @unchecked Sendable { var bytes: UInt64 = 0 }

    func export(selections: [BackupSelection], progress: @escaping @Sendable (BackupProgress) -> Void = { _ in }) throws -> URL {
        try validateSelections(selections)
        try BackupFileIO.prepare(locations.exports)
        var snapshots: [String: [String: BackupFileIO.Fingerprint]] = [:]
        var total: UInt64 = 0
        for selection in selections where selection.component != "preferences" {
            let files = try inventory(selection)
            snapshots[selection.component] = files
            for value in files.values where !value.directory { total = try adding(total, UInt64(value.size)) }
        }
        guard snapshots.values.reduce(0, { $0 + $1.count }) + 1 <= BackupFileIO.maximumFiles else { throw BackupFailure("The selected backup exceeds 100,000 entries.") }
        let includesPreferences = selections.contains(where: { $0.component == "preferences" })
        let preferences = includesPreferences ? try preferenceData() : Data()
        if includesPreferences { total = try adding(total, UInt64(preferences.count)) }
        try BackupFileIO.capacity(locations.exports, additional: total, available: availableBytes)
        let id = UUID(), stage = locations.exports.appendingPathComponent(".export-\(UUID().uuidString)")
        let output = locations.exports.appendingPathComponent("NOMAD-\(id.uuidString).nomadbackup", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        var complete = false
        defer { if !complete { try? FileManager.default.removeItem(at: stage) } }
        let payload = stage.appendingPathComponent("Payload", isDirectory: true)
        try BackupFileIO.prepare(payload)
        var entries: [BackupEntry] = []
        let counter = Counter(), totalBytes = total
        for selection in selections {
            try Task.checkCancellation()
            let component = try BackupCatalog.component(selection.component)
            if component.id == "preferences" {
                let target = try BackupFileIO.child("preferences/preferences.plist", in: payload, createParents: true)
                try preferences.write(to: target, options: .withoutOverwriting)
                entries.append(.init(component: component.id, path: "preferences.plist", directory: false,
                                     bytes: UInt64(preferences.count), sha256: SHA256.hash(data: preferences).map { String(format: "%02x", $0) }.joined()))
                counter.bytes += UInt64(preferences.count)
                continue
            }
            for (path, info) in (snapshots[component.id] ?? [:]).sorted(by: { $0.key < $1.key }) {
                try Task.checkCancellation()
                let destination = try BackupFileIO.child(component.id + "/" + path, in: payload, createParents: true)
                if info.directory {
                    try BackupFileIO.prepare(destination)
                    entries.append(.init(component: component.id, path: path, directory: true, bytes: 0, sha256: nil))
                } else {
                    let source = try BackupFileIO.child(path, in: component.directory(in: locations))
                    let hash = try BackupFileIO.copyAndHash(source, to: destination, expected: UInt64(info.size), checkStorage: {
                        try BackupFileIO.capacity(stage, additional: 0, available: availableBytes)
                    }) { count in
                        counter.bytes += count
                        progress(.init(message: "Backing up \(component.title)", completedBytes: counter.bytes, totalBytes: totalBytes))
                    }
                    entries.append(.init(component: component.id, path: path, directory: false, bytes: UInt64(info.size), sha256: hash))
                }
            }
        }
        // A metadata or file-list change invalidates the entire snapshot, without publishing it.
        for selection in selections where selection.component != "preferences" {
            guard try inventory(selection) == snapshots[selection.component] else { throw BackupFailure("\(selection.component) changed during backup. Close its editor and retry.") }
        }
        if selections.contains(where: { $0.component == "preferences" }),
           !NSDictionary(dictionary: try decodePreferences(preferences)).isEqual(to: try decodePreferences(preferenceData())) {
            throw BackupFailure("App preferences changed during backup. Retry after finishing the change.")
        }
        let manifest = BackupManifest(id: id, createdAt: Date(), appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
                                      selections: selections, entries: entries, exclusions: BackupCatalog.exclusions)
        try validateManifest(manifest)
        try BackupFileIO.write(manifest, to: stage.appendingPathComponent("manifest.json"))
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: stage, to: output)
        complete = true
        progress(.init(message: "Backup saved in Files → On My iPad → NOMAD → Backups", completedBytes: total, totalBytes: total))
        return output
    }

    /// Reads bounded metadata for review before any large payload is copied. Hash validation
    /// happens during stageSelected, so this preliminary review is not an integrity verdict.
    func inspect(_ source: URL) throws -> BackupReview {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let manifest = try readManifest(source)
        let payload = try BackupFileIO.child("Payload", in: source)
        let issues = try BackupMetadata.issues(manifest: manifest, payload: payload, locations: locations)
        return BackupReview(manifest: manifest, directory: source, issues: issues)
    }
    /// Imports only reviewed components to a private UUID directory. No live data is changed.
    func stageSelected(_ source: URL, selected: Set<String>?, progress: @escaping @Sendable (BackupProgress) -> Void = { _ in }) throws -> BackupReview {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var result: Result<BackupReview, Error>?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { url in
            result = Result { try stageCoordinated(url, selected: selected, progress: progress) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw BackupFailure("The selected backup folder could not be read.") }
        return try result.get()
    }
    private func stageCoordinated(_ source: URL, selected: Set<String>?, progress: @escaping @Sendable (BackupProgress) -> Void) throws -> BackupReview {
        guard try BackupFileIO.fingerprint(source).directory else { throw BackupFailure("Choose the complete .nomadbackup folder.") }
        let original = try readManifest(source)
        let selected = selected ?? Set(original.selections.map(\.component))
        guard !selected.isEmpty, selected.isSubset(of: Set(original.selections.map(\.component))) else { throw BackupFailure("Choose components present in this backup.") }
        let manifest = BackupManifest(id: original.id, createdAt: original.createdAt, appVersion: original.appVersion,
                                      selections: original.selections.filter { selected.contains($0.component) },
                                      entries: original.entries.filter { selected.contains($0.component) }, exclusions: original.exclusions)
        let sourcePayload = try BackupFileIO.child("Payload", in: source)
        try validatePayloadShape(original, payload: sourcePayload)
        try BackupFileIO.prepare(locations.control)
        try BackupFileIO.capacity(locations.control, additional: manifest.totalBytes, available: availableBytes)
        let stage = locations.control.appendingPathComponent("staged-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        var complete = false
        defer { if !complete { try? FileManager.default.removeItem(at: stage) } }
        let payload = stage.appendingPathComponent("Payload", isDirectory: true)
        try BackupFileIO.prepare(payload)
        let counter = Counter()
        for entry in manifest.entries.sorted(by: { $0.key < $1.key }) {
            try Task.checkCancellation()
            let destination = try BackupFileIO.child(entry.key, in: payload, createParents: true)
            if entry.directory { try BackupFileIO.prepare(destination); continue }
            let sourceFile = try BackupFileIO.child(entry.key, in: sourcePayload)
            let hash = try BackupFileIO.copyAndHash(sourceFile, to: destination, expected: entry.bytes, checkStorage: {
                try BackupFileIO.capacity(stage, additional: 0, available: availableBytes)
            }) { bytes in
                counter.bytes += bytes
                progress(.init(message: "Validating \(entry.component)", completedBytes: counter.bytes, totalBytes: manifest.totalBytes))
            }
            guard hash == entry.sha256 else { throw BackupFailure("Checksum mismatch for \(entry.key). Existing app data has not changed.") }
        }
        try BackupFileIO.write(manifest, to: stage.appendingPathComponent("manifest.json"))
        let issues = try BackupMetadata.issues(manifest: manifest, payload: payload, locations: locations)
        complete = true
        return BackupReview(manifest: manifest, directory: stage, issues: issues)
    }
    func readManifest(_ folder: URL) throws -> BackupManifest {
        let url = try BackupFileIO.child("manifest.json", in: folder)
        let manifest = try JSONDecoder().decode(BackupManifest.self, from: BackupFileIO.read(url, maximum: BackupFileIO.maximumManifest))
        try validateManifest(manifest)
        return manifest
    }
    func validateManifest(_ manifest: BackupManifest) throws {
        guard manifest.formatVersion == 1, manifest.entries.count <= BackupFileIO.maximumFiles,
              manifest.appVersion.utf8.count <= 256, manifest.exclusions.count <= 100 else { throw BackupFailure("Unsupported backup version or excessive manifest size.") }
        try validateSelections(manifest.selections)
        let selected = Dictionary(uniqueKeysWithValues: manifest.selections.map { ($0.component, $0.includeContent) })
        var seen = Set<String>(), destinations = Set<String>(), total: UInt64 = 0
        for entry in manifest.entries {
            guard BackupFileIO.validPath(entry.path), let includeContent = selected[entry.component] else { throw BackupFailure("A backup file has an unsafe path or unselected component.") }
            let component = try BackupCatalog.component(entry.component)
            guard component.accepts(entry.path, includingContent: includeContent) || (entry.directory && component.hasOptionalContent && includeContent) || (entry.directory && component.stateFiles == nil) else {
                throw BackupFailure("The backup contains a file outside its declared component: \(entry.key)")
            }
            let canonical = entry.key.precomposedStringWithCanonicalMapping.lowercased()
            let actual = (component.documents ? "documents/" : "support/") + component.root + "/" + entry.path
            guard seen.insert(canonical).inserted, destinations.insert(actual.precomposedStringWithCanonicalMapping.lowercased()).inserted,
                  !BackupFileIO.isWorkingPath(entry.path) else { throw BackupFailure("Duplicate, conflicting or temporary backup file.") }
            if entry.directory { guard entry.bytes == 0, entry.sha256 == nil else { throw BackupFailure("Invalid backup folder record.") } }
            else {
                guard let hash = entry.sha256, hash.count == 64, hash.allSatisfy({ $0.isASCII && $0.isHexDigit && !$0.isUppercase }) else { throw BackupFailure("Missing or invalid backup checksum.") }
                total = try adding(total, entry.bytes)
            }
        }
        let files = Set(manifest.entries.filter { !$0.directory }.map { $0.key.precomposedStringWithCanonicalMapping.lowercased() })
        for entry in manifest.entries {
            let parts = entry.key.precomposedStringWithCanonicalMapping.lowercased().split(separator: "/")
            for depth in 1..<parts.count where files.contains(parts.prefix(depth).joined(separator: "/")) { throw BackupFailure("A backup file is also used as a folder.") }
        }
    }
    func validatePayloadShape(_ manifest: BackupManifest, payload: URL) throws {
        let files = try BackupFileIO.tree(payload)
        let declared = Dictionary(uniqueKeysWithValues: manifest.entries.map { ($0.key, $0) })
        var parents = Set<String>()
        for key in declared.keys {
            let parts = key.split(separator: "/")
            for depth in 1..<parts.count { parents.insert(parts.prefix(depth).joined(separator: "/")) }
        }
        for (path, info) in files {
            if let entry = declared[path] {
                guard info.directory == entry.directory, info.directory || UInt64(info.size) == entry.bytes else { throw BackupFailure("Backup file type/size does not match its manifest.") }
            } else {
                guard info.directory, parents.contains(path) else { throw BackupFailure("Undeclared file in backup package: \(path)") }
            }
        }
        guard declared.keys.allSatisfy({ files[$0] != nil }) else { throw BackupFailure("The backup is missing a declared file.") }
    }
    func inventory(_ selection: BackupSelection) throws -> [String: BackupFileIO.Fingerprint] {
        let component = try BackupCatalog.component(selection.component), root = try component.directory(in: locations)
        guard BackupFileIO.exists(root) else { return [:] }
        guard try BackupFileIO.fingerprint(root).directory else { throw BackupFailure("A component root is not a folder.") }
        if component.stateFiles == nil || (selection.includeContent && component.contentPrefix == "") {
            let result = try BackupFileIO.tree(root)
            guard !result.keys.contains(where: BackupFileIO.isWorkingPath) else { throw BackupFailure("An import/delete is in progress in \(component.title). Retry after it finishes.") }
            return result
        }
        var result: [String: BackupFileIO.Fingerprint] = [:]
        for name in component.stateFiles ?? [] {
            let url = try BackupFileIO.child(name, in: root)
            if BackupFileIO.exists(url) {
                let info = try BackupFileIO.fingerprint(url)
                guard !info.directory else { throw BackupFailure("Expected a metadata file in \(component.title).") }
                result[name] = info
            }
        }
        if selection.includeContent {
            if let prefix = component.contentPrefix, !prefix.isEmpty {
                let folder = try BackupFileIO.child(prefix, in: root)
                if BackupFileIO.exists(folder) {
                    result[prefix] = try BackupFileIO.fingerprint(folder)
                    for (path, value) in try BackupFileIO.tree(folder) { result[prefix + "/" + path] = value }
                }
            }
            if component.contentExtensions != nil {
                for name in try FileManager.default.contentsOfDirectory(atPath: root.path) where component.accepts(name, includingContent: true) {
                    let url = try BackupFileIO.child(name, in: root), info = try BackupFileIO.fingerprint(url)
                    guard !info.directory else { throw BackupFailure("A content file is unexpectedly a directory.") }
                    result[name] = info
                }
            }
        }
        guard !result.keys.contains(where: BackupFileIO.isWorkingPath) else { throw BackupFailure("An import/delete is in progress in \(component.title). Retry after it finishes.") }
        return result
    }
    func preferenceData() throws -> Data {
        let saved = defaults.dictionaryRepresentation().filter { BackupCatalog.allowedPreference($0.key) }
        let data = try PropertyListSerialization.data(fromPropertyList: saved, format: .binary, options: 0)
        _ = try decodePreferences(data)
        return data
    }
    func decodePreferences(_ data: Data) throws -> [String: Any] {
        guard data.count <= 4 * 1_024 * 1_024,
              let values = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              values.count <= 10_000, values.keys.allSatisfy(BackupCatalog.allowedPreference) else { throw BackupFailure("Invalid or unapproved preference backup.") }
        let booleans: Set<String> = ["assistant.semanticRetrieval", "NomadGGUFUseGPU", "NomadGGUFUseLibrary", "NomadGGUFSemanticRetrieval"]
        for (key, value) in values {
            if booleans.contains(key) {
                guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw BackupFailure("Invalid Boolean app preference.") }
            } else if ["offline.lastManualCheck", "epub.reader.zoom"].contains(key) {
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
                      key != "epub.reader.zoom" || (0.25...4).contains(number.doubleValue) else { throw BackupFailure("Invalid numeric app preference.") }
            } else if key.hasPrefix("epub.position.") {
                guard let data = value as? Data, data.count <= 32_768,
                      let position = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let path = position["path"] as? String, BackupFileIO.validPath(path),
                      let fraction = position["fraction"] as? NSNumber, CFGetTypeID(fraction) != CFBooleanGetTypeID(),
                      fraction.doubleValue.isFinite, (0...1).contains(fraction.doubleValue),
                      position["fragment"] == nil || position["fragment"] is String else { throw BackupFailure("Invalid EPUB reading position.") }
            } else if key == "notes.sort" {
                guard let text = value as? String, ["modified", "created", "title"].contains(text) else { throw BackupFailure("Invalid note sort setting.") }
            } else if key == "notes.homeQuery" {
                guard let text = value as? String else { throw BackupFailure("Invalid note home search.") }
                _ = try NoteQuery(text)
            } else {
                guard let text = value as? String, text.utf8.count <= 16_384 else { throw BackupFailure("Invalid text app preference.") }
            }
        }
        return values
    }
    func installPreferences(_ data: Data) throws {
        let values = try decodePreferences(data)
        for key in defaults.dictionaryRepresentation().keys where BackupCatalog.allowedPreference(key) { defaults.removeObject(forKey: key) }
        for (key, value) in values { defaults.set(value, forKey: key) }
        guard defaults.synchronize() else { throw BackupFailure("Restored preferences could not be synchronized.") }
    }
    func validateSelections(_ selections: [BackupSelection]) throws {
        guard !selections.isEmpty, selections.count <= BackupCatalog.components.count,
              Set(selections.map(\.component)).count == selections.count else { throw BackupFailure("Select valid, unique backup components.") }
        for value in selections {
            let item = try BackupCatalog.component(value.component)
            guard !value.includeContent || item.hasOptionalContent else { throw BackupFailure("This component has no optional content selection.") }
        }
    }
    func adding(_ left: UInt64, _ right: UInt64) throws -> UInt64 {
        let (sum, overflow) = left.addingReportingOverflow(right)
        guard !overflow, sum <= BackupFileIO.maximumBytes else { throw BackupFailure("The backup exceeds the supported 10 TB size.") }
        return sum
    }
}
