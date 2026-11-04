import Foundation

struct BackupFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct BackupLocations: Sendable {
    let support: URL
    let documents: URL
    var control: URL { support.appendingPathComponent("NomadPad/BackupControl", isDirectory: true) }
    var exports: URL { documents.appendingPathComponent("Backups", isDirectory: true) }
    static var live: Self { Self(support: .applicationSupportDirectory, documents: .documentsDirectory) }
}

struct BackupComponent: Identifiable, Sendable {
    let id: String
    let title: String
    let description: String
    let documents: Bool
    let root: String
    /// nil means every normal file is irreplaceable state (workspace/drawings).
    let stateFiles: Set<String>?
    let contentPrefix: String?
    let contentExtensions: Set<String>?
    var hasOptionalContent: Bool { contentPrefix != nil || contentExtensions != nil }
    func directory(in locations: BackupLocations) throws -> URL {
        // Resolve only trusted catalog components, never archive-supplied paths. On a
        // case-insensitive simulator volume Foundation needs the actual on-disk spelling.
        // This lookup does not create folders while exporting or reviewing a backup.
        var current = documents ? locations.documents : locations.support
        for component in root.split(separator: "/").map(String.init) {
            if BackupFileIO.exists(current) {
                current = try CollectionStorageDirectory.existingSpelling(of: component, in: current)
            } else {
                current.appendPathComponent(component, isDirectory: true)
            }
        }
        return current
    }
    func accepts(_ path: String, includingContent: Bool) -> Bool {
        if let stateFiles, stateFiles.contains(path) { return true }
        if stateFiles == nil { return true }
        guard includingContent else { return false }
        if let contentPrefix, contentPrefix.isEmpty || path.hasPrefix(contentPrefix + "/") { return true }
        return contentExtensions?.contains((path as NSString).pathExtension.lowercased()) == true
    }
}

