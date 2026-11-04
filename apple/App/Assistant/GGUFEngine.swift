import Foundation
#if canImport(llama) && !targetEnvironment(simulator)
import llama
#endif

struct GGUFChatMessage: Codable, Identifiable, Sendable {
    var id = UUID()
    var role: String
    var text: String
    var sources: [GGUFSource] = []
    var usedLibrary = false
    var notice: String?

    init(id: UUID = UUID(), role: String, text: String, sources: [GGUFSource] = [], usedLibrary: Bool = false, notice: String? = nil) {
        self.id = id; self.role = role; self.text = text; self.sources = sources; self.usedLibrary = usedLibrary; self.notice = notice
    }
    private enum CodingKeys: String, CodingKey { case id, role, text, sources, usedLibrary, notice }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        role = try values.decode(String.self, forKey: .role)
        text = try values.decode(String.self, forKey: .text)
        sources = try values.decodeIfPresent([GGUFSource].self, forKey: .sources) ?? []
        usedLibrary = try values.decodeIfPresent(Bool.self, forKey: .usedLibrary) ?? false
        notice = try values.decodeIfPresent(String.self, forKey: .notice)
    }
}

struct GGUFLoadInfo: Sendable {
    let description: String
    let backend: String
    let contextTokens: Int
    let loadSeconds: Double
    let usedCPUFallback: Bool
}

struct GGUFMetrics: Codable, Sendable {
    let promptTokens: Int
    let generatedTokens: Int
    let promptSeconds: Double
    let generationSeconds: Double
    let reachedTokenLimit: Bool
    var tokensPerSecond: Double { generationSeconds > 0 ? Double(generatedTokens) / generationSeconds : 0 }
}

enum GGUFError: LocalizedError {
    case unavailable, busy, notLoaded, loadFailed, contextFailed, promptTooLong(Int), decodeFailed(Int32), invalidModel, tokenizer, notTextModel
    var errorDescription: String? {
        switch self {
        case .unavailable: "The GGUF engine requires a physical iPhone, iPad, or Mac. The pinned Apple inference framework does not include a simulator build."
        case .busy: "The model is busy. Stop the current operation before switching or unloading it."
        case .notLoaded: "Load a GGUF model before generating an answer."
        case .loadFailed: "The model could not be loaded on this device. It may be incomplete, unsupported, or too large for available memory."
        case .contextFailed: "The model loaded, but its working context could not be allocated. Try a smaller model."
        case .promptTooLong(let limit): "This conversation exceeds the model's \(limit)-token working context. Start a new chat or shorten your message."
        case .decodeFailed(let code): "Local inference stopped with error \(code). Try a shorter prompt, CPU mode, or a smaller model."
        case .invalidModel: "Choose a complete GGUF model file. This file does not have a valid GGUF header."
        case .tokenizer: "The model's tokenizer could not process this prompt."
        case .notTextModel: "This engine requires a decoder-only text-generation model. Embedding and encoder-decoder GGUF models are not supported in this chat interface."
        }
    }
}

private final class GGUFStopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    func reset() { lock.lock(); stopped = false; lock.unlock() }
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
    var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
}

