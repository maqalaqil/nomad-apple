#if DEBUG
import SwiftUI
import Observation
import FoundationModels
import NaturalLanguage
@preconcurrency import Translation
import CryptoKit
import Darwin

private struct DeviceValidationStep: Codable, Identifiable, Sendable {
    let id: String
    var status: String
    var seconds: Double = 0
    var details: [String: String] = [:]
    var measurements: [String: Double] = [:]
    var output: String?
}

private struct DeviceValidationReport: Encodable, Sendable {
    let formatVersion = 1
    let runID = UUID()
    let startedAt = Date()
    var completedAt: Date?
    var status = "running"
    var environment: [String: String]
    var steps: [DeviceValidationStep] = []
    let scope = "Local physical-device diagnostics. Generated text and ranking are observations, not quality certifications. The diagnostic engines issue no network requests or user-library writes. Network isolation was not independently verified; these checks do not establish airplane-mode readiness."
}

private struct DeviceValidationFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Only compiled in DEBUG. Root launch routing controls access through --device-validation.
struct DeviceValidationView: View {
    @State private var runner = DeviceValidationRunner()
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Local device validation").font(.title2.bold())
                    Text("Runs local tests using optional Documents/Validation/model.gguf, sample.zim and sample.pmtiles. Missing fixtures are skipped. Your library, chats, and imported courses are not modified.").foregroundStyle(.secondary)
                    Text("These engine checks do not independently verify network isolation or airplane-mode readiness.").font(.caption).foregroundStyle(.secondary)
                    if runner.running { ProgressView(runner.progress); Button("Cancel validation", role: .cancel) { runner.cancel() } }
                    else { Text(runner.progress); Button("Run validation again") { runner.start() } }
                    if let error = runner.reportError { Text(error).foregroundStyle(.red) }
                    if FileManager.default.fileExists(atPath: runner.reportURL.path) { ShareLink("Export device report", item: runner.reportURL) }
                }
                ForEach(runner.report?.steps ?? []) { step in
                    Section(step.id) {
                        Text(step.status).font(.headline)
                        ForEach(step.details.keys.sorted(), id: \.self) { key in Text("\(key): \(step.details[key] ?? "")").font(.caption) }
                        ForEach(step.measurements.keys.sorted(), id: \.self) { key in Text("\(key): \((step.measurements[key] ?? 0).formatted())").font(.caption) }
                        if let output = step.output { Text(output).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                    }
                }
            }
            .navigationTitle("Device validation")
            .task { if runner.report == nil { runner.start() } }
            .onDisappear { runner.cancel() }
            .onChange(of: scenePhase) { _, phase in if phase == .background { runner.cancel() } }
        }
    }
}

