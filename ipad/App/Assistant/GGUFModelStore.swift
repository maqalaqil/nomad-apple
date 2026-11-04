import Foundation
import Observation

struct GGUFModelFile: Identifiable, Equatable, Sendable {
    let filename: String
    let title: String
    let byteCount: Int64
    let importedAt: Date
    var id: String { filename }
}

struct GGUFBenchmark: Codable, Identifiable {
    var id = UUID()
    let date: Date
    let model: String
    let backend: String
    let metrics: GGUFMetrics
}

@MainActor
@Observable
final class GGUFModelStore {
    static let shared = GGUFModelStore()
    private(set) var models: [GGUFModelFile] = []
    private(set) var messages: [GGUFChatMessage] = []
    private(set) var benchmarks: [GGUFBenchmark] = []
    private(set) var loadedID: String?
    private(set) var loadInfo: GGUFLoadInfo?
    private(set) var lastMetrics: GGUFMetrics?
    private(set) var busyText: String?
    private(set) var importing = false
    var error: String?
    var selectedID: String {
        didSet { UserDefaults.standard.set(selectedID, forKey: "NomadGGUFSelectedModel") }
    }
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var messagesConversationID: UUID?
    @ObservationIgnored private let engine = GGUFEngine.shared
    let conversations: ConversationStore<GGUFChatMessage>
    var settings: ConversationSettings { conversations.selected?.settings ?? .init(useLibrary: false) }
    @ObservationIgnored private var benchmarksUnreadable = false
    @ObservationIgnored private let root: URL
    private var modelsRoot: URL { root.appendingPathComponent("Models", isDirectory: true) }
    var isBusy: Bool { busyText != nil }

    init(root: URL? = nil) {
        self.root = root ?? URL.applicationSupportDirectory.appendingPathComponent("NomadPad/GGUF", isDirectory: true)
        conversations = ConversationStore(url: self.root.appendingPathComponent("conversations.json"),
            legacyURL: self.root.appendingPathComponent("chat.json"),
            defaults: ConversationSettings(useLibrary: UserDefaults.standard.bool(forKey: "NomadGGUFUseLibrary"),
                semantic: UserDefaults.standard.bool(forKey: "NomadGGUFSemanticRetrieval"))) { saved in
                guard Set(saved.map(\.id)).count == saved.count, saved.allSatisfy({ message in
                    ["user", "assistant"].contains(message.role) && message.text.count <= 1_000_000 &&
                    message.sources.count <= GGUFGrounding.maximumSources &&
                    Set(message.sources.map(\.id)).count == message.sources.count &&
                    message.sources.allSatisfy { !$0.id.isEmpty && $0.id.count <= 512 && $0.title.count <= 120 && $0.excerpt.count <= GGUFGrounding.maximumExcerptCharacters }
                }) else { throw CocoaError(.fileReadCorruptFile) }
            }
        selectedID = UserDefaults.standard.string(forKey: "NomadGGUFSelectedModel") ?? ""
        messages = conversations.selected?.messages ?? []
        messagesConversationID = conversations.selectedID
        do {
            try FileManager.default.createDirectory(at: modelsRoot, withIntermediateDirectories: true)
            try refresh()
        } catch { self.error = error.localizedDescription }
        if !conversations.isReady { error = conversations.error }
        let benchmarksURL = self.root.appendingPathComponent("benchmarks.json")
        if FileManager.default.fileExists(atPath: benchmarksURL.path) {
            do { benchmarks = try JSONDecoder().decode([GGUFBenchmark].self, from: Data(contentsOf: benchmarksURL)) }
            catch { benchmarksUnreadable = true; self.error = "Saved benchmark results could not be read; their file has been preserved." }
        }
        conversations.mutationAllowed = { [weak self] in self?.isBusy == false }
    }

