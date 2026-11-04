import SwiftUI
import UniformTypeIdentifiers

struct ConversationsView<Message: Codable>: View {
    @Bindable var store: ConversationStore<Message>
    var canEdit = true
    @Environment(\.dismiss) private var dismiss
    @State private var pendingDelete: UUID?
    @State private var renaming: UUID?
    @State private var title = ""
    @State private var error: String?
    @State private var exported: URL?
    @State private var importing = false

    var body: some View {
        NavigationStack {
            List {
                if let error = error ?? store.error { Text(error).foregroundStyle(.orange) }
                if !store.isReady { Button("Reload conversations") { if canEdit { store.reload() } }.disabled(!canEdit) }
                ForEach(store.conversations.sorted { $0.updatedAt > $1.updatedAt }) { conversation in
                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            perform { try store.select(conversation.id); dismiss() }
                        } label: {
                            HStack {
                                Image(systemName: store.selectedID == conversation.id ? "checkmark.bubble.fill" : "bubble.left.and.bubble.right")
                                VStack(alignment: .leading) {
                                    Text(conversation.title).font(.headline)
                                    Text("\(conversation.messages.count) messages · \(conversation.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }.buttonStyle(.plain)
                        HStack {
                            Button("Rename") { title = conversation.title; renaming = conversation.id }
                            Button("Export JSON") { perform { exported = try store.export(conversation.id) } }
                            Spacer()
                            Button("Delete", role: .destructive) { pendingDelete = conversation.id }
                        }.font(.caption).buttonStyle(.borderless)
                    }.disabled(!store.isReady || !canEdit)
                }
                if let exported { ShareLink("Share exported conversation", item: exported) }
                Text("Conversations and source excerpts stay on this device. Exported JSON includes that text. Import adds new conversations without replacing existing ones. Up to 500 conversations fit in the 32 MB history archive.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .navigationTitle("Conversations")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("New conversation", systemImage: "plus.bubble") { perform { try store.create(); dismiss() } }
                        Button("Import conversation JSON", systemImage: "square.and.arrow.down") { importing = true }
                    } label: { Image(systemName: "plus") }.disabled(!store.isReady || !canEdit)
                }
            }
            .alert("Rename conversation", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Title", text: $title)
                Button("Cancel", role: .cancel) { renaming = nil }
                Button("Save") { if let id = renaming { perform { try store.rename(id, to: title) } }; renaming = nil }
            }
            .confirmationDialog("Delete this saved conversation?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
                Button("Delete conversation", role: .destructive) { if let id = pendingDelete { perform { try store.delete(id) } }; pendingDelete = nil }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                perform {
                    let url = try result.get()
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    try store.importConversation(url)
                }
            }
        }
    }
    private func perform(_ operation: () throws -> Void) {
        guard canEdit else { error = "Stop the current operation before changing conversations."; return }
        do { try operation(); error = nil } catch { self.error = error.localizedDescription }
    }
}

struct ConversationSettingsView: View {
    let initial: ConversationSettings
    let save: (ConversationSettings) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ConversationSettings()
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("Sources") {
                    Toggle("Use my library", isOn: $draft.useLibrary)
                    Toggle("Semantic + keyword retrieval", isOn: $draft.semantic).disabled(!draft.useLibrary)
                }
                Section("General chat") {
                    Stepper("Previous messages: \(draft.historyMessages)", value: $draft.historyMessages, in: 0...12)
                    TextEditor(text: $draft.instructions).frame(minHeight: 120)
                    Text("Custom instructions: \(draft.instructions.count) / 1,000 characters. Previous messages and custom instructions apply to general chat. Library answers use only the current question and selected passages.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Generation") {
                    Stepper("Response limit: \(draft.responseTokens) tokens", value: $draft.responseTokens, in: 32...512, step: 32)
                    Slider(value: $draft.temperature, in: 0...1, step: 0.1) { Text("Temperature") }
                    LabeledContent("Temperature", value: String(format: "%.1f", draft.temperature))
                    Text("Higher temperature produces more varied answers. Library answers use 0.2. A model's working context can require shorter prompts or responses.").font(.caption)
                }
                if let error { Text(error).foregroundStyle(.orange) }
            }
            .navigationTitle("Conversation settings")
            .onAppear { draft = initial }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { do { try draft.validate(); try save(draft); dismiss() } catch { self.error = error.localizedDescription } }
                        .disabled(draft.instructions.count > 1_000)
                }
            }
            .interactiveDismissDisabled(draft != initial)
        }
    }
}