/// Owns all llama state. Calls serialize on the actor; cancellation remains callable during C inference.
actor GGUFEngine {
    static let shared = GGUFEngine()
    nonisolated static var isAvailable: Bool {
        #if canImport(llama) && !targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }
    nonisolated private let stopFlag = GGUFStopFlag()
    nonisolated func cancel() { stopFlag.cancel() }
    private var busy = false
    private var info: GGUFLoadInfo?

    #if canImport(llama) && !targetEnvironment(simulator)
    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private static let initializeBackend: Void = {
        llama_log_set({ level, message, _ in
            if let message, level == GGML_LOG_LEVEL_ERROR || level == GGML_LOG_LEVEL_WARN { fputs(message, stderr) }
        }, nil)
        llama_backend_init()
    }()

    isolated deinit {
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
    }
    #endif

    func load(url: URL, useGPU: Bool = true) async throws -> GGUFLoadInfo {
        guard !busy else { throw GGUFError.busy }
        try Task.checkCancellation()
        #if canImport(llama) && !targetEnvironment(simulator)
        busy = true
        stopFlag.reset()
        defer { busy = false }
        unloadState()
        _ = Self.initializeBackend
        let start = Date()
        let wantsGPU = useGPU && llama_supports_gpu_offload()
        var lastError: Error = GGUFError.loadFailed
        for gpu in wantsGPU ? [true, false] : [false] {
            try checkCancellation()
            var parameters = llama_model_default_params()
            parameters.n_gpu_layers = gpu ? -1 : 0
            parameters.progress_callback = { _, userData in
                guard let userData else { return true }
                return !Unmanaged<GGUFStopFlag>.fromOpaque(userData).takeUnretainedValue().isStopped
            }
            parameters.progress_callback_user_data = Unmanaged.passUnretained(stopFlag).toOpaque()
            // An empty offload-device list is necessary for a genuine CPU fallback:
            // n_gpu_layers=0 alone can still initialize a Metal backend for other operations.
            var noGPUDevices: [OpaquePointer?] = [nil]
            let candidate = noGPUDevices.withUnsafeMutableBufferPointer { devices in
                if !gpu { parameters.devices = devices.baseAddress }
                return url.path.withCString { llama_model_load_from_file($0, parameters) }
            }
            guard let candidate else {
                try checkCancellation()
                lastError = GGUFError.loadFailed
                continue
            }
            guard llama_model_has_decoder(candidate), !llama_model_has_encoder(candidate) else {
                llama_model_free(candidate)
                throw GGUFError.notTextModel
            }
            var contextParameters = llama_context_default_params()
            let trainedContext = Int(llama_model_n_ctx_train(candidate))
            contextParameters.n_ctx = UInt32(min(2048, trainedContext > 0 ? trainedContext : 2048))
            contextParameters.n_batch = 128
            contextParameters.n_ubatch = 128
            let threads = Int32(max(1, min(4, ProcessInfo.processInfo.activeProcessorCount - 2)))
            contextParameters.n_threads = threads
            contextParameters.n_threads_batch = threads
            contextParameters.offload_kqv = gpu
            contextParameters.op_offload = gpu
            contextParameters.abort_callback = { userData in
                guard let userData else { return false }
                return Unmanaged<GGUFStopFlag>.fromOpaque(userData).takeUnretainedValue().isStopped
            }
            contextParameters.abort_callback_data = Unmanaged.passUnretained(stopFlag).toOpaque()
            guard let candidateContext = llama_init_from_model(candidate, contextParameters) else {
                llama_model_free(candidate)
                try checkCancellation()
                lastError = GGUFError.contextFailed
                continue
            }
            model = candidate
            context = candidateContext
            var description = [CChar](repeating: 0, count: 512)
            _ = llama_model_desc(candidate, &description, description.count)
            let loaded = GGUFLoadInfo(description: String(cString: description), backend: gpu ? "Metal" : "CPU",
                contextTokens: Int(llama_n_ctx(candidateContext)), loadSeconds: Date().timeIntervalSince(start),
                usedCPUFallback: wantsGPU && !gpu)
            info = loaded
            do { try checkCancellation() } catch { unloadState(); throw error }
            return loaded
        }
        throw lastError
        #else
        throw GGUFError.unavailable
        #endif
    }

    func unload() throws {
        guard !busy else { throw GGUFError.busy }
        #if canImport(llama) && !targetEnvironment(simulator)
        unloadState()
        #endif
        info = nil
    }

    /// Fits selected passages with this loaded model's real chat template and tokenizer.
    /// Generation repeats the token check, so a prepared prompt can never bypass its context limit.
    func prepareGrounded(question: String, sources: [GGUFSource], maximumTokens: Int = 256) throws -> GGUFPreparedGrounding {
        guard !busy else { throw GGUFError.busy }
        try Task.checkCancellation()
        #if canImport(llama) && !targetEnvironment(simulator)
        guard let model, let info, let vocab = llama_model_get_vocab(model) else { throw GGUFError.notLoaded }
        return try GGUFGrounding.prepare(question: question, sources: sources, contextTokens: info.contextTokens, maximumResponseTokens: maximumTokens) { messages in
            try Task.checkCancellation()
            let prompt = self.formattedPrompt(messages, model: model)
            guard prompt.utf8.count <= 128_000 else { throw GGUFError.tokenizer }
            var tokens = [llama_token](repeating: 0, count: info.contextTokens)
            let count = prompt.withCString { llama_tokenize(vocab, $0, Int32(prompt.utf8.count), &tokens, Int32(tokens.count), true, true) }
            guard count != 0, count != Int32.min else { throw GGUFError.tokenizer }
            return abs(Int(count))
        }
        #else
        throw GGUFError.unavailable
        #endif
    }

    func generate(messages: [GGUFChatMessage], maximumTokens: Int = 256, temperature: Float = 0.7,
                  onChunk: @Sendable (String) async -> Void) async throws -> GGUFMetrics {
        guard !busy else { throw GGUFError.busy }
        try Task.checkCancellation()
        #if canImport(llama) && !targetEnvironment(simulator)
        guard let model, let context, let info else { throw GGUFError.notLoaded }
        busy = true
        stopFlag.reset()
        defer { busy = false; llama_memory_clear(llama_get_memory(context), true) }
        let prompt = formattedPrompt(messages, model: model)
        let vocab = llama_model_get_vocab(model)
        guard let vocab, prompt.utf8.count <= 128_000 else { throw GGUFError.tokenizer }
        let maximum = min(max(1, maximumTokens), 512)
        var tokens = [llama_token](repeating: 0, count: info.contextTokens)
        let tokenCount = prompt.withCString {
            llama_tokenize(vocab, $0, Int32(prompt.utf8.count), &tokens, Int32(tokens.count), true, true)
        }
        guard tokenCount > 0 else { throw tokenCount < 0 ? GGUFError.promptTooLong(info.contextTokens) : GGUFError.tokenizer }
        tokens.removeSubrange(Int(tokenCount)..<tokens.count)
        guard tokens.count + maximum <= info.contextTokens else { throw GGUFError.promptTooLong(info.contextTokens) }
        llama_memory_clear(llama_get_memory(context), true)
        guard let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params()) else { throw GGUFError.contextFailed }
        defer { llama_sampler_free(sampler) }
        if temperature <= 0 {
            llama_sampler_chain_add(sampler, llama_sampler_init_greedy())
        } else {
            llama_sampler_chain_add(sampler, llama_sampler_init_top_k(40))
            llama_sampler_chain_add(sampler, llama_sampler_init_top_p(0.9, 1))
            llama_sampler_chain_add(sampler, llama_sampler_init_temp(min(temperature, 2)))
            llama_sampler_chain_add(sampler, llama_sampler_init_dist(UInt32.random(in: 0..<UInt32.max)))
        }
        let promptStart = Date()
        for start in stride(from: 0, to: tokens.count, by: 128) {
            try checkCancellation()
            var chunk = Array(tokens[start..<min(start + 128, tokens.count)])
            let result = chunk.withUnsafeMutableBufferPointer { llama_decode(context, llama_batch_get_one($0.baseAddress, Int32($0.count))) }
            if result != 0 { try checkCancellation(); throw GGUFError.decodeFailed(result) }
        }
        llama_synchronize(context)
        let promptSeconds = Date().timeIntervalSince(promptStart)
        let generationStart = Date()
        var generated = 0
        var pending = Data()
        var reachedLimit = true
        for _ in 0..<maximum {
            try checkCancellation()
            var token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) { reachedLimit = false; break }
            generated += 1
            var piece = [CChar](repeating: 0, count: 256)
            var length = llama_token_to_piece(vocab, token, &piece, Int32(piece.count), 0, false)
            if length < 0, length != Int32.min {
                piece = [CChar](repeating: 0, count: Int(-length))
                length = llama_token_to_piece(vocab, token, &piece, Int32(piece.count), 0, false)
            }
            guard length >= 0 else { throw GGUFError.tokenizer }
            pending.append(contentsOf: piece.prefix(Int(length)).map { UInt8(bitPattern: $0) })
            if let text = String(data: pending, encoding: .utf8) {
                pending.removeAll(keepingCapacity: true)
                if !text.isEmpty { await onChunk(text) }
            }
            let result = llama_decode(context, llama_batch_get_one(&token, 1))
            if result != 0 { try checkCancellation(); throw GGUFError.decodeFailed(result) }
            await Task.yield()
        }
        if !pending.isEmpty { await onChunk(String(decoding: pending, as: UTF8.self)) }
        llama_synchronize(context)
        return GGUFMetrics(promptTokens: tokens.count, generatedTokens: generated, promptSeconds: promptSeconds,
            generationSeconds: Date().timeIntervalSince(generationStart), reachedTokenLimit: reachedLimit)
        #else
        throw GGUFError.unavailable
        #endif
    }

    private func checkCancellation() throws {
        if Task.isCancelled || stopFlag.isStopped { throw CancellationError() }
    }

    #if canImport(llama) && !targetEnvironment(simulator)
    private func unloadState() {
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
        context = nil
        model = nil
        info = nil
    }

    private func formattedPrompt(_ messages: [GGUFChatMessage], model: OpaquePointer) -> String {
        let fallback = messages.map { "\($0.role.capitalized): \($0.text)" }.joined(separator: "\n\n") + "\n\nAssistant:"
        guard let template = llama_model_chat_template(model, nil) else { return fallback }
        let allocated = messages.flatMap { [strdup($0.role), strdup($0.text)] }
        defer { allocated.forEach { free($0) } }
        guard allocated.allSatisfy({ $0 != nil }) else { return fallback }
        let chat = messages.indices.map { llama_chat_message(role: UnsafePointer(allocated[$0 * 2]!), content: UnsafePointer(allocated[$0 * 2 + 1]!)) }
        var output = [CChar](repeating: 0, count: max(1024, fallback.utf8.count * 2))
        var count = llama_chat_apply_template(template, chat, chat.count, true, &output, Int32(output.count))
        if count > output.count {
            guard count <= 128_000 else { return fallback }
            output = [CChar](repeating: 0, count: Int(count))
            count = llama_chat_apply_template(template, chat, chat.count, true, &output, Int32(output.count))
        }
        guard count > 0, count <= output.count else { return fallback }
        return String(decoding: output.prefix(Int(count)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
    #endif
}
