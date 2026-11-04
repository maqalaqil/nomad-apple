import SwiftUI

struct OfflinePreparationView: View {
    @Binding var selection: NomadModule?
    @AppStorage("offline.manualChecks") private var savedChecks = ""
    @AppStorage("offline.lastManualCheck") private var lastCheck = 0.0
    private let preparation: [(String, String, NomadModule)] = [
        ("Choose your content", "Download Wikipedia editions and maps, or add direct file links. Allow space for the download and imported copy.", .downloads),
        ("Read a local resource", "Import documents and ZIM archives, then open their articles and images.", .library),
        ("Prepare your maps", "Import map archives and check the places and zoom levels you need.", .maps),
        ("Prepare a GGUF model", "Import a suitable model in Local AI Models and test it on this iPad.", .models),
        ("Prepare the AI Assistant", "Enable Apple Intelligence in Settings, let its model finish downloading, and test questions using your indexed documents.", .assistant),
        ("Prepare languages", "Download the translation languages you will use while connected.", .translation),
        ("Prepare courses", "Import channel metadata and content together, and check the supported lesson and exercise formats.", .education)
    ]
    private let checks: [(String, String)] = [
        ("network", "Airplane mode is on and Wi-Fi is off."),
        ("restart", "I closed and reopened the app, then restarted the iPad."),
        ("reading", "My required documents, books, ZIM search and images open."),
        ("maps", "My required map areas and zoom levels render."),
        ("ai", "The model and translation languages I need work locally, or I do not need them."),
        ("courses", "My required media, courses and exercises work, or I do not need them."),
        ("exports", "I tested important exports and have a recovery copy of irreplaceable data."),
        ("installation", "My app installation will remain valid for the time I need it offline.")
    ]

    var body: some View {
        Form {
            Section("Prepare while connected") {
                ForEach(preparation, id: \.0) { item in
                    Button { selection = item.2 } label: {
                        VStack(alignment: .leading, spacing: 7) {
                            Label(item.0, systemImage: item.2.symbol).font(.headline)
                            Text(item.1).font(.subheadline).foregroundStyle(.secondary)
                        }.padding(.vertical, 5)
                    }.buttonStyle(.plain)
                }
            }
            Section("Check on this iPad") {
                Text("This is your manual checklist. It does not automatically verify network isolation, downloaded models, file contents, or installation validity. Repeat it after changing content or updating the app.")
                    .font(.subheadline).foregroundStyle(.secondary)
                ForEach(checks, id: \.0) { item in
                    Toggle(item.1, isOn: Binding(get: { selectedChecks.contains(item.0) }, set: { checked in
                        var values = selectedChecks
                        if checked { values.insert(item.0) } else { values.remove(item.0) }
                        savedChecks = values.sorted().joined(separator: ",")
                    }))
                }
                Button("Record completed manual check", systemImage: "checkmark.circle") { lastCheck = Date().timeIntervalSince1970 }
                    .disabled(selectedChecks.count != checks.count)
                if lastCheck > 0 {
                    LabeledContent("Last recorded check", value: Date(timeIntervalSince1970: lastCheck).formatted(date: .abbreviated, time: .shortened))
                }
                Button("Reset checklist") { savedChecks = "" }
            }
            Section("How offline use works") {
                Text("Downloaded and imported resources remain on this iPad. New downloads and app updates need a transfer or network connection. The content catalog is a bundled snapshot; browsing it works offline, but downloading its files needs a connection.")
                Text("Server account services, live collaboration, and mesh radio integration are not available in this build. An internet connection or external radio does not enable those features.")
                Text("iPadOS controls background work. Keep large imports, indexing, and model generation in the foreground. If a transfer stops, reopen Downloads and resume it. Use the available export controls before removing the app or a resource.")
                Text("The full upstream NOMAD feature set is still being implemented. Each module describes its current capabilities; unsupported formats and missing integrations are not ready for offline reliance.")
            }
        }
    }
    private var selectedChecks: Set<String> {
        Set(savedChecks.split(separator: ",").map(String.init)).intersection(Set(checks.map(\.0)))
    }
}