enum BackupCatalog {
    static let components: [BackupComponent] = [
        .init(id: "notes", title: "Notes", description: "Titles, text and dates", documents: false, root: "Nomad/Notes", stateFiles: ["notes.json"], contentPrefix: nil, contentExtensions: nil),
        .init(id: "inventory", title: "Inventory", description: "Items, tags, quantities, purchase/warranty metadata and attachments", documents: false, root: "NOMAD/Collections/inventory", stateFiles: nil, contentPrefix: nil, contentExtensions: nil),
        .init(id: "sketches", title: "Sketchbook", description: "Editable drawings and their titles", documents: false, root: "NOMAD/Collections/sketches", stateFiles: nil, contentPrefix: nil, contentExtensions: nil),
        .init(id: "workspace", title: "Files workspace", description: "All user files and folders, including exported web-tool documents", documents: true, root: "Workspace", stateFiles: nil, contentPrefix: nil, contentExtensions: nil),
        .init(id: "dashboard", title: "Dashboard", description: "Favorites and custom links", documents: false, root: "NomadPad", stateFiles: ["dashboard.json"], contentPrefix: nil, contentExtensions: nil),
        .init(id: "assistant", title: "Apple assistant conversations", description: "Conversation archives and retained migration history", documents: false, root: "NomadPad", stateFiles: ["assistant.json", "assistant-conversations.json"], contentPrefix: nil, contentExtensions: nil),
        .init(id: "gguf", title: "GGUF conversations and models", description: "Conversations, sources and benchmarks; model files are optional", documents: false, root: "NomadPad/GGUF", stateFiles: ["chat.json", "conversations.json", "benchmarks.json"], contentPrefix: "Models", contentExtensions: nil),
        .init(id: "knowledge", title: "Knowledge collections", description: "Selected sources and saved semantic index", documents: false, root: "NomadPad/Knowledge", stateFiles: ["collections.json", "index.json"], contentPrefix: nil, contentExtensions: nil),
        .init(id: "catalogs", title: "Custom content catalogs", description: "OPDS configuration and acquisition provenance; cached pages are optional", documents: false, root: "NomadPad/Catalogs", stateFiles: ["catalogs.json"], contentPrefix: "Cache", contentExtensions: nil),
        .init(id: "annotations", title: "Reading annotations", description: "Saved bookmarks and reading notes", documents: false, root: "NomadPad/ReadingAnnotations", stateFiles: ["marks.json"], contentPrefix: nil, contentExtensions: nil),
        .init(id: "library", title: "Knowledge library", description: "Document catalog and extracted text; imported archives/books are optional", documents: false, root: "Nomad/Library", stateFiles: ["library.json"], contentPrefix: "Files", contentExtensions: nil),
        .init(id: "media", title: "Media playlists and progress", description: "Catalog, playlists and playback positions; media files are optional", documents: false, root: "NOMAD/Collections/media", stateFiles: ["library.json"], contentPrefix: "", contentExtensions: nil),
        .init(id: "courses", title: "Courses and learners", description: "Learners, progress and exercise answers; channel packages are optional", documents: false, root: "NomadPad/Courses", stateFiles: ["learners-and-channels.json"], contentPrefix: "Packages", contentExtensions: nil),
        .init(id: "lessons", title: "Loose lessons", description: "Lesson catalog and completion; lesson files are optional", documents: false, root: "NomadPad/Lessons", stateFiles: ["lessons.json"], contentPrefix: "", contentExtensions: nil),
        .init(id: "pmtiles", title: "Vector maps and saved places", description: "Map catalog and saved places; PMTiles archives are optional", documents: false, root: "NomadPad/PMTiles", stateFiles: ["workspace.json"], contentPrefix: nil, contentExtensions: ["pmtiles"]),
        .init(id: "raster", title: "Raster map and places", description: "Saved places; current MBTiles map is optional", documents: false, root: "NomadPad/Maps", stateFiles: ["places.json"], contentPrefix: nil, contentExtensions: ["mbtiles"]),
        .init(id: "reference", title: "Drug reference dataset", description: "Source metadata; imported read-only dataset is optional", documents: false, root: "NOMAD/Reference", stateFiles: ["dataset.json"], contentPrefix: nil, contentExtensions: ["sqlite"]),
        .init(id: "benchmarks", title: "Benchmark history", description: "Saved results and builder tags; working test files excluded", documents: false, root: "NomadPad/Benchmarks", stateFiles: ["history.json"], contentPrefix: nil, contentExtensions: nil),
        .init(id: "preferences", title: "App preferences and reading positions", description: "Allowlisted assistant, EPUB, translation and preparation settings", documents: false, root: "", stateFiles: ["preferences.plist"], contentPrefix: nil, contentExtensions: nil)
    ]
    static func component(_ id: String) throws -> BackupComponent {
        guard let item = components.first(where: { $0.id == id }) else { throw BackupFailure("Unknown backup component: \(id)") }
        return item
    }
    static let exclusions = ["Vault secrets and Keychain items: use Vault’s encrypted recovery export.",
        "All download queue/files/resume/temporary state: the active download queue is preserved.",
        "Unsaved web-editor drafts, browser storage/cookies, caches and temporary work: export documents to Files first.",
        "Apple system/translation models, app binaries, signing credentials and device permissions.",
        "Files outside the app’s Workspace and selected native stores; existing backup/recovery packages."]
    static func allowedPreference(_ key: String) -> Bool {
        ["assistant.semanticRetrieval", "assistant.customPrompt", "offline.manualChecks", "offline.lastManualCheck",
         "tools.translation.source", "tools.translation.target", "epub.reader.zoom", "NomadGGUFUseGPU",
         "NomadGGUFUseLibrary", "NomadGGUFSemanticRetrieval", "NomadGGUFSelectedModel",
         "notes.sort", "notes.homeQuery"].contains(key)
        || (key.hasPrefix("epub.position.") && key.utf8.count <= 512 && !key.contains("\0"))
    }
}

struct BackupSelection: Codable, Hashable, Sendable {
    let component: String
    let includeContent: Bool
}
struct BackupEntry: Codable, Equatable, Sendable {
    let component: String
    let path: String
    let directory: Bool
    let bytes: UInt64
    let sha256: String?
    var key: String { component + "/" + path }
}
struct BackupManifest: Codable, Sendable {
    var formatVersion = 1
    let id: UUID
    let createdAt: Date
    let appVersion: String
    let selections: [BackupSelection]
    let entries: [BackupEntry]
    let exclusions: [String]
    var totalBytes: UInt64 { entries.reduce(0) { $0 + $1.bytes } }
}
struct BackupReview: Identifiable, Sendable {
    let manifest: BackupManifest
    let directory: URL
    let issues: [String: String]
    var id: UUID { manifest.id }
}
struct BackupProgress: Sendable {
    let message: String
    let completedBytes: UInt64
    let totalBytes: UInt64
}
