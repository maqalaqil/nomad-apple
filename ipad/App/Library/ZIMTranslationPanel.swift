import SwiftUI
@preconcurrency import Translation

struct ZIMTranslationPanel: View {
    let translation: ZIMArticleTranslation
    @Environment(\.dismiss) private var dismiss
    @AppStorage("tools.translation.source") private var sourceID = "en"
    @AppStorage("tools.translation.target") private var targetID = "ar"
    @State private var languages: [String] = []
    @State private var languagesLoaded = false
    @State private var availability: LanguageAvailability.Status?
    @State private var preparation: TranslationSession.Configuration?
    @State private var preparing = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Translate the open article on this iPad while keeping its links, images and layout. The archived original is never changed.")
                    Text("Language downloads require a connection and an explicit preparation step. Translate article uses installed models only. Review important translations against the original.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("Languages") {
                    if !languagesLoaded { ProgressView("Loading supported languages…") }
                    else {
                        Picker("From", selection: $sourceID) {
                            if !languages.contains(sourceID) { Text("\(languageName(sourceID)) (not supported)").tag(sourceID) }
                            ForEach(languages, id: \.self) { Text(languageName($0)).tag($0) }
                        }
                        Picker("To", selection: $targetID) {
                            if !languages.contains(targetID) { Text("\(languageName(targetID)) (not supported)").tag(targetID) }
                            ForEach(languages, id: \.self) { Text(languageName($0)).tag($0) }
                        }
                    }
                    Text(status).font(.caption).foregroundStyle(availability == .installed ? Color.green : Color.secondary)
                    if availability == .supported {
                        Button("Prepare languages while online", systemImage: "arrow.down.circle") {
                            preparing = true
                            let value = TranslationSession.Configuration(source: Locale.Language(identifier: sourceID), target: Locale.Language(identifier: targetID))
                            if preparation?.source == value.source && preparation?.target == value.target { preparation?.invalidate() }
                            else { preparation = value }
                        }
                    }
                    Button("Check installed languages", systemImage: "arrow.clockwise") { Task { await check() } }
                }.disabled(translation.busy || preparing)
                Section {
                    if preparing { ProgressView("Preparing languages…") }
                    if translation.busy {
                        ProgressView(translation.progress.isEmpty ? "Updating article…" : translation.progress)
                        Button("Cancel") { translation.cancel() }
                    } else if translation.translated {
                        Button("Restore original article", systemImage: "arrow.uturn.backward") { translation.restore() }
                    } else {
                        Button("Translate article offline", systemImage: "character.bubble") { translation.translate(source: sourceID, target: targetID) }
                            .disabled(!translation.ready || availability != .installed || preparing)
                    }
                    if !translation.notice.isEmpty { Text(translation.notice).font(.footnote) }
                    if let failure = translation.error { Text(failure).foregroundStyle(.orange) }
                    Text("Up to 512 visible text runs or 60,000 characters per article. Code, equations, hidden text and controls are skipped. Translations follow the page’s existing text-node boundaries; wording around inline links may need review. The translated display is temporary.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Translate article")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task {
                let supported = await LanguageAvailability().supportedLanguages
                guard !Task.isCancelled else { return }
                languages = supported.map(\.minimalIdentifier).sorted { languageName($0).localizedCompare(languageName($1)) == .orderedAscending }
                if let resolved = TranslationLanguageResolver.resolve(preferredIdentifier: sourceID, supported: supported) { sourceID = resolved.minimalIdentifier }
                if let resolved = TranslationLanguageResolver.resolve(preferredIdentifier: targetID, supported: supported) { targetID = resolved.minimalIdentifier }
                languagesLoaded = true
            }
            .task(id: "\(sourceID)|\(targetID)|\(languagesLoaded)") { await check() }
            .translationTask(preparation) { session in
                defer { preparing = false }
                do { try await session.prepareTranslation(); await check() }
                catch { self.error = error.localizedDescription; await check() }
            }
            .alert("Language preparation", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
        }
    }
    private func languageName(_ identifier: String) -> String { Locale.current.localizedString(forIdentifier: identifier) ?? identifier }
    private var status: String {
        if sourceID == targetID { return "Choose two different languages." }
        switch availability {
        case .installed: return "Language pair installed for offline translation"
        case .supported: return "Download the language models while online first"
        case .unsupported: return "This language pair is not supported by this iPad"
        case nil: return "Checking language availability…"
        @unknown default: return "Language availability is unknown"
        }
    }
    private func check() async {
        availability = nil
        guard languagesLoaded else { return }
        guard sourceID != targetID, languages.contains(sourceID), languages.contains(targetID) else { availability = .unsupported; return }
        let source = sourceID, target = targetID
        let result = await LanguageAvailability().status(from: Locale.Language(identifier: source), to: Locale.Language(identifier: target))
        guard !Task.isCancelled, source == sourceID, target == targetID else { return }
        availability = result
    }
}
