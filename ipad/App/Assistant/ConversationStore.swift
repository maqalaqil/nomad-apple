import Foundation
import Observation

struct ConversationSettings: Codable, Equatable {
    var useLibrary = true
    var semantic = false
    var instructions = ""
    var historyMessages = 4
    var responseTokens = 256
    var temperature = 0.2

    func validate() throws {
        guard instructions.count <= 1_000, (0...12).contains(historyMessages),
              (32...512).contains(responseTokens), temperature.isFinite, (0...1).contains(temperature)
        else { throw CocoaError(.fileReadCorruptFile) }
    }
}

struct SavedConversation<Message: Codable>: Codable, Identifiable {
    var id = UUID()
    var title = "New conversation"
    var createdAt = Date()
    var updatedAt = Date()
    var settings = ConversationSettings()
    var messages: [Message] = []
}

private struct ConversationArchive<Message: Codable>: Codable {
    var version = 1
    var selectedID: UUID
    var conversations: [SavedConversation<Message>]
}

/// The original single-chat file is never changed. A corrupt archive blocks writes,
/// and a second writer cannot silently replace a newer archive loaded elsewhere.
@MainActor @Observable
final class ConversationStore<Message: Codable> {
    private(set) var conversations: [SavedConversation<Message>] = []
    private(set) var selectedID: UUID?
    private(set) var isReady = false
    private(set) var error: String?
    @ObservationIgnored private let url: URL
    @ObservationIgnored private let legacyURL: URL
    @ObservationIgnored private let defaultSettings: ConversationSettings
    @ObservationIgnored private let validateMessages: ([Message]) throws -> Void
    @ObservationIgnored private var snapshot: Data?
    @ObservationIgnored var mutationAllowed: () -> Bool = { true }
    private let maximumBytes = 32 * 1_024 * 1_024

    var selected: SavedConversation<Message>? { conversations.first { $0.id == selectedID } }

    init(url: URL, legacyURL: URL, defaults: ConversationSettings = .init(), validate: @escaping ([Message]) throws -> Void) {
        self.url = url; self.legacyURL = legacyURL; self.defaultSettings = defaults; self.validateMessages = validate
        reload()
    }

    func reload() {
        guard mutationAllowed() else { error = "Stop the current operation before reloading conversations."; return }
        isReady = false; error = nil
        do {
            let data = try read(url)
            let archive: ConversationArchive<Message>
            if let data { archive = try JSONDecoder().decode(ConversationArchive<Message>.self, from: data) }
            else {
                let legacy = try read(legacyURL).map { try JSONDecoder().decode([Message].self, from: $0) } ?? []
                var first = SavedConversation<Message>(settings: defaultSettings, messages: legacy)
                if !legacy.isEmpty { first.title = "Previous conversation" }
                archive = ConversationArchive(selectedID: first.id, conversations: [first])
            }
            try validate(archive)
            snapshot = data
            conversations = archive.conversations; selectedID = archive.selectedID
            isReady = true
        } catch { self.error = "Saved conversations could not be opened. Original files are preserved. \(error.localizedDescription)" }
    }

    func create() throws {
        var next = SavedConversation<Message>(settings: selected?.settings ?? defaultSettings)
        next.title = "New conversation"
        try commit(ConversationArchive(selectedID: next.id, conversations: [next] + conversations))
    }

    func select(_ id: UUID) throws {
        guard conversations.contains(where: { $0.id == id }) else { throw CocoaError(.fileNoSuchFile) }
        try commit(ConversationArchive(selectedID: id, conversations: conversations))
    }

    func rename(_ id: UUID, to title: String) throws {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 120 else { throw CocoaError(.fileWriteInvalidFileName) }
        try change(id) { $0.title = title }
    }

    func update(messages: [Message], titleSuggestion: String? = nil) throws {
        guard let selectedID else { throw CocoaError(.fileNoSuchFile) }
        try update(id: selectedID, messages: messages, titleSuggestion: titleSuggestion)
    }

    func update(id: UUID, messages: [Message], titleSuggestion: String? = nil) throws {
        try change(id) {
            $0.messages = messages
            if $0.title == "New conversation", let titleSuggestion, !titleSuggestion.isEmpty {
                $0.title = String(titleSuggestion.prefix(80))
            }
        }
    }

