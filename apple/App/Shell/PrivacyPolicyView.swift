import SwiftUI

/// Bundled policy remains available when the device has no network connection.
struct PrivacyPolicyView: View {
    private var policy: String? {
        guard let url = Bundle.main.url(forResource: "PRIVACY_POLICY", withExtension: "md") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let policy {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(Array(policy.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, paragraph in
                            if paragraph.hasPrefix("## ") {
                                Text(String(paragraph.dropFirst(3))).font(.title3.bold())
                            } else if paragraph.hasPrefix("# ") {
                                Text(String(paragraph.dropFirst(2))).font(.title.bold())
                            } else {
                                Text(.init(paragraph))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("privacy.policy")
                    .textSelection(.enabled)
                } else {
                    ContentUnavailableView("Policy unavailable", systemImage: "doc.text.magnifyingglass", description: Text("The bundled privacy policy could not be read. You can open the public policy below while online."))
                }
                Link("View public privacy policy", destination: URL(string: "https://github.com/maqalaqil/nomad-apple/blob/main/docs/PRIVACY_POLICY.md")!)
                Text("Opening the public policy uses your browser and connects to GitHub.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding()
            .frame(maxWidth: 800)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Privacy & network use")
    }
}