    func fileURL(for file: GGUFModelFile) -> URL {
        guard file.filename == (file.filename as NSString).lastPathComponent,
              !file.filename.contains("\\"), models.contains(where: { $0.filename == file.filename }) else {
            return modelsRoot.appendingPathComponent("invalid-model")
        }
        return modelsRoot.appendingPathComponent(file.filename)
    }

    func importModel(_ source: URL, name: String? = nil) async {
        guard !isBusy else { return }
        busyText = "Copying model to this iPad…"
        importing = true
        error = nil
        defer { busyText = nil; importing = false }
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        let destinationRoot = modelsRoot
        do {
            let filename = try await Task.detached(priority: .userInitiated) {
                let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                      source.pathExtension.lowercased() == "gguf" else { throw GGUFError.invalidModel }
                let reader = try FileHandle(forReadingFrom: source)
                let magic = try reader.read(upToCount: 4)
                try reader.close()
                guard magic == Data([0x47, 0x47, 0x55, 0x46]) else { throw GGUFError.invalidModel }
                let suppliedName = ((name ?? source.lastPathComponent) as NSString).lastPathComponent
                var original = (suppliedName as NSString).deletingPathExtension
                    .replacingOccurrences(of: "\\", with: "_")
                    .components(separatedBy: .controlCharacters).joined()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if original.isEmpty { original = "model" }
                while original.utf8.count > 160 { original.removeLast() }
                let id = UUID().uuidString
                let filename = "\(id)--\(original).gguf"
                let staging = destinationRoot.appendingPathComponent(".import-\(id)")
                let destination = destinationRoot.appendingPathComponent(filename)
                do {
                    try FileManager.default.copyItem(at: source, to: staging)
                    try FileManager.default.moveItem(at: staging, to: destination)
                } catch { try? FileManager.default.removeItem(at: staging); throw error }
                return filename
            }.value
            try refresh()
            selectedID = filename
        } catch { self.error = "Model import failed: \(error.localizedDescription)" }
    }

    func load(_ file: GGUFModelFile, useGPU: Bool) {
        guard !isBusy else { return }
        error = nil
        busyText = "Loading \(file.title)…"
        let url = fileURL(for: file)
        selectedID = file.id
        task = Task {
            defer { busyText = nil; task = nil }
            loadedID = nil
            loadInfo = nil
            do {
                loadInfo = try await engine.load(url: url, useGPU: useGPU)
                loadedID = file.id
            } catch {
                self.error = Task.isCancelled || error is CancellationError ? "Model loading stopped." : error.localizedDescription
            }
        }
    }

    func unload() {
        guard !isBusy else { return }
        busyText = "Releasing model memory…"
        task = Task {
            defer { busyText = nil; task = nil }
            do { try await engine.unload(); loadedID = nil; loadInfo = nil }
            catch { self.error = error.localizedDescription }
        }
    }

    func delete(_ file: GGUFModelFile) {
        guard !isBusy else { return }
        busyText = "Removing model…"
        task = Task {
            defer { busyText = nil; task = nil }
            do {
                if loadedID == file.id { try await engine.unload(); loadedID = nil; loadInfo = nil }
                try FileManager.default.removeItem(at: fileURL(for: file))
                try refresh()
                if selectedID == file.id { selectedID = models.first?.id ?? "" }
            } catch { self.error = error.localizedDescription }
        }
    }

