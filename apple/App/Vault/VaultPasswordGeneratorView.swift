import SwiftUI

struct VaultPasswordGeneratorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let usePassword: (String) -> Void
    @State private var options = VaultPasswordOptions()
    @State private var password = ""
    @State private var reveal = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Options") {
                    Stepper("Length: \(options.length)", value: $options.length, in: 12...128)
                    Toggle("Uppercase letters", isOn: $options.uppercase)
                    Toggle("Lowercase letters", isOn: $options.lowercase)
                    Toggle("Digits", isOn: $options.digits)
                    Toggle("Symbols", isOn: $options.symbols)
                    Toggle("Exclude ambiguous characters", isOn: $options.excludeAmbiguous)
                    Button("Generate new password", systemImage: "arrow.clockwise", action: generate).disabled(options.groups.isEmpty)
                }
                Section("Generated password") {
                    if password.isEmpty { Text("Choose options and generate a password.").foregroundStyle(.secondary) }
                    else {
                        Text(reveal ? password : String(repeating: "•", count: min(password.count, 32)))
                            .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        Toggle("Show password", isOn: $reveal)
                        Button("Copy for 45 seconds") {
                            guard scenePhase == .active else { return }
                            VaultClipboard.copy(password)
                        }
                        Button("Use this password") { guard scenePhase == .active else { return }; usePassword(password); clear() }
                    }
                }
                Text(VaultClipboard.explanation).font(.caption).foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.red) }
                Text("Uses the system cryptographic random generator. Every selected character group is included. Changing options takes effect when you generate again.")
                    .font(.footnote).foregroundStyle(.secondary)
            }.navigationTitle("Password Generator")
                .toolbar { Button("Cancel") { clear(); dismiss() } }
        }
        .onAppear(perform: generate)
        .onDisappear(perform: clear)
        .opacity(scenePhase == .active ? 1 : 0)
        .overlay { if scenePhase != .active { VaultPrivacyCover() } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { clear(); dismiss() } }
        .privacySensitive()
    }

    private func generate() {
        guard scenePhase == .active else { return }
        do { password = try options.generate(); error = nil; reveal = false }
        catch { self.error = error.localizedDescription; password = "" }
    }
    private func clear() { password = ""; reveal = false }
}
