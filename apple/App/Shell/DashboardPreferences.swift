import SwiftUI
import Observation

struct DashboardLink: Codable, Identifiable {
    var id = UUID()
    var title: String
    var url: URL
}
struct DashboardConfiguration: Codable {
    var favorites = ["library", "assistant", "notes", "pdf", "inventory", "media"]
    var links: [DashboardLink] = []
}

@MainActor @Observable
final class DashboardPreferences {
    private(set) var configuration = DashboardConfiguration()
    private(set) var error: String?
    @ObservationIgnored private var file = LocalManifestFile(url: URL.applicationSupportDirectory.appendingPathComponent("NomadPad/dashboard.json"))
    init() {
        do {
            configuration = try file.load(DashboardConfiguration.self) { value in
                guard Set(value.favorites).count == value.favorites.count, Set(value.links.map(\.id)).count == value.links.count,
                      value.links.count <= 100, value.links.allSatisfy({ ["https", "http"].contains($0.url.scheme ?? "") && $0.url.host != nil && !$0.title.isEmpty }) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
            } ?? DashboardConfiguration()
        } catch { self.error = "Dashboard preferences could not be read. Your saved configuration has been preserved." }
    }
    var writable: Bool { file.isReady }
    func save(_ value: DashboardConfiguration) throws {
        try file.save(value)
        configuration = value
    }
}

struct DashboardPreferencesView: View {
    let store: DashboardPreferences
    @State private var favorites: Set<String>
    @State private var links: [DraftLink]
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    private struct DraftLink: Identifiable {
        var id = UUID()
        var title = ""
        var address = ""
    }
    init(store: DashboardPreferences) {
        self.store = store
        _favorites = State(initialValue: Set(store.configuration.favorites))
        _links = State(initialValue: store.configuration.links.map { DraftLink(id: $0.id, title: $0.title, address: $0.url.absoluteString) })
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Favorite modules") {
                    ForEach(NomadModule.allCases.filter { ![.home, .settings, .depot].contains($0) }) { module in
                        Toggle(module.title, isOn: Binding(get: { favorites.contains(module.rawValue) }, set: { on in
                            if on { favorites.insert(module.rawValue) } else { favorites.remove(module.rawValue) }
                        }))
                    }
                }
                Section("Custom links") {
                    Text("Links open in the browser and may require a network connection. Adding a link does not download its content.").font(.caption).foregroundStyle(.secondary)
                    ForEach($links) { $link in
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("Title", text: $link.title)
                            TextField("https://…", text: $link.address).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                            Button("Remove from dashboard", role: .destructive) { links.removeAll { $0.id == link.id } }
                        }.padding(.vertical, 5)
                    }
                    Button("Add link", systemImage: "plus") { links.append(DraftLink()) }.disabled(links.count >= 100)
                }
                if let error { Text(error).foregroundStyle(.orange) }
            }
            .navigationTitle("Customize dashboard")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(!store.writable) }
            }
            .interactiveDismissDisabled()
        }
    }
    private func save() {
        var valid: [DashboardLink] = []
        for link in links {
            let title = link.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, title.count <= 100,
                  let url = URL(string: link.address.trimmingCharacters(in: .whitespacesAndNewlines)),
                  ["http", "https"].contains(url.scheme ?? ""), url.host != nil, url.user == nil, url.password == nil else {
                error = "Give every link a title and a valid HTTP or HTTPS address without embedded credentials."
                return
            }
            valid.append(DashboardLink(id: link.id, title: title, url: url))
        }
        do {
            try store.save(DashboardConfiguration(favorites: NomadModule.allCases.map(\.rawValue).filter { favorites.contains($0) }, links: valid))
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