    @discardableResult
    func send(_ text: String, library: LibraryStore? = nil, useLibrary: Bool = false, semantic: Bool = false) -> Bool {
        guard !isBusy else { return false }
        // Selection can change from another window before SwiftUI delivers onChange.
        if messagesConversationID != conversations.selectedID { restoreConversation() }
        if useLibrary { return sendGrounded(text, library: library, semantic: semantic) }
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isBusy, loadedID != nil, !question.isEmpty, let conversationID = conversations.selectedID else { return false }
        guard conversations.isReady else { error = conversations.error ?? "Reload saved conversations before continuing."; return false }
        error = nil
        lastMetrics = nil
        guard question.count <= 6_000 else { error = "Keep the message under 6,000 characters. Your text has not been changed."; return false }
        var conversation = Array(messages.suffix(settings.historyMessages))
        if !settings.instructions.isEmpty { conversation.insert(GGUFChatMessage(role: "system", text: settings.instructions), at: 0) }
        let questionMessage = GGUFChatMessage(role: "user", text: question)
        messages.append(questionMessage)
        conversation.append(questionMessage)
        let answer = GGUFChatMessage(role: "assistant", text: "")
        messages.append(answer)
        busyText = "Generating locally…"
        let maximum = min(settings.responseTokens, max(16, (loadInfo?.contextTokens ?? 2048) / 2))
        task = Task {
            defer { busyText = nil; task = nil; persistHistory(conversationID: conversationID) }
            do {
                lastMetrics = try await engine.generate(messages: conversation, maximumTokens: maximum, temperature: Float(settings.temperature)) { [weak self] chunk in
                    await self?.append(chunk, to: answer.id)
                }
                if let index = messages.firstIndex(where: { $0.id == answer.id }), messages[index].text.isEmpty {
                    messages[index].text = "The model finished without producing text. Try a different prompt or model."
                }
            } catch {
                let stopped = Task.isCancelled || error is CancellationError
                if let index = messages.firstIndex(where: { $0.id == answer.id }), messages[index].text.isEmpty {
                    messages[index].text = stopped ? "Response stopped." : "The model could not complete this response."
                }
                self.error = stopped ? "Generation stopped." : error.localizedDescription
            }
        }
        return true
    }

    private func sendGrounded(_ text: String, library: LibraryStore?, semantic: Bool) -> Bool {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isBusy, loadedID != nil, !question.isEmpty, let conversationID = conversations.selectedID else { return false }
        guard conversations.isReady else { error = conversations.error ?? "Reload saved conversations before continuing."; return false }
        guard let library else { error = "Open Local AI Models from the workspace to use its Knowledge Library."; return false }
        guard question.count <= GGUFGrounding.maximumQuestionCharacters else { error = GGUFGroundingError.questionTooLong.localizedDescription; return false }
        error = nil
        lastMetrics = nil
        messages.append(GGUFChatMessage(role: "user", text: question, usedLibrary: true))
        let answer = GGUFChatMessage(role: "assistant", text: "", usedLibrary: true)
        messages.append(answer)
        busyText = "Searching selected documents locally…"
        let maximum = min(settings.responseTokens, max(16, (loadInfo?.contextTokens ?? 2048) / 2))
        task = Task {
            defer { busyText = nil; task = nil; persistHistory(conversationID: conversationID) }
            do {
                let knowledge = SemanticIndexStore.shared
                let hits = try await knowledge.search(question, library: library, semantic: semantic)
                try Task.checkCancellation()
                let sources = GGUFGrounding.sources(from: hits, allowedDocuments: knowledge.allowedDocuments(in: library))
                guard !sources.isEmpty else {
                    if let index = messages.firstIndex(where: { $0.id == answer.id }) {
                        messages[index].text = GGUFGroundingError.noSources.localizedDescription
                        messages[index].notice = "Library retrieval was enabled. No model answer was generated."
                    }
                    return
                }
                let prepared = try await engine.prepareGrounded(question: question, sources: sources, maximumTokens: maximum)
                try Task.checkCancellation()
                let currentSelection = knowledge.allowedDocuments(in: library)
                guard prepared.sources.allSatisfy({ currentSelection.contains($0.documentID) }) else { throw GGUFGroundingError.selectionChanged }
                if let index = messages.firstIndex(where: { $0.id == answer.id }) {
                    messages[index].sources = prepared.sources
                    messages[index].notice = prepared.shortened ? "Source passages were shortened or omitted to fit this model's context. Only the passages shown below were supplied." : nil
                }
                busyText = "Generating from local passages…"
                lastMetrics = try await engine.generate(messages: prepared.messages, maximumTokens: prepared.maximumResponseTokens, temperature: 0.2) { [weak self] chunk in
                    await self?.append(chunk, to: answer.id)
                }
                if let index = messages.firstIndex(where: { $0.id == answer.id }) {
                    if messages[index].text.isEmpty { messages[index].text = "The model finished without producing text. Try a different prompt or model." }
                    if let warning = GGUFGrounding.citationWarning(answer: messages[index].text, sources: prepared.sources) {
                        messages[index].notice = [messages[index].notice, warning].compactMap { $0 }.joined(separator: " ")
                    }
                }
            } catch {
                let stopped = Task.isCancelled || error is CancellationError
                if let index = messages.firstIndex(where: { $0.id == answer.id }) {
                    if messages[index].text.isEmpty { messages[index].text = stopped ? "Response stopped." : "The model could not complete this library answer." }
                    messages[index].notice = stopped ? "This response was interrupted." : error.localizedDescription
                }
                self.error = stopped ? "Generation stopped." : error.localizedDescription
            }
        }
        return true
    }