    func update(settings: ConversationSettings) throws {
        guard let selectedID else { throw CocoaError(.fileNoSuchFile) }
        try settings.validate()
        try change(selectedID) { $0.settings = settings }
    }

    func delete(_ id: UUID) throws {
        guard conversations.contains(where: { $0.id == id }) else { throw CocoaError(.fileNoSuchFile) }
        var remaining = conversations.filter { $0.id != id }
        if remaining.isEmpty { remaining = [SavedConversation(settings: defaultSettings)] }
        let selection = selectedID == id ? remaining[0].id : (selectedID ?? remaining[0].id)
        try commit(ConversationArchive(selectedID: selection, conversations: remaining))
    }

    func export(_ id: UUID) throws -> URL {
        guard let conversation = conversations.first(where: { $0.id == id }) else { throw CocoaError(.fileNoSuchFile) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ConversationExports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("NOMAD-conversation-\(id.uuidString).json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(ConversationArchive(selectedID: id, conversations: [conversation])).write(to: destination, options: .atomic)
        return destination
    }

    func importConversation(_ source: URL) throws {
        guard let data = try read(source) else { throw CocoaError(.fileNoSuchFile) }
        let incoming = try JSONDecoder().decode(ConversationArchive<Message>.self, from: data)
        try validate(incoming)
        var additions = incoming.conversations
        for index in additions.indices { additions[index].id = UUID(); additions[index].updatedAt = Date() }
        try commit(ConversationArchive(selectedID: additions[0].id, conversations: additions + conversations))
    }

    private func change(_ id: UUID, _ mutation: (inout SavedConversation<Message>) -> Void) throws {
        var next = conversations
        guard let index = next.firstIndex(where: { $0.id == id }), let selectedID else { throw CocoaError(.fileNoSuchFile) }
        mutation(&next[index]); next[index].updatedAt = Date()
        try commit(ConversationArchive(selectedID: selectedID, conversations: next))
    }

    private func validate(_ archive: ConversationArchive<Message>) throws {
        guard archive.version == 1, (1...500).contains(archive.conversations.count),
              Set(archive.conversations.map(\.id)).count == archive.conversations.count,
              archive.conversations.contains(where: { $0.id == archive.selectedID }) else { throw CocoaError(.fileReadCorruptFile) }
        for item in archive.conversations {
            guard !item.title.isEmpty, item.title.count <= 120, item.messages.count <= 20_000,
                  item.createdAt.timeIntervalSince1970.isFinite, item.updatedAt.timeIntervalSince1970.isFinite
            else { throw CocoaError(.fileReadCorruptFile) }
            try item.settings.validate(); try validateMessages(item.messages)
        }
    }

    private func read(_ source: URL) throws -> Data? {
        let fm = FileManager.default
        if (try? fm.attributesOfItem(atPath: source.path)[.type] as? FileAttributeType) == .typeSymbolicLink {
            throw CocoaError(.fileReadCorruptFile)
        }
        guard fm.fileExists(atPath: source.path) else { return nil }
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= maximumBytes else { throw CocoaError(.fileReadTooLarge) }
        let data = try Data(contentsOf: source)
        guard data.count <= maximumBytes else { throw CocoaError(.fileReadTooLarge) }
        return data
    }

    private func commit(_ archive: ConversationArchive<Message>) throws {
        guard isReady else { throw CocoaError(.fileReadCorruptFile) }
        guard mutationAllowed() else {
            throw NSError(domain: "NOMAD.Conversations", code: 1, userInfo: [NSLocalizedDescriptionKey: "Stop the current operation before changing saved conversations."])
        }
        try validate(archive)
        guard try read(url) == snapshot else {
            isReady = false
            error = "Saved conversations changed outside this screen. Reload before editing; neither copy was overwritten."
            throw CocoaError(.fileWriteFileExists)
        }
        let data = try JSONEncoder().encode(archive)
        guard data.count <= maximumBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        snapshot = data; conversations = archive.conversations; selectedID = archive.selectedID; error = nil
    }
}