@MainActor @Observable private final class DeviceValidationRunner {
    private(set) var report: DeviceValidationReport?
    private(set) var running = false
    private(set) var progress = "Ready"
    private(set) var reportError: String?
    // Explicit DEBUG-only root lets desktop acceptance use isolated fixtures and reports.
    // Normal device launches continue to use the application's Documents directory.
    let documents: URL = {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--validation-root"), arguments.indices.contains(index + 1), arguments[index + 1].hasPrefix("/") {
            return URL(fileURLWithPath: arguments[index + 1], isDirectory: true).standardizedFileURL
        }
        return URL.documentsDirectory.resolvingSymlinksInPath()
    }()
    var reportURL: URL { documents.appendingPathComponent("nomad-device-report.json") }
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let engine = GGUFEngine()

    func start() {
        guard !running else { return }
        running = true; reportError = nil
        task = Task { await run() }
    }
    func cancel() { task?.cancel(); engine.cancel(); if running { progress = "Canceling and releasing local test resources…" } }

    private func run() async {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nomad-device-validation-\(UUID().uuidString)")
        #if os(iOS)
        let previousIdleSetting = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        #endif
        defer {
            #if os(iOS)
            UIApplication.shared.isIdleTimerDisabled = previousIdleSetting
            #endif
            do { if FileManager.default.fileExists(atPath: temporary.path) { try FileManager.default.removeItem(at: temporary) } }
            catch { report?.steps.append(.init(id: "temporary-cleanup", status: "failed", details: ["error": error.localizedDescription])) }
            // Build the completed value before assigning an @Observable optional.
            // Reading report while its modify accessor is active traps exclusivity.
            if var finished = report {
                finished.completedAt = Date()
                finished.status = Task.isCancelled ? "cancelled" : (finished.steps.contains(where: { $0.status == "failed" }) ? "completed-with-failures" :
                    (finished.steps.contains(where: { $0.status == "cancelled" }) ? "completed-with-cancellations" : "completed"))
                report = finished
            }
            progress = Task.isCancelled ? "Canceled. Partial results are saved." : "Finished. Review actual measurements and skipped tests below."
            persist(); running = false; task = nil
        }
        report = DeviceValidationReport(environment: environment())
        persist()
        await step("FoundationModels availability") {
            let availability: String
            switch SystemLanguageModel.default.availability {
            case .available: availability = "available"
            case .unavailable(.deviceNotEligible): availability = "deviceNotEligible"
            case .unavailable(.appleIntelligenceNotEnabled): availability = "appleIntelligenceNotEnabled"
            case .unavailable(.modelNotReady): availability = "modelNotReady"
            case .unavailable: availability = "unavailable (other reason)"
            }
            return .init(id: "", status: "completed", details: ["availability": availability, "generation": "not requested; availability check only"])
        }
        await step("Native CPU and storage") {
            let worker = Task.detached(priority: .utility) { try NativeBenchmarkEngine.run(temporaryRoot: temporary) }
            let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
            guard result.valid else { throw DeviceValidationFailure(message: "Benchmark returned invalid measurements.") }
            return .init(id: "", status: "completed", details: ["cpuDigest": result.cpuLastDigest, "storageDigest": result.storageDigest, "storageIntegrity": "read bytes and SHA-256 matched the bytes written", "interpretation": "Single-worker SHA-256; synchronized write plus cached read/verify, not a disk hardware rating."], measurements: ["cpuHashes": Double(result.cpuHashes), "cpuBytes": Double(result.cpuBytes), "cpuSeconds": result.cpuSeconds, "cpuMiBPerSecond": result.cpuMiBPerSecond, "storageBytes": Double(result.storageBytes), "writeSeconds": result.writeSeconds, "readVerifySeconds": result.readVerifySeconds, "writeMiBPerSecond": result.writeMiBPerSecond, "readVerifyMiBPerSecond": result.readVerifyMiBPerSecond])
        }
        await step("Native sentence embeddings and ranking") {
            let available = await Task.detached { NLEmbedding.sentenceEmbedding(for: .english) != nil }.value
            guard available else { return .init(id: "", status: "skipped", details: ["reason": "The local English NLEmbedding sentence model is unavailable. No model download requested."] ) }
            let samples = [
                ("TEST-ONLY plants", "Green plants use sunlight to turn water and carbon dioxide into sugars during photosynthesis."),
                ("TEST-ONLY astronomy", "A planet follows an orbit around a star because of gravitational attraction."),
                ("TEST-ONLY baking", "Bread dough rises before baking in a hot oven.")
            ]
            let passages = samples.enumerated().map { index, pair in SearchHit(id: "device-validation-\(index)", documentID: UUID(), documentTitle: pair.0, excerpt: pair.1, score: 0) }
            let semantic = SemanticEngine()
            let snapshot = try await semantic.build(passages, language: "en") { _ in }
            let query = "How does a plant get energy from sunlight?"
            let hits = try await semantic.search(query, snapshot: snapshot, allowed: snapshot.documentIDs, limit: 3)
            let rows = hits.enumerated().map { index, hit in "\(index + 1). \(hit.documentTitle) | cosine=\(hit.score) | \(hit.excerpt)" }.joined(separator: "\n")
            return .init(id: "", status: "completed", details: ["query": query, "fixture": "Three test-only passages; isolated in memory", "interpretation": "Actual semantic ranking is recorded without an invented quality threshold."], measurements: ["dimension": Double(snapshot.dimension), "revision": Double(snapshot.revision), "indexedPassages": Double(snapshot.passages.count), "returnedHits": Double(hits.count)], output: rows)
        }
        await step("Direct downloaded archive storage") {
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            let canShare = try InternalDownloadLink.probe(in: temporary)
            guard canShare else {
                return .init(id: "", status: "skipped", details: ["reason": "This filesystem requires a full import copy; capacity preflight must include that copy."])
            }
            let downloads = temporary.appendingPathComponent("CompletedDownloads", isDirectory: true)
            try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
            let source = downloads.appendingPathComponent("local-guide.txt")
            let bytes = Data("A compass points toward magnetic north.".utf8)
            try bytes.write(to: source, options: .withoutOverwriting)
            let library = LibraryStore(rootURL: temporary.appendingPathComponent("TestLibrary", isDirectory: true))
            try await library.importDownloadedFile(source, sourceRoot: downloads, expectedBytes: UInt64(bytes.count), name: "Local guide.txt")
            guard let document = library.documents.first else { throw DeviceValidationFailure(message: "The imported guide was not recorded.") }
            try FileManager.default.removeItem(at: source)
            guard try Data(contentsOf: library.fileURL(for: document)) == bytes,
                  library.search("magnetic north").first?.documentID == document.id else {
                throw DeviceValidationFailure(message: "The imported guide did not survive removal of its download entry.")
            }
            return .init(id: "", status: "completed", details: ["sameVolumeSharing": "supported; actual inode/size checks passed", "libraryImport": "read and searched successfully after the test download was removed", "scope": "Isolated tiny test files; user archives and download history were not changed."])
        }
        await step("FoundationModels local generation") {
            guard case .available = SystemLanguageModel.default.availability else {
                return .init(id: "", status: "skipped", details: ["reason": "The on-device system model is unavailable: \(String(describing: SystemLanguageModel.default.availability)). No download requested."])
            }
            let prompt = "Write one short sentence about using a device without an internet connection."
            let text = try await Self.bounded(seconds: 30, cancel: {}) {
                let session = LanguageModelSession(model: .default, instructions: "Reply concisely.")
                var observed = ""
                for try await response in session.streamResponse(to: prompt, options: GenerationOptions(temperature: 0, maximumResponseTokens: 32)) {
                    try Task.checkCancellation()
                    guard response.content.utf8.count <= 128 * 1_024 else { throw DeviceValidationFailure(message: "The system model response exceeded the diagnostic output bound.") }
                    observed = response.content
                }
                return observed
            }
            return .init(id: "", status: "completed", details: ["prompt": prompt, "backend": "Apple FoundationModels on-device system model", "interpretation": "Actual generated output; answer quality is not graded. Token usage is not exposed by this check."], measurements: ["maximumResponseTokens": 32, "outputUTF8Bytes": Double(text.utf8.count)], output: text)
        }
        await step("GGUF local inference") {
            guard let model = try self.fixture("model.gguf", maximumBytes: 2 * 1_024 * 1_024 * 1_024) else {
                return .init(id: "", status: "skipped", details: ["reason": "Documents/Validation/model.gguf is absent."])
            }
            guard GGUFEngine.isAvailable else { return .init(id: "", status: "skipped", details: ["reason": "The real-device GGUF framework is not available in this build."]) }
            let handle = try FileHandle(forReadingFrom: model)
            let magic = try handle.read(upToCount: 4); try handle.close()
            guard magic == Data("GGUF".utf8) else { throw DeviceValidationFailure(message: "The optional model fixture does not have a GGUF header.") }
            let engine = self.engine
            var loaded: GGUFLoadInfo?
            var result: DeviceValidationStep
            let output = DeviceValidationTextBuffer()
            do {
                loaded = try await Self.bounded(seconds: 90, cancel: { engine.cancel() }) { try await engine.load(url: model, useGPU: true) }
                self.progress = "GGUF loaded using \(loaded!.backend); generating up to 64 tokens…"
                let prompt = "Reply with one short sentence explaining what an offline device is."
                let metrics = try await Self.bounded(seconds: 60, cancel: { engine.cancel() }) {
                    try await engine.generate(messages: [.init(role: "user", text: prompt)], maximumTokens: 64, temperature: 0) { chunk in await output.append(chunk) }
                }
                let text = await output.value
                result = .init(id: "", status: "completed", details: ["fixture": "Validation/model.gguf", "prompt": prompt, "backend": loaded!.backend, "modelDescription": loaded!.description, "cpuFallback": String(loaded!.usedCPUFallback), "tokenLimitReached": String(metrics.reachedTokenLimit), "interpretation": "Successful execution records raw output and timing; answer quality is not graded."], measurements: ["fileBytes": Double(try model.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0), "contextTokens": Double(loaded!.contextTokens), "loadSeconds": loaded!.loadSeconds, "promptTokens": Double(metrics.promptTokens), "generatedTokens": Double(metrics.generatedTokens), "promptSeconds": metrics.promptSeconds, "generationSeconds": metrics.generationSeconds, "tokensPerSecond": metrics.tokensPerSecond], output: text)
                let question = "What color are the orchid petals?"
                let source = GGUFSource(id: "diagnostic-orchid", documentID: UUID(), title: "TEST-ONLY field guide", excerpt: "The orchid in this field guide has violet petals and a white center.")
                let grounded = try await engine.prepareGrounded(question: question, sources: [source], maximumTokens: 64)
                let groundedOutput = DeviceValidationTextBuffer()
                let groundedMetrics = try await Self.bounded(seconds: 60, cancel: { engine.cancel() }) {
                    try await engine.generate(messages: grounded.messages, maximumTokens: grounded.maximumResponseTokens, temperature: 0) { chunk in await groundedOutput.append(chunk) }
                }
                guard groundedMetrics.promptTokens == grounded.promptTokens,
                      grounded.promptTokens + grounded.maximumResponseTokens <= loaded!.contextTokens else {
                    throw DeviceValidationFailure(message: "Grounded generation did not respect its measured token budget.")
                }
                let groundedText = await groundedOutput.value
                result.details["groundedQuestion"] = question
                result.details["groundedPassage"] = source.excerpt
                result.details["groundedOutput"] = groundedText
                result.details["groundedCitationWarning"] = GGUFGrounding.citationWarning(answer: groundedText, sources: grounded.sources) ?? "No out-of-range or missing citation number detected; factual support is not certified."
                result.measurements["groundedPromptTokens"] = Double(groundedMetrics.promptTokens)
                result.measurements["groundedGeneratedTokens"] = Double(groundedMetrics.generatedTokens)
            } catch {
                try? await engine.unload()
                if error is CancellationError { throw error }
                return .init(id: "", status: "failed", details: ["error": error.localizedDescription, "backend": loaded?.backend ?? "not loaded", "modelDescription": loaded?.description ?? "not loaded", "cleanup": "Dedicated test engine unload requested after failure."], measurements: loaded.map { ["loadSeconds": $0.loadSeconds, "contextTokens": Double($0.contextTokens)] } ?? [:], output: await output.value)
            }
            try await engine.unload()
            result.details["cleanup"] = "Dedicated test engine unloaded after generation."
            return result
        }
        await step("ZIM local archive") {
            guard let url = try self.fixture("sample.zim", maximumBytes: 512 * 1_024 * 1_024) else {
                return .init(id: "", status: "skipped", details: ["reason": "Documents/Validation/sample.zim is absent."])
            }
            let worker = Task.detached(priority: .utility) {
                try Task.checkCancellation()
                let archive = try NomadZIMArchive(url: url)
                let main = try archive.mainPath()
                let metadata = try archive.metadata(path: main)
                let data = try archive.read(path: main, offset: 0, length: 65_536)
                try Task.checkCancellation()
                let titles = try archive.search("", fullText: false, limit: 5)
                let sample = titles.compactMap { $0["title"] as? String }.joined(separator: "\n")
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                return DeviceValidationStep(id: "", status: "completed", details: ["fixture": "Validation/sample.zim", "title": archive.title, "mainPath": main, "mime": metadata["mime"] as? String ?? "unknown", "fullTextIndex": String(archive.hasFullTextIndex), "readSHA256": digest, "interpretation": "Archive open, main-page read and title listing; complete content/rendering coverage is not claimed."], measurements: ["articles": Double(archive.articleCount), "mainPageBytes": (metadata["size"] as? NSNumber)?.doubleValue ?? 0, "bytesRead": Double(data.count), "titlesReturned": Double(titles.count)], output: sample)
            }
            return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
        }
        await step("Isolated backup activation and rollback") {
            let worker = Task.detached(priority: .utility) {
                let root = temporary.appendingPathComponent("BackupValidation")
                let locations = BackupLocations(support: root.appendingPathComponent("Support"), documents: root.appendingPathComponent("Documents"))
                let suite = "NOMAD.Validation.\(UUID().uuidString)"
                guard let defaults = UserDefaults(suiteName: suite) else { throw DeviceValidationFailure(message: "Could not create isolated validation preferences.") }
                defer { defaults.removePersistentDomain(forName: suite) }
                let engine = BackupEngine(locations: locations, defaults: defaults)
                let notes = locations.support.appendingPathComponent("Nomad/Notes/notes.json")
                let downloads = locations.support.appendingPathComponent("NomadPad/Downloads/downloads.json")
                try FileManager.default.createDirectory(at: notes.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: downloads.deletingLastPathComponent(), withIntermediateDirectories: true)
                let id = UUID().uuidString
                func note(_ body: String) throws -> Data {
                    try JSONSerialization.data(withJSONObject: ["formatVersion": 1, "notes": [["id": id, "title": "Isolated validation note", "body": body, "createdAt": 1.0, "updatedAt": 2.0]]], options: .sortedKeys)
                }
                let original = try note("Original test record"), newer = try note("Newer test record retained for rollback")
                let transfer = Data("Isolated transfer marker; must remain unchanged".utf8)
                try original.write(to: notes); try transfer.write(to: downloads)
                let backup = try engine.export(selections: [.init(component: "notes", includeContent: false)])
                try newer.write(to: notes, options: .atomic)
                let review = try engine.stageSelected(backup, selected: ["notes"])
                try BackupRestoreCoordinator.schedule(review, selected: ["notes"], engine: engine)
                _ = try BackupRestoreCoordinator.activatePendingRestore(engine: engine)
                guard try Data(contentsOf: notes) == original, try Data(contentsOf: downloads) == transfer else {
                    throw DeviceValidationFailure(message: "Isolated backup activation or download exclusion failed.")
                }
                try BackupRestoreCoordinator.requestRollback(locations: locations)
                _ = try BackupRestoreCoordinator.activatePendingRestore(engine: engine)
                guard try Data(contentsOf: notes) == newer, try Data(contentsOf: downloads) == transfer else {
                    throw DeviceValidationFailure(message: "Isolated rollback did not restore the newer test record.")
                }
                try BackupRestoreCoordinator.discardRecovery(locations: locations)
                guard !BackupRestoreCoordinator.hasRecovery(locations: locations), !BackupRestoreCoordinator.hasPendingRestore(locations: locations) else {
                    throw DeviceValidationFailure(message: "Isolated recovery cleanup did not finish.")
                }
                return DeviceValidationStep(id: "", status: "completed", details: ["activation": "Original test note restored byte-for-byte", "rollback": "Newer test note recovered byte-for-byte", "downloadExclusion": "Isolated transfer marker unchanged", "cleanup": "Recovery and pending intent removed", "scope": "Temporary fixtures only. Does not validate external Files providers, a process restart, large backups or user workspace restoration."])
            }
            return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
        }
        await step("PMTiles local rendering") {
            guard let url = try self.fixture("sample.pmtiles", maximumBytes: 512 * 1_024 * 1_024) else {
                return .init(id: "", status: "skipped", details: ["reason": "Documents/Validation/sample.pmtiles is absent."])
            }
            let measurements = try await DeviceMapProbe().run(archive: url, screenshot: self.documents.appendingPathComponent("nomad-map-validation.png"))
            return .init(id: "", status: "completed", details: ["fixture": "Validation/sample.pmtiles", "resources": "Production bundled style/fonts/sprites and local byte-range archive handler", "networkPolicy": "HTTP(S) and WebSocket requests blocked by WebKit rules and local content security policy", "screenshot": "Documents/nomad-map-validation.png", "scope": "One small regional fixture; this does not validate the complete world archive or device airplane mode."], measurements: measurements)
        }
        let supportedTranslationLanguages = await LanguageAvailability().supportedLanguages
        let preferredTranslationIDs = [UserDefaults.standard.string(forKey: "tools.translation.source"),
                                       UserDefaults.standard.string(forKey: "tools.translation.target")].compactMap { $0 }
        let englishID = TranslationLanguageResolver.resolve(baseCode: "en", preferredIdentifiers: preferredTranslationIDs, supported: supportedTranslationLanguages)?.minimalIdentifier ?? "en"
        let arabicID = TranslationLanguageResolver.resolve(baseCode: "ar", preferredIdentifiers: preferredTranslationIDs, supported: supportedTranslationLanguages)?.minimalIdentifier ?? "ar"
        await step("Arabic and English translation readiness") {
            var details = ["englishIdentifier": englishID, "arabicIdentifier": arabicID,
                "scope": "Availability only, using supported variants and the user's selected language identifiers. No download requested; actual short translations are checked separately."]
            for (source, target, name) in [(englishID, arabicID, "English to Arabic"), (arabicID, englishID, "Arabic to English")] {
                try Task.checkCancellation()
                let status = await LanguageAvailability().status(from: Locale.Language(identifier: source), to: Locale.Language(identifier: target))
                switch status {
                case .installed: details[name] = "installed"
                case .supported: details[name] = "supported; language preparation required"
                case .unsupported: details[name] = "unsupported on this device"
                @unknown default: details[name] = "unknown"
                }
            }
            return .init(id: "", status: "completed", details: details)
        }

        for (source, target, name, text) in [
            (englishID, arabicID, "English to Arabic", "The library is available without an internet connection."),
            (arabicID, englishID, "Arabic to English", "هذه الخريطة محفوظة على الجهاز.")
        ] {
            await step("Installed translation: " + name) {
                let status = await LanguageAvailability().status(from: Locale.Language(identifier: source), to: Locale.Language(identifier: target))
                guard status == .installed else {
                    return .init(id: "", status: "skipped", details: ["reason": "Language pair is not installed. No model download requested."])
                }
                let translated = try await Self.bounded(seconds: 30, cancel: {}) {
                    let session = TranslationSession(installedSource: Locale.Language(identifier: source), target: Locale.Language(identifier: target))
                    guard await session.isReady else { throw DeviceValidationFailure(message: "Installed translation session is not ready.") }
                    try Task.checkCancellation()
                    return try await session.translate(text).targetText
                }
                guard !translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw DeviceValidationFailure(message: "The translation engine returned empty text.")
                }
                return .init(id: "", status: "completed", details: ["sourceText": text, "pair": name, "sourceIdentifier": source, "targetIdentifier": target,
                    "session": "Installed-only TranslationSession; no preparation or model download requested.",
                    "scope": "One short fixture. Raw output is recorded without a translation-quality grade; device network isolation and full article translation are separate checks."], output: translated)
            }
        }
        try? await engine.unload()
    }

    private func step(_ name: String, operation: () async throws -> DeviceValidationStep) async {
        guard !Task.isCancelled else { report?.steps.append(.init(id: name, status: "cancelled", details: ["reason": "Not started after cancellation."])); persist(); return }
        progress = name
        report?.steps.append(.init(id: name, status: "running")); persist()
        let started = ProcessInfo.processInfo.systemUptime
        var value: DeviceValidationStep
        do { value = try await operation(); try Task.checkCancellation() }
        catch is CancellationError { value = .init(id: "", status: "cancelled", details: ["reason": "Validation was cancelled."]) }
        catch { value = .init(id: "", status: "failed", details: ["error": error.localizedDescription]) }
        let completed = DeviceValidationStep(id: name, status: value.status, seconds: ProcessInfo.processInfo.systemUptime - started, details: value.details, measurements: value.measurements, output: value.output)
        if let index = report?.steps.lastIndex(where: { $0.id == name }) { report?.steps[index] = completed }
        persist()
    }
    private func fixture(_ name: String, maximumBytes: Int) throws -> URL? {
        let root = documents.appendingPathComponent("Validation"), url = root.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard url.resolvingSymlinksInPath().path == url.path, values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= maximumBytes else { throw DeviceValidationFailure(message: "The \(name) fixture must be a regular local file no larger than \(maximumBytes) bytes.") }
        return url
    }
    private func persist() {
        guard let report else { return }
        do {
            if FileManager.default.fileExists(atPath: reportURL.path) {
                let values = try reportURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { throw DeviceValidationFailure(message: "The device-report path is not a regular file.") }
            }
            try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(report).write(to: reportURL, options: .atomic)
        } catch { reportError = "Report could not be saved: \(error.localizedDescription)" }
    }
    private func environment() -> [String: String] {
        var system = utsname(); uname(&system)
        let capacity = MemoryLayout.size(ofValue: system.machine)
        let machine = withUnsafePointer(to: &system.machine) { pointer in pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) } }
        let process = ProcessInfo.processInfo
        let free = (try? documents.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? 0
        return ["os": process.operatingSystemVersionString, "deviceModel": NomadDeviceDescription.model, "hardwareIdentifier": machine,
                "physicalRAMBytes": String(process.physicalMemory), "availableStorageBytes": String(free), "activeCPUs": String(process.activeProcessorCount),
                "thermalState": String(describing: process.thermalState), "lowPowerMode": String(process.isLowPowerModeEnabled),
                "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                "appBuild": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown", "simulator": String(Self.isSimulator)]
    }
    private static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }
    nonisolated private static func bounded<T: Sendable>(seconds: Double, cancel: @escaping @Sendable () -> Void, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withTaskCancellationHandler(operation: {
            try await withThrowingTaskGroup(of: T.self) { group in
                group.addTask { try await operation() }
                group.addTask {
                    try await Task.sleep(for: .seconds(seconds)); cancel()
                    throw DeviceValidationFailure(message: "The test exceeded its \(Int(seconds))-second limit and cancellation was requested.")
                }
                defer { group.cancelAll() }
                guard let first = try await group.next() else { throw CancellationError() }
                return first
            }
        }, onCancel: cancel)
    }
}

private actor DeviceValidationTextBuffer {
    private(set) var value = ""
    func append(_ chunk: String) {
        // 64 generated tokens should remain far below this bound, even with a damaged vocabulary.
        if value.utf8.count < 128 * 1_024 { value.append(String(chunk.prefix(16 * 1_024))) }
    }
}
#endif
