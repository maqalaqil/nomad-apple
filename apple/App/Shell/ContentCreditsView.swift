import SwiftUI

/// Credits remain readable offline; publisher links open only when explicitly selected.
struct ContentCreditsView: View {
    var body: some View {
        List {
            Section("Wikipedia archives") {
                Text("Wikipedia articles are written by their contributors. Text is generally available under Creative Commons Attribution-ShareAlike; check each article and archive for the applicable version and additional notices. Images and other media can have separate licenses or reuse restrictions. Keep the archive’s article credits, source references and license notices when sharing content.")
                Text("NOMAD downloads the selected Kiwix archive without modifying its contents. An archive’s availability does not give every item the same license.")
                Link("Wikimedia content terms (online)", destination: URL(string: "https://foundation.wikimedia.org/wiki/Policy:Terms_of_Use#7._Licensing_of_Content")!)
            }
            Section("Maps in the built-in catalog") {
                Text("© OpenStreetMap contributors. The worldwide Protomaps basemap and Crosstalk Solutions’ regional extracts are Open Database License (ODbL) Produced Works. Credit OpenStreetMap and retain the applicable data notices when sharing or adapting these maps.")
                Text("OpenStreetMap copyright and license: https://www.openstreetmap.org/copyright")
                Link("OpenStreetMap copyright (online)", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                Link("Open Database License (online)", destination: URL(string: "https://opendatacommons.org/licenses/odbl/1-0/")!)
                Text("Other imported maps retain their own attribution and terms. The map displays attribution from each archive; these catalog credits do not assign a license to an unknown archive.")
            }
            Section("Model in the built-in catalog") {
                Text("Qwen2.5-0.5B-Instruct-GGUF · Copyright 2024 Alibaba Cloud. Apache License 2.0. The catalog uses publisher revision 9217f5db79a29953eb74d5343926648285ec7e67. Other models have separate terms.")
                NavigationLink("Read Qwen license offline") {
                    ScrollView {
                        Text(modelLicense).font(.footnote).textSelection(.enabled).padding()
                    }
                    .navigationTitle("Qwen license")
                }
                Link("Qwen publisher page (online)", destination: URL(string: "https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF")!)
            }
            Section("Your library and courses") {
                Text("Imported books, media, courses and reference datasets retain their own terms. Course details show the author and license supplied in the channel metadata. Importing a file does not transfer its copyright. Preserve credits and check its license before redistribution.")
                Text("The original NOMAD sample library is dedicated under CC0 1.0. Bundled software licenses are listed separately under Offline help → Open-source licenses.")
                Text("NOMAD Apple is independent and is not endorsed by the content providers or Crosstalk Solutions. Online links open your browser; the credits and bundled model license remain available offline.")
            }
        }
        .navigationTitle("Content credits")
        .textSelection(.enabled)
        .accessibilityIdentifier("content.credits")
    }

    private var modelLicense: String {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("Catalogs/Qwen-LICENSE.txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "The bundled license could not be read. See the publisher’s LICENSE file at https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF."
        }
        return text
    }
}