    func benchmark() {
        guard !isBusy, let loadInfo, let loadedID else { return }
        busyText = "Measuring local generation…"
        error = nil
        let name = models.first(where: { $0.id == loadedID })?.title ?? loadedID
        task = Task {
            defer { busyText = nil; task = nil }
            do {
                let metrics = try await engine.generate(messages: [GGUFChatMessage(role: "user", text: "Write a short story about a traveler who carries an offline library.")],
                    maximumTokens: min(64, max(16, loadInfo.contextTokens / 4)), temperature: 0) { _ in }
                let result = GGUFBenchmark(date: Date(), model: name, backend: loadInfo.backend, metrics: metrics)
                guard !benchmarksUnreadable else { error = "Benchmark completed, but the existing results file is unreadable and has been preserved."; return }
                var updated = benchmarks
                updated.insert(result, at: 0)
                updated = Array(updated.prefix(100))
                try JSONEncoder().encode(updated).write(to: root.appendingPathComponent("benchmarks.json"), options: .atomic)
                benchmarks = updated
            } catch { self.error = Task.isCancelled || error is CancellationError ? "Benchmark stopped." : error.localizedDescription }
        }
    }

    func stop() { engine.cancel(); task?.cancel() }

    func newChat() {
        guard !isBusy else { return }
        do { try conversations.create(); restoreConversation() }
        catch { self.error = error.localizedDescription }
    }

    func restoreConversation() {
        guard !isBusy else { return }
        messages = conversations.selected?.messages ?? []
        messagesConversationID = conversations.selectedID
        lastMetrics = nil
        error = conversations.error
    }

    func updateSettings(_ next: ConversationSettings) {
        do { try conversations.update(settings: next) }
        catch { self.error = error.localizedDescription }
    }

    private func append(_ chunk: String, to id: UUID) {
        if let index = messages.firstIndex(where: { $0.id == id }) { messages[index].text += chunk }
    }

    private func persistHistory(conversationID: UUID) {
        do {
            try conversations.update(id: conversationID, messages: messages, titleSuggestion: messages.first(where: { $0.role == "user" })?.text)
            if conversations.selectedID != conversationID { restoreConversation() }
        }
        catch { self.error = "Chat could not be saved: \(error.localizedDescription)" }
    }

    private func refresh() throws {
        let urls = try FileManager.default.contentsOfDirectory(at: modelsRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .creationDateKey], options: .skipsHiddenFiles)
        models = try urls.filter { $0.pathExtension.lowercased() == "gguf" }.compactMap { url in
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .creationDateKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
            let name = url.lastPathComponent
            let display = name.count > 38 && UUID(uuidString: String(name.prefix(36))) != nil ? String(name.dropFirst(38)) : name
            return GGUFModelFile(filename: name, title: display, byteCount: Int64(values.fileSize ?? 0), importedAt: values.creationDate ?? .distantPast)
        }.sorted { $0.importedAt > $1.importedAt }
    }
}
