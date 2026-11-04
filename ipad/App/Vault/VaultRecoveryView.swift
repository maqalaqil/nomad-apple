import SwiftUI
import UniformTypeIdentifiers

private struct VaultEncryptedDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents, data.count <= VaultBackupCodec.maximumFileBytes else { throw VaultFailure.message("Invalid encrypted backup.") }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct VaultRecoveryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let entries: [VaultEntry]
    let isUnlocked: () -> Bool
    let importEntries: ([VaultEntry]) throws -> Void
    @State private var mode = 0
    @State private var passphrase = ""
    @State private var confirmation = ""
    @State private var acknowledged = false
    @State private var encryptedInput: Data?
    @State private var inputName = ""
    @State private var encryptedOutput: VaultEncryptedDocument?
    @State private var importing = false
    @State private var exporting = false
    @State private var busy = false
    @State private var error: String?
    @State private var status: String?
    @State private var task: Task<Void, Never>?
    @State private var gate = VaultUnlockGate()
    @State private var reviewed: [VaultEntry]?
    @State private var added = 0
    @State private var kept = 0
    @State private var confirmingImport = false

    var body: some View {
        NavigationStack {
            Form {
                Picker("Recovery", selection: $mode) { Text("Export").tag(0); Text("Import").tag(1) }.pickerStyle(.segmented).disabled(busy)
                Section {
                    Text("Backups are encrypted with AES-256-GCM and a separate passphrase. The passphrase is not stored with the backup and cannot be recovered by the app.")
                    Text("Use at least 20 characters, preferably five or more randomly chosen words. Store the passphrase separately from the backup.")
                }.font(.footnote).foregroundStyle(.secondary)
                if mode == 0 {
                    Section("Export \(entries.count) credentials") {
                        SecureField("Backup passphrase", text: $passphrase).textContentType(.newPassword)
                        SecureField("Confirm passphrase", text: $confirmation).textContentType(.newPassword)
                        Toggle("I have a separate, safe copy of this passphrase", isOn: $acknowledged)
                        Button("Create encrypted backup", systemImage: "lock.doc") { encrypt() }
                            .disabled(busy || !passphraseValid || passphrase != confirmation || !acknowledged)
                    }
                } else {
                    Section("Encrypted backup") {
                        Button("Choose backup from Files", systemImage: "doc.badge.arrow.up") { importing = true }.disabled(busy)
                        if !inputName.isEmpty { Text(inputName).font(.caption) }
                        SecureField("Backup passphrase", text: $passphrase).textContentType(.password)
                        Button("Decrypt and review", systemImage: "lock.open") { decrypt() }.disabled(busy || encryptedInput == nil || !passphraseValid)
                    }
                    if let reviewed {
                        Section("Review before importing") {
                            Text("Add \(added) new credentials. Keep \(kept) existing credentials whose IDs are already present. Existing credentials are never overwritten.")
                            ForEach(Array(reviewed.prefix(20))) { entry in Text(entry.title.isEmpty ? "Untitled credential" : entry.title) }
                            if reviewed.count > 20 { Text("And \(reviewed.count - 20) more…").foregroundStyle(.secondary) }
                            Button("Import \(added) new credentials") { confirmingImport = true }.disabled(added == 0 || busy)
                        }
                    }
                }
                if busy { HStack { ProgressView(); Text("Protecting or verifying backup…") } }
                if let error { Text(error).foregroundStyle(.red) }
                if let status { Text(status).foregroundStyle(.secondary) }
                Section {
                    Text("The version 1 format uses PBKDF2-HMAC-SHA256 with 600,000 iterations, a fresh 32-byte salt, and authenticated encryption. Backups are limited to 4 MB and 5,000 credentials. Files contains only encrypted backup data.")
                }.font(.footnote).foregroundStyle(.secondary)
            }
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .navigationTitle("Encrypted Vault Backup")
            .toolbar { Button("Done") { clear(); dismiss() } }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
            guard active else { return }
            do {
                let url = try result.get(), access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                encryptedInput = try VaultBackupCodec.readEncryptedFile(url)
                inputName = url.lastPathComponent; reviewed = nil; error = nil; status = nil
            } catch { encryptedInput = nil; reviewed = nil; self.error = error.localizedDescription }
        }
        .fileExporter(isPresented: $exporting, document: encryptedOutput, contentType: .data, defaultFilename: "NOMAD-Vault-Encrypted.nomadvault") { result in
            defer { encryptedOutput = nil }
            guard active else { return }
            do { _ = try result.get(); status = "Encrypted backup saved. Keep the passphrase separately." }
            catch { self.error = error.localizedDescription }
        }
        .confirmationDialog("Import verified backup?", isPresented: $confirmingImport, titleVisibility: .visible) {
            Button("Add \(added) credentials") { commitImport() }
        } message: { Text("The \(entries.count) credentials already in this vault will be kept. \(kept) matching IDs will be skipped.") }
        .onChange(of: mode) { _, _ in clear() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { clear(); dismiss() } }
        .onDisappear(perform: clear)
        .opacity(scenePhase == .active ? 1 : 0)
        .overlay { if scenePhase != .active { VaultPrivacyCover() } }
        .privacySensitive()
    }

    private var active: Bool { scenePhase == .active && isUnlocked() }
    private var passphraseValid: Bool { (try? VaultBackupCodec.validatePassphrase(passphrase)) != nil }
    private func accepts(_ id: UUID) -> Bool { !Task.isCancelled && gate.accepts(id) && active }

    private func encrypt() {
        guard active, !busy, passphrase == confirmation, acknowledged else { return }
        let id = gate.begin(), password = passphrase, snapshot = entries
        busy = true; error = nil; status = nil
        task = Task { @MainActor in
            let worker = Task.detached(priority: .userInitiated) { try VaultBackupCodec.encrypt(snapshot, passphrase: password) }
            do {
                let data = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard accepts(id) else { return }
                encryptedOutput = VaultEncryptedDocument(data: data)
                passphrase = ""; confirmation = ""; acknowledged = false
                busy = false; gate.invalidate(); task = nil; exporting = true
            } catch {
                guard accepts(id) else { return }
                self.error = error.localizedDescription; busy = false; gate.invalidate(); task = nil
            }
        }
    }

    private func decrypt() {
        guard active, !busy, let input = encryptedInput else { return }
        let id = gate.begin(), password = passphrase
        busy = true; reviewed = nil; error = nil; status = nil
        task = Task { @MainActor in
            let worker = Task.detached(priority: .userInitiated) { try VaultBackupCodec.decrypt(input, passphrase: password) }
            do {
                let imported = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard accepts(id) else { return }
                let plan = try VaultBackupCodec.merge(existing: entries, imported: imported)
                reviewed = imported; added = plan.added; kept = plan.kept
                if added == 0 { status = "Every credential ID is already present; nothing needs to be imported." }
                passphrase = ""; busy = false; gate.invalidate(); task = nil
            } catch {
                guard accepts(id) else { return }
                self.error = error.localizedDescription; passphrase = ""; busy = false; gate.invalidate(); task = nil
            }
        }
    }

    private func commitImport() {
        guard active, let reviewed else { return }
        do { try importEntries(reviewed); clear(); dismiss() }
        catch { self.error = error.localizedDescription }
    }

    private func clear() {
        gate.invalidate(); task?.cancel(); task = nil
        passphrase = ""; confirmation = ""; acknowledged = false
        encryptedInput = nil; encryptedOutput = nil; reviewed = nil; inputName = ""
        busy = false; error = nil; status = nil; confirmingImport = false
    }
}
