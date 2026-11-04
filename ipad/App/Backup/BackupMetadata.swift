import Foundation
import CoreFoundation

enum BackupMetadata {
    /// Checks native JSON envelopes and referenced content before a component becomes selectable.
    /// A state-only backup is portable only when its required content is already present.
    static func issues(manifest: BackupManifest, payload: URL, locations: BackupLocations) throws -> [String: String] {
        var issues: [String: String] = [:]
        let entries = Dictionary(uniqueKeysWithValues: manifest.entries.filter { !$0.directory }.map { ($0.key, $0) })
        for selection in manifest.selections {
            do {
                let component = try BackupCatalog.component(selection.component)
                func object(_ path: String) throws -> Any? {
                    guard entries[component.id + "/" + path] != nil else { return nil }
                    let file = try BackupFileIO.child(component.id + "/" + path, in: payload)
                    let maximum: Int
                    switch component.id {
                    case "assistant", "gguf", "annotations": maximum = 32 * 1_024 * 1_024
                    case "inventory": maximum = InventoryValidation.maximumManifestBytes
                    case "catalogs": maximum = 8 * 1_024 * 1_024
                    case "benchmarks": maximum = 4_000_000
                    default: maximum = 64 * 1_024 * 1_024
                    }
                    return try JSONSerialization.jsonObject(with: BackupFileIO.read(file, maximum: maximum))
                }
                func reference(_ path: String, bytes: UInt64? = nil) throws -> URL {
                    guard BackupFileIO.validPath(path), !BackupFileIO.isWorkingPath(path) else { throw BackupFailure("Unsafe content reference.") }
                    let url: URL
                    if let entry = entries[component.id + "/" + path] {
                        if let bytes, entry.bytes != bytes { throw BackupFailure("A bundled content file has the wrong length.") }
                        url = try BackupFileIO.child(entry.key, in: payload)
                    } else {
                        let root = try component.directory(in: locations)
                        guard BackupFileIO.exists(root) else { throw BackupFailure("Required content is absent. Restore a backup with optional content included, or reinstall the matching content first.") }
                        url = try BackupFileIO.child(path, in: root)
                    }
                    guard BackupFileIO.exists(url) else { throw BackupFailure("Missing required content: \(path). Include optional content when exporting for another device.") }
                    let info = try BackupFileIO.fingerprint(url)
                    guard !info.directory, bytes == nil || UInt64(info.size) == bytes else { throw BackupFailure("Required content does not match: \(path)") }
                    return url
                }
                switch component.id {
                case "preferences":
                    if let entry = entries["preferences/preferences.plist"] {
                        _ = try BackupEngine(locations: locations).decodePreferences(BackupFileIO.read(BackupFileIO.child(entry.key, in: payload), maximum: 4 * 1_024 * 1_024))
                    }
                case "notes":
                    if let value = try object("notes.json") {
                        _ = try NotesArchive.decode(JSONSerialization.data(withJSONObject: value))
                    }
                case "inventory":
                    if let value = try object("inventory.json") {
                        let data = try JSONSerialization.data(withJSONObject: value)
                        guard data.count <= InventoryValidation.maximumManifestBytes else { throw BackupFailure("Inventory metadata exceeds its supported size.") }
                        let archive = try JSONDecoder().decode(InventoryArchive.self, from: data)
                        try InventoryValidation.archive(archive)
                        for item in archive.items {
                            for attachment in item.attachments {
                                let count = UInt64(attachment.byteCount)
                                let file = try reference("attachments/" + attachment.filename, bytes: count)
                                guard try BackupFileIO.copyAndHash(file, to: nil, expected: count) == attachment.sha256 else { throw BackupFailure("Inventory attachment checksum does not match.") }
                            }
                        }
                    }
                case "sketches":
                    if let value = try object("sketches.json") {
                        let root = try dictionary(value); try version(root, key: "version", allowed: [1])
                        let items = try records(root["sketches"]); try uniqueIDs(items)
                        for item in items {
                            try strings(item, ["title", "fileName"]); try numbers(item, ["createdAt", "updatedAt"])
                            _ = try reference(basename(item["fileName"]))
                        }
                    }
                case "library":
                    if let value = try object("library.json") {
                        let root = try dictionary(value); try version(root, key: "formatVersion", allowed: [1])
                        let rows = try records(root["records"])
                        let documents = try rows.map { row -> [String: Any] in
                            try strings(row, ["searchableText"]); return try dictionary(row["document"])
                        }
                        try uniqueIDs(documents)
                        for document in documents {
                            try strings(document, ["title", "kind", "indexingStatus"]); try numbers(document, ["importedAt"])
                            _ = try reference("Files/" + basename(document["filename"]), bytes: integer(document["byteCount"]))
                        }
                    }
                case "media":
                    if let value = try object("library.json") {
                        let root = try dictionary(value); try version(root, key: "version", allowed: [1, 2])
                        let items = try records(root["items"]); try uniqueIDs(items)
                        for item in items { try strings(item, ["title"]); _ = try reference(basename(item["fileName"]), bytes: integer(item["bytes"])) }
                        if let playlists = root["playlists"] { try uniqueIDs(records(playlists)) }
                    }
                case "lessons":
                    if let value = try object("lessons.json") {
                        let lessons = try records(value); try uniqueIDs(lessons)
                        for lesson in lessons { try strings(lesson, ["title"]); _ = try reference(basename(lesson["filename"])) }
                    }
                case "pmtiles":
                    if let value = try object("workspace.json") {
                        let root = try dictionary(value), archives = try records(root["archives"])
                        try uniqueIDs(archives); try uniqueIDs(records(root["places"]))
                        for archive in archives {
                            let id = try uuid(archive["id"])
                            _ = try reference(id.uuidString.lowercased() + ".pmtiles", bytes: integer(archive["byteCount"]))
                        }
                    }
                case "courses":
                    if let value = try object("learners-and-channels.json") {
                        let root = try dictionary(value); try version(root, key: "formatVersion", allowed: [1])
                        let courses = try records(root["courses"]); try uniqueIDs(courses); try uniqueIDs(records(root["learners"]))
                        _ = try records(root["progress"]); _ = try records(root["attempts"])
                        for course in courses {
                            let prefix = "Packages/" + (try uuid(course["id"])).uuidString
                            let file = try reference(prefix + "/course.json")
                            let package = try dictionary(JSONSerialization.jsonObject(with: BackupFileIO.read(file, maximum: 64 * 1_024 * 1_024)))
                            try version(package, key: "formatVersion", allowed: [1])
                            for node in try records(package["nodes"]) {
                                for resource in try records(node["resources"]) where (resource["available"] as? Bool) == true {
                                    let checksum = try basename(resource["checksum"]), ext = try basename(resource["fileExtension"])
                                    guard checksum.count == 32, checksum.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { throw BackupFailure("Invalid course resource checksum.") }
                                    let path = prefix + "/storage/" + checksum.prefix(1) + "/" + checksum.dropFirst().prefix(1) + "/" + checksum + "." + ext
                                    _ = try reference(path, bytes: integer(resource["byteCount"]))
                                }
                            }
                        }
                    }
                case "reference":
                    if let value = try object("dataset.json") {
                        let root = try dictionary(value); _ = try uuid(root["id"]); _ = try integer(root["labelCount"])
                        _ = try reference(basename(root["fileName"]))
                    }
                case "dashboard":
                    if let value = try object("dashboard.json") {
                        let root = try dictionary(value)
                        guard root["favorites"] is [String] else { throw BackupFailure("Invalid dashboard favorites.") }
                        try uniqueIDs(records(root["links"]))
                    }
                case "raster": if let value = try object("places.json") { try uniqueIDs(records(value)) }
                case "assistant", "gguf":
                    let isGGUF = component.id == "gguf"
                    if let value = try object(isGGUF ? "conversations.json" : "assistant-conversations.json") { try conversationArchive(value, gguf: isGGUF) }
                    if let value = try object(isGGUF ? "chat.json" : "assistant.json") { try messages(value, gguf: isGGUF) }
                    if isGGUF, let value = try object("benchmarks.json") { _ = try records(value) }
                case "annotations":
                    if let value = try object("marks.json") {
                        let data = try JSONSerialization.data(withJSONObject: value)
                        guard data.count <= 32 * 1_024 * 1_024 else { throw BackupFailure("Reading marks exceed their supported size.") }
                        let marks = try JSONDecoder().decode([ReadingMark].self, from: data)
                        guard marks.count <= 2_000, Set(marks.map(\.id)).count == marks.count else { throw BackupFailure("Invalid reading mark count or duplicate IDs.") }
                        for mark in marks { try mark.validate() }
                    }
                case "knowledge", "benchmarks", "catalogs":
                    // Native stores continue enforcing their versioned model schemas on launch.
                    // Validate every known JSON envelope here; never treat unreadable data as empty.
                    for path in component.stateFiles ?? [] {
                        if let value = try object(path), !(value is [String: Any]) && !(value is [Any]) { throw BackupFailure("Invalid native JSON envelope: \(path)") }
                    }
                default: break // Workspace bytes are user documents, not app metadata.
                }
            } catch { issues[selection.component] = error.localizedDescription }
        }
        return issues
    }
    private static func dictionary(_ value: Any?) throws -> [String: Any] {
        guard let result = value as? [String: Any] else { throw BackupFailure("Invalid native metadata object.") }; return result
    }
    private static func records(_ value: Any?) throws -> [[String: Any]] {
        guard let rows = value as? [[String: Any]], rows.count <= 100_000 else { throw BackupFailure("Invalid native metadata record list.") }; return rows
    }
    private static func integer(_ value: Any?) throws -> UInt64 {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
              number.doubleValue >= 0, number.doubleValue.rounded() == number.doubleValue,
              number.doubleValue <= Double(BackupFileIO.maximumBytes) else { throw BackupFailure("Invalid native count or file length.") }
        return number.uint64Value
    }
    private static func version(_ object: [String: Any], key: String, allowed: Set<UInt64>) throws {
        guard allowed.contains(try integer(object[key])) else { throw BackupFailure("Unsupported native data version.") }
    }
    private static func basename(_ value: Any?) throws -> String {
        guard let name = value as? String, BackupFileIO.validPath(name), !name.contains("/") else { throw BackupFailure("Unsafe native file reference.") }; return name
    }
    private static func uuid(_ value: Any?) throws -> UUID {
        guard let text = value as? String, let id = UUID(uuidString: text) else { throw BackupFailure("Invalid native record identifier.") }; return id
    }
    private static func uniqueIDs(_ rows: [[String: Any]]) throws {
        let identifiers = try rows.map { try uuid($0["id"]) }
        guard Set(identifiers).count == identifiers.count else { throw BackupFailure("Duplicate native record identifiers.") }
    }
    private static func strings(_ value: [String: Any], _ keys: [String]) throws {
        guard keys.allSatisfy({ value[$0] is String }) else { throw BackupFailure("A native text field is missing.") }
    }
    private static func numbers(_ value: [String: Any], _ keys: [String]) throws {
        guard keys.allSatisfy({
            guard let number = value[$0] as? NSNumber else { return false }
            return CFGetTypeID(number) != CFBooleanGetTypeID() && number.doubleValue.isFinite
        }) else { throw BackupFailure("A native date field is missing or invalid.") }
    }
    private static func conversationArchive(_ value: Any, gguf: Bool) throws {
        let root = try dictionary(value)
        try version(root, key: "version", allowed: [1])
        let conversations = try records(root["conversations"])
        try uniqueIDs(conversations)
        let selected = try uuid(root["selectedID"])
        guard (1...500).contains(conversations.count), try conversations.contains(where: { try uuid($0["id"]) == selected }) else { throw BackupFailure("Invalid selected conversation or archive size.") }
        for conversation in conversations {
            guard let title = conversation["title"] as? String, !title.isEmpty, title.count <= 120 else { throw BackupFailure("Invalid conversation title.") }
            try numbers(conversation, ["createdAt", "updatedAt"])
            let settings = try dictionary(conversation["settings"])
            guard let instructions = settings["instructions"] as? String, instructions.count <= 1_000,
                  try integer(settings["historyMessages"]) <= 12,
                  (32...512).contains(try integer(settings["responseTokens"])),
                  let temperature = settings["temperature"] as? NSNumber,
                  CFGetTypeID(temperature) != CFBooleanGetTypeID(), temperature.doubleValue.isFinite,
                  (0...1).contains(temperature.doubleValue),
                  ["useLibrary", "semantic"].allSatisfy({ key in
                      (settings[key] as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } == true
                  }) else { throw BackupFailure("Invalid conversation settings.") }
            try messages(conversation["messages"], gguf: gguf)
        }
    }
    private static func messages(_ value: Any?, gguf: Bool) throws {
        let rows = try records(value); try uniqueIDs(rows)
        guard rows.count <= 20_000 else { throw BackupFailure("Too many conversation messages.") }
        for message in rows {
            guard let role = message["role"] as? String, ["user", "assistant"].contains(role),
                  let text = message["text"] as? String, text.count <= 1_000_000 else { throw BackupFailure("Invalid saved conversation message.") }
            let sources: [[String: Any]]
            if let value = message["sources"] { sources = try records(value) }
            else if gguf { sources = [] }
            else { throw BackupFailure("Missing saved assistant source list.") }
            guard sources.count <= 3 else { throw BackupFailure("Too many saved source passages.") }
            var identifiers = Set<String>()
            for source in sources {
                _ = try uuid(source["documentID"])
                guard let id = source["id"] as? String, id.count <= 512, (!gguf || !id.isEmpty), identifiers.insert(id).inserted,
                      let title = source["title"] as? String, title.count <= (gguf ? 120 : 1_000),
                      let excerpt = source["excerpt"] as? String, excerpt.count <= (gguf ? 900 : 4_000) else { throw BackupFailure("Invalid saved source passage.") }
            }
            if let notice = message["notice"], !(notice is String) { throw BackupFailure("Invalid saved conversation notice.") }
            if let used = message["usedLibrary"] {
                guard let number = used as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw BackupFailure("Invalid saved library-answer flag.") }
            }
        }
    }
}
