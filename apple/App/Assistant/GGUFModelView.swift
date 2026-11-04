import SwiftUI
import UniformTypeIdentifiers
import QuickLook

@MainActor
struct GGUFModelView: View {
    var library: LibraryStore? = nil
    @State private var store = GGUFModelStore.shared
    @State private var showingImporter = false
    @State private var pendingDelete: GGUFModelFile?
    @State private var pendingLargeLoad: GGUFModelFile?
    @State private var confirmDelete = false
    @State private var confirmLargeLoad = false
    @State private var showingConversations = false
    @State private var editingSettings = false
    @State private var question = ""
    @AppStorage("NomadGGUFUseGPU") private var useGPU = true
    private var useLibrary: Bool { store.settings.useLibrary }
    private var useSemantic: Bool { store.settings.semantic }
    @State private var preview: URL?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollViewReader { proxy in
            List {
                Section {
                    Text("Import a complete, single-file GGUF text model from Files. Models and chats remain on this device; no model is downloaded automatically.")
                    NavigationLink { CatalogDownloadsView() } label: { Label("Browse downloadable models and content", systemImage: "arrow.down.circle") }
                    if !GGUFEngine.isAvailable {
                        Label("Model import is available here. Inference runs on a physical iPhone, iPad, or Mac; the pinned framework has no iOS simulator build.", systemImage: "ipad")
                            .foregroundStyle(.orange)
                    }
                    Text("Storage is not working memory. Runtime memory includes weights, context, and temporary buffers. Start with a small quantized model; a model that exceeds available memory can cause the operating system to stop the app.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Models on this device") {
                    if store.models.isEmpty {
                        ContentUnavailableView("Import your first model", systemImage: "cpu", description: Text("Choose a .gguf file you have already downloaded. No cloud inference is used."))
                    }
                    ForEach(store.models) { file in
                        VStack(alignment: .leading, spacing: 9) {
                            HStack {
                                Image(systemName: store.loadedID == file.id ? "checkmark.circle.fill" : "cpu")
                                    .foregroundStyle(store.loadedID == file.id ? .green : .secondary)
                                Text(file.title).font(.headline).lineLimit(2)
                                Spacer()
                                Text(ByteCountFormatter.string(fromByteCount: file.byteCount, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                            }
                            HStack {
                                if store.loadedID == file.id {
                                    Button("Unload") { store.unload() }
                                    Text("Loaded").font(.caption).foregroundStyle(.green)
                                } else {
                                    Button("Load model") { requestLoad(file) }.disabled(!GGUFEngine.isAvailable)
                                }
                                Spacer()
                                ShareLink(item: store.fileURL(for: file)) { Image(systemName: "square.and.arrow.up") }
                                Button(role: .destructive) { pendingDelete = file; confirmDelete = true } label: { Image(systemName: "trash") }
                            }.disabled(store.isBusy)
                        }.padding(.vertical, 4)
                    }
                    Toggle("Use Metal GPU, with CPU fallback", isOn: $useGPU).disabled(store.isBusy)
                    Text("The setting applies when loading a model. Context is capped at 2,048 tokens, and at the model's own limit when smaller.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button { showingImporter = true } label: { Label("Import GGUF model", systemImage: "square.and.arrow.down") }.disabled(store.isBusy)
                }
                if let loadInfo = store.loadInfo {
                    Section("Loaded model") {
                        Text(loadInfo.description).font(.headline)
                        LabeledContent("Backend", value: loadInfo.backend)
                        LabeledContent("Context", value: "\(loadInfo.contextTokens) tokens")
                        LabeledContent("Load time", value: String(format: "%.1f seconds", loadInfo.loadSeconds))
                        if loadInfo.usedCPUFallback { Text("Metal loading failed; this model is running on the CPU.").foregroundStyle(.orange) }
                        Text("The model's embedded chat template is used when supported; otherwise a plain role prompt is used. Enable library retrieval below to supply selected local document passages.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("Run generation benchmark", systemImage: "speedometer") { store.benchmark() }.disabled(store.isBusy)
                    }
                }
                if let status = store.busyText {
                    Section {
                        HStack {
                            ProgressView()
                            Text(status)
                            Spacer()
                            if !store.importing { Button("Stop", role: .destructive) { store.stop() } }
                        }
                    }
                }
                if let error = store.error { Section { Text(error).foregroundStyle(.orange).textSelection(.enabled) } }
                Section("Local chat") {
                    Toggle("Use selected Knowledge Collections", isOn: Binding(get: { useLibrary && library != nil }, set: { value in var next = store.settings; next.useLibrary = value; store.updateSettings(next) }))
                        .disabled(store.isBusy || library == nil)
                    if useLibrary, let library {
                        Toggle("Semantic + keyword retrieval", isOn: Binding(get: { useSemantic }, set: { value in var next = store.settings; next.semantic = value; store.updateSettings(next) })).disabled(store.isBusy)
                        NavigationLink { SemanticCollectionsView(library: library) } label: { Label("Choose sources and manage the index", systemImage: "books.vertical") }
                            .disabled(store.isBusy)
                        Text("Uses extracted PDF/text passages from enabled collections. With no collections, all imported documents are active. ZIM and EPUB contents are not included in this retrieval index. Semantic retrieval requires an index built in Knowledge Collections; keyword retrieval needs no embedding model.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Text("Each library answer uses this question and up to three retrieved passages. Previous chat is not supplied as evidence. The model may still make mistakes; check its citations and source text.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(store.messages) { message in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(message.role == "user" ? "You" : "Model").font(.caption.bold()).foregroundStyle(.secondary)
                            Text(message.text.isEmpty ? "Generating…" : message.text).textSelection(.enabled)
                            if message.usedLibrary && message.role == "assistant" {
                                Text("Library retrieval enabled").font(.caption).foregroundStyle(.secondary)
                            }
                            if let notice = message.notice { Text(notice).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                            if !message.sources.isEmpty {
                                Text("Supplied source passages · verify the answer against these excerpts")
                                    .font(.caption).foregroundStyle(.secondary)
                                ForEach(Array(message.sources.enumerated()), id: \.element.id) { index, source in
                                    DisclosureGroup("[\(index + 1)] \(source.title)") {
                                        VStack(alignment: .leading, spacing: 9) {
                                            Text(source.excerpt).font(.subheadline).textSelection(.enabled)
                                            Button("Open original", systemImage: "doc.text") {
                                                if let library, let document = library.documents.first(where: { $0.id == source.documentID }) {
                                                    preview = library.fileURL(for: document)
                                                } else { store.error = "The source document has been removed or its library is unavailable." }
                                            }
                                        }.padding(.top, 6)
                                    }.font(.subheadline)
                                }
                            }
                        }.padding(.vertical, 6)
                    }
                    if let metrics = store.lastMetrics {
                        Text("\(metrics.generatedTokens) tokens · \(String(format: "%.1f", metrics.tokensPerSecond)) tokens/s\(metrics.reachedTokenLimit ? " · response limit reached" : "")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(alignment: .bottom) {
                        TextField("Message your local model", text: $question, axis: .vertical).lineLimit(1...6)
                            .textFieldStyle(.roundedBorder).disabled(store.isBusy)
                        Button("Send", systemImage: "arrow.up") {
                            if store.send(question, library: library, useLibrary: useLibrary && library != nil, semantic: useSemantic) { question = "" }
                        }.disabled(store.isBusy || store.loadedID == nil || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }.id("composer")
                    Button("New conversation", systemImage: "plus.bubble") { store.newChat() }.disabled(store.isBusy || !store.conversations.isReady)
                    Button("Saved conversations", systemImage: "bubble.left.and.bubble.right") { showingConversations = true }.disabled(store.isBusy)
                    Button("Conversation settings", systemImage: "slider.horizontal.3") { editingSettings = true }.disabled(store.isBusy || !store.conversations.isReady)
                }
                if !store.benchmarks.isEmpty {
                    Section("Measured performance") {
                        Text("Local generation measurements include this model and device only. They are not NOMAD leaderboard scores.")
                            .font(.footnote).foregroundStyle(.secondary)
                        ForEach(store.benchmarks.prefix(10)) { result in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(result.model).font(.headline)
                                Text("\(result.backend) · \(result.metrics.generatedTokens) generated tokens · \(String(format: "%.1f", result.metrics.tokensPerSecond)) tokens/s")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(result.date, style: .date).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .onChange(of: store.messages.last?.text) { _, _ in proxy.scrollTo("composer", anchor: .bottom) }
        }
        .navigationTitle("GGUF Models")
        .quickLookPreview($preview)
        .onChange(of: scenePhase) { _, phase in if phase == .background { store.stop() } }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [UTType(filenameExtension: "gguf") ?? .data]) { result in
            switch result {
            case .success(let url): Task { await store.importModel(url) }
            case .failure(let error): store.error = error.localizedDescription
            }
        }
        .confirmationDialog("Delete this model from the device?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete local model", role: .destructive) { if let pendingDelete { store.delete(pendingDelete) } }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { Text("This removes the imported local copy. The original file and saved chat remain.") }
        .confirmationDialog("Load this large model?", isPresented: $confirmLargeLoad, titleVisibility: .visible) {
            Button("Load model") { if let pendingLargeLoad { store.load(pendingLargeLoad, useGPU: useGPU) } }
            Button("Cancel", role: .cancel) { pendingLargeLoad = nil }
        } message: { Text("This model is over 2 GB. Its total working memory will be larger than its file size, and it may not fit within the device's available app memory.") }
        .sheet(isPresented: $showingConversations, onDismiss: { store.restoreConversation() }) { ConversationsView(store: store.conversations, canEdit: !store.isBusy) }
        .sheet(isPresented: $editingSettings) { ConversationSettingsView(initial: store.settings) { try store.conversations.update(settings: $0) } }
        .onChange(of: store.conversations.selectedID) { _, _ in store.restoreConversation() }
    }

    private func requestLoad(_ file: GGUFModelFile) {
        if file.byteCount > 2 * 1_024 * 1_024 * 1_024 { pendingLargeLoad = file; confirmLargeLoad = true }
        else { store.load(file, useGPU: useGPU) }
    }
}
