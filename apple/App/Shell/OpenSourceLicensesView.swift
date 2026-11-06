import SwiftUI

/// License texts are read from the shipped bundle, including while offline.
struct OpenSourceLicensesView: View {
    private struct Notice: Identifiable {
        let url: URL
        let title: String
        var id: String { url.path }
    }
    @State private var query = ""

    private var notices: [Notice] {
        guard let root = Bundle.main.resourceURL else { return [] }
        var result: [Notice] = []
        for folder in ["ThirdPartyLicenses", "WebTools"] {
            let directory = root.appendingPathComponent(folder, isDirectory: true)
            guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
            for case let url as URL in files {
                let name = url.lastPathComponent.lowercased()
                let relative = String(url.path.dropFirst(directory.path.count + 1))
                let isNotice = folder == "ThirdPartyLicenses" || name.contains("license") || name.hasPrefix("copying") || name.hasPrefix("notice") || name == "ofl.txt"
                    || (relative.contains("/licenses/") && url.pathExtension == "txt")
                guard isNotice, ["", "txt", "md"].contains(url.pathExtension.lowercased()),
                      (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                result.append(Notice(url: url, title: relative.replacingOccurrences(of: "--", with: " / ")))
            }
        }
        return result.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        List {
            Section {
                Text("NOMAD Apple includes open-source software. Each component retains its own copyright and license. Imported books, maps, courses and models have separate terms.")
                Link("Source code & dependency inventory", destination: URL(string: "https://github.com/maqalaqil/nomad-apple/blob/main/docs/LICENSING.md")!)
                Text("Opening the source link connects to GitHub in your browser.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Bundled notices") {
                ForEach(notices.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }) { notice in
                    NavigationLink(notice.title) {
                        ScrollView {
                            Text((try? String(contentsOf: notice.url, encoding: .utf8)) ?? "This notice could not be read. See the source inventory for its original text.")
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                        }.navigationTitle(notice.title)
                    }
                }
            }
        }
        .navigationTitle("Open-source licenses")
        .searchable(text: $query, prompt: "Find a component")
    }
}
