import Foundation

private struct Message: Codable, Equatable { var id = UUID(); var role: String; var text: String }

@main struct ConversationRegression {
    @MainActor static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NomadConversationTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var checks = 0
        func check(_ success: Bool) { precondition(success); checks += 1 }
        func rejects(_ operation: () throws -> Void) { do { try operation(); fatalError("Expected rejection") } catch { checks += 1 } }
        func make(_ name: String = "archive", legacy: String = "legacy") -> ConversationStore<Message> {
            ConversationStore(url: root.appendingPathComponent(name), legacyURL: root.appendingPathComponent(legacy)) { messages in
                guard Set(messages.map(\.id)).count == messages.count, messages.allSatisfy({ ["user", "assistant"].contains($0.role) })
                else { throw CocoaError(.fileReadCorruptFile) }
            }
        }
        let legacy = [Message(role: "user", text: "Preserve this question"), Message(role: "assistant", text: "Preserve this answer")]
        let original = try JSONEncoder().encode(legacy)
        try original.write(to: root.appendingPathComponent("legacy"))
        let store = make()
        check(store.isReady && store.conversations.count == 1 && store.selected?.messages == legacy)
        let firstID = store.selectedID!
        try store.rename(firstID, to: "Original")
        check(try Data(contentsOf: root.appendingPathComponent("legacy")) == original)
        check(make().selected?.title == "Original")
        try store.create()
        check(store.conversations.count == 2 && store.selected?.messages.isEmpty == true)
        let secondID = store.selectedID!
        var settings = ConversationSettings(); settings.historyMessages = 0; settings.responseTokens = 128; settings.useLibrary = false
        try store.update(settings: settings)
        let next = [Message(role: "user", text: "Independent chat")]
        try store.update(messages: next, titleSuggestion: next[0].text)
        check(store.selected?.title == "Independent chat" && store.selected?.settings == settings)
        try store.select(firstID)
        check(store.selected?.messages == legacy && store.selected?.settings != settings)
        let reopened = make()
        check(reopened.selectedID == firstID && reopened.conversations.count == 2)
        let exported = try store.export(secondID)
        defer { try? FileManager.default.removeItem(at: exported) }
        try store.importConversation(exported)
        check(store.conversations.count == 3 && store.selectedID != secondID && store.selected?.messages == next)
        check(store.selected?.settings == settings)
        try store.delete(store.selectedID!)
        check(store.conversations.count == 2)
        rejects { try store.rename(firstID, to: "   ") }
        rejects { try store.rename(firstID, to: String(repeating: "x", count: 121)) }
        rejects { try store.select(UUID()) }
        var invalid = settings; invalid.responseTokens = Int.max
        rejects { try store.update(settings: invalid) }
        rejects { try store.update(messages: [Message(role: "system", text: "invalid saved role")]) }
        check(store.isReady && store.conversations.count == 2)
        // A concurrent writer fails closed without overwriting either durable history.
        let before = try Data(contentsOf: root.appendingPathComponent("archive"))
        rejects { try reopened.rename(firstID, to: "Stale replacement") }
        let afterConflict = try Data(contentsOf: root.appendingPathComponent("archive"))
        check(!reopened.isReady && afterConflict == before)
        reopened.reload()
        check(reopened.isReady && reopened.conversations.count == 2)
        try store.delete(secondID); try store.delete(firstID)
        check(store.conversations.count == 1 && store.selected?.messages.isEmpty == true)
        // Corrupt migration input never creates a replacement archive.
        try Data("bad".utf8).write(to: root.appendingPathComponent("bad-legacy"))
        let corrupt = make("bad-archive", legacy: "bad-legacy")
        check(!corrupt.isReady)
        rejects { try corrupt.create() }
        check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("bad-archive").path))
        try Data("bad".utf8).write(to: root.appendingPathComponent("bad-existing"))
        let badExisting = make("bad-existing")
        check(!badExisting.isReady)
        rejects { try badExisting.create() }
        check(try Data(contentsOf: root.appendingPathComponent("bad-existing")) == Data("bad".utf8))
        // A symlink cannot redirect imports or archive writes to an unrelated file.
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: root.appendingPathComponent("legacy"))
        check(!make("link").isReady)
        rejects { try store.importConversation(root.appendingPathComponent("link")) }
        var malformed = try JSONSerialization.jsonObject(with: Data(contentsOf: exported)) as! [String: Any]
        malformed["version"] = 999
        try JSONSerialization.data(withJSONObject: malformed).write(to: root.appendingPathComponent("unknown-version"))
        rejects { try store.importConversation(root.appendingPathComponent("unknown-version")) }
        check(store.isReady && store.conversations.count == 1)
        // A generator persists to its origin even if selection changes before completion.
        let origin = store.selectedID!
        try store.create()
        let other = store.selectedID!
        try store.update(id: origin, messages: legacy)
        check(store.selectedID == other && store.selected?.messages.isEmpty == true)
        check(store.conversations.first(where: { $0.id == origin })?.messages == legacy)
        store.mutationAllowed = { false }
        rejects { try store.select(origin) }
        rejects { try store.delete(origin) }
        rejects { try store.create() }
        rejects { try store.update(settings: settings) }
        store.reload()
        check(store.selectedID == other && store.isReady)
        store.mutationAllowed = { true }
        try store.select(origin)
        check(store.selected?.messages == legacy)
        print("PASS: \(checks) conversation migration, persistence, isolation, import/export, corruption and conflict checks")
    }
}
