import SwiftUI
@preconcurrency import Translation
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct ToolLanguage: Identifiable {
    let id: String
    var name: String { Locale.current.localizedString(forIdentifier: id) ?? id }
}

struct TranslationView: View {
    @AppStorage("tools.translation.source") private var sourceID = "en"
    @AppStorage("tools.translation.target") private var targetID = "ar"
    @State private var languages: [ToolLanguage] = []
    @State private var languagesLoaded = false
    @State private var input = ""
    @State private var output = ""
    @State private var availability: LanguageAvailability.Status?
    @State private var preparationConfiguration: TranslationSession.Configuration?
    @State private var busy = false
    @State private var notice = ""
    @State private var error: String?
    @State private var importing = false
    @State private var exporting = false
    @State private var requests = TranslationRequestState()

    var body: some View {
        Form {
            Section {
                Label("On-device translation", systemImage: "character.bubble")
                    .font(.headline)
                Text("Download languages while online, then translate using installed models. The Translate button uses an installed-only session and cannot request model downloads.")
                    .foregroundStyle(.secondary)
                Text("Apple controls language support and model storage. Recheck availability before traveling offline.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Languages") {
                if !languagesLoaded { ProgressView("Loading supported languages…") }
                else {
                    Picker("From", selection: $sourceID) {
                        if !languages.contains(where: { $0.id == sourceID }) { Text("\(ToolLanguage(id: sourceID).name) (not supported)").tag(sourceID) }
                        ForEach(languages) { Text($0.name).tag($0.id) }
                    }
                    Picker("To", selection: $targetID) {
                        if !languages.contains(where: { $0.id == targetID }) { Text("\(ToolLanguage(id: targetID).name) (not supported)").tag(targetID) }
                        ForEach(languages) { Text($0.name).tag($0.id) }
                    }
                    Button("Swap languages", systemImage: "arrow.up.arrow.down") {
                        let previous = sourceID; sourceID = targetID; targetID = previous
                        output = ""
                    }
                }
                Label(availabilityText, systemImage: availability == .installed ? "checkmark.circle.fill" : "arrow.down.circle")
                    .foregroundStyle(availability == .installed ? Color.green : Color.secondary)
                if availability == .supported {
                    Button("Download / prepare languages", systemImage: "arrow.down.circle") { prepareLanguages() }
                        .disabled(busy)
                }
                Button("Check language availability", systemImage: "arrow.clockwise") { Task { await checkAvailability() } }
                    .disabled(busy)
            }.disabled(busy)
            Section("Original text") {
                TextEditor(text: $input).frame(minHeight: 180).accessibilityLabel("Text to translate").disabled(busy)
                Button("Import text", systemImage: "square.and.arrow.down") { importing = true }
                    .disabled(busy)
                Button("Translate offline", systemImage: "character.bubble.fill") { Task { await translate() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || availability != .installed || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if busy { ProgressView("Working…") }
                if !notice.isEmpty { Text(notice).font(.caption).foregroundStyle(.secondary) }
            }
            if !output.isEmpty {
                Section("Translation") {
                    Text(output).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    HStack {
                        Button("Copy", systemImage: "doc.on.doc") { NomadClipboard.copy(output); notice = "Translation copied." }
                        Button("Export", systemImage: "square.and.arrow.up") { exporting = true }
                    }.buttonStyle(.borderless)
                    Text("Review critical translations against the original. Text remains temporary until exported.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                Text("Translate pasted or imported text here. For a ZIM article, open it in the Knowledge Library and choose Translate. Article translation keeps local links and images and leaves the original archive intact.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Translation")
        .task {
            let supported = await LanguageAvailability().supportedLanguages
            guard !Task.isCancelled else { return }
            languages = supported.map { ToolLanguage(id: $0.minimalIdentifier) }.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
            if let resolved = TranslationLanguageResolver.resolve(preferredIdentifier: sourceID, supported: supported) { sourceID = resolved.minimalIdentifier }
            if let resolved = TranslationLanguageResolver.resolve(preferredIdentifier: targetID, supported: supported) { targetID = resolved.minimalIdentifier }
            languagesLoaded = true
        }
        .task(id: "\(sourceID)|\(targetID)|\(languagesLoaded)") { output = ""; notice = ""; await checkAvailability() }
        .onChange(of: input) { output = ""; notice = "" }
        .onDisappear { requests.invalidate() }
        .translationTask(preparationConfiguration) { session in
            defer { busy = false }
            do {
                try await session.prepareTranslation()
                await checkAvailability()
                notice = availability == .installed ? "Languages installed. Test translation with Wi-Fi disabled before relying on it offline." : "Preparation request finished. Downloads may still be running; check availability again before translating."
            } catch { self.error = error.localizedDescription; await checkAvailability() }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.text, .json]) { result in
            do { input = try ToolReadText(result.get()); output = "" }
            catch { self.error = error.localizedDescription }
        }
        .fileExporter(isPresented: $exporting, document: ToolTextDocument(text: output), contentType: .plainText, defaultFilename: "translation-\(targetID)") { result in
            if case .failure(let failure) = result { error = failure.localizedDescription }
        }
        .alert("Translation unavailable", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private var availabilityText: String {
        if sourceID == targetID { return "Choose two different languages." }
        switch availability {
        case .installed: return "Language pair installed — ready for offline translation"
        case .supported: return "Supported — language download required"
        case .unsupported: return "This language pair is not supported by this device"
        case nil: return "Checking installed languages…"
        @unknown default: return "Unknown language availability"
        }
    }

    @MainActor private func checkAvailability() async {
        availability = nil
        guard languagesLoaded else { return }
        guard sourceID != targetID, languages.contains(where: { $0.id == sourceID }), languages.contains(where: { $0.id == targetID }) else { availability = .unsupported; return }
        let pair = TranslationLanguagePair(source: sourceID, target: targetID)
        guard let result = await requests.checkAvailability(pair: pair, currentPair: {
            TranslationLanguagePair(source: sourceID, target: targetID)
        }, check: { pair in
            await LanguageAvailability().status(from: Locale.Language(identifier: pair.source), to: Locale.Language(identifier: pair.target))
        }) else { return }
        availability = result
    }

    @MainActor private func prepareLanguages() {
        busy = true; notice = "The system may ask permission to download language models."; output = ""
        let configuration = TranslationSession.Configuration(source: Locale.Language(identifier: sourceID), target: Locale.Language(identifier: targetID))
        if preparationConfiguration?.source == configuration.source && preparationConfiguration?.target == configuration.target {
            preparationConfiguration?.invalidate()
        } else { preparationConfiguration = configuration }
    }

    @MainActor private func translate() async {
        guard input.utf8.count <= 100_000 else { error = "Translate smaller sections, up to 100 KB each."; return }
        let request = TranslationTextRequest(pair: .init(source: sourceID, target: targetID), text: input)
        let token = requests.beginTextRequest(request)
        busy = true; notice = ""; output = ""
        defer { busy = false }
        do {
            let session = TranslationSession(installedSource: Locale.Language(identifier: request.pair.source), target: Locale.Language(identifier: request.pair.target))
            guard await session.isReady else {
                await checkAvailability()
                throw ToolFailure.message("The language models are not installed. Connect to the internet and use Download / prepare languages first.")
            }
            try Task.checkCancellation()
            guard requests.accepts(token, currentRequest: currentTextRequest) else { return }
            let response = try await session.translate(request.text)
            guard requests.accepts(token, currentRequest: currentTextRequest) else { return }
            output = response.targetText
            notice = "Translated using installed language models."
        } catch {
            if requests.accepts(token, currentRequest: currentTextRequest) { self.error = error.localizedDescription }
        }
    }

    private var currentTextRequest: TranslationTextRequest {
        .init(pair: .init(source: sourceID, target: targetID), text: input)
    }
}
