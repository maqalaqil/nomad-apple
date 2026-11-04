import SwiftUI
import Security
import LocalAuthentication

// BEGIN VAULT_UNLOCK_GATE: kept independent of UI/authentication for lifecycle tests.
struct VaultUnlockGate {
    private var attempt: UUID?
    mutating func begin() -> UUID { let id = UUID(); attempt = id; return id }
    mutating func invalidate() { attempt = nil }
    func accepts(_ id: UUID) -> Bool { attempt == id }
}
// END VAULT_UNLOCK_GATE

private enum VaultKeychain {
    static let service = "org.projectnomad.ipad.local-vault"
    static func query(context: LAContext) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "vault-v1", kSecUseAuthenticationContext as String: context]
    }
    static func load(context: LAContext) throws -> [VaultEntry] {
        var q = query(context: context)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let data = result as? Data else { throw keychainError(status) }
        return try JSONDecoder().decode([VaultEntry].self, from: data)
    }
    static func save(_ entries: [VaultEntry], context: LAContext) throws {
        try VaultBackupCodec.validateExportable(entries)
        let data = try JSONEncoder().encode(entries)
        let q = query(context: context)
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw keychainError(status) }
        var creationError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .userPresence, &creationError) else {
            throw creationError?.takeRetainedValue() as Error? ?? keychainError(errSecParam)
        }
        var new = q
        new[kSecAttrAccessControl as String] = access
        new[kSecValueData as String] = data
        let added = SecItemAdd(new as CFDictionary, nil)
        guard added == errSecSuccess else { throw keychainError(added) }
    }
    static func keychainError(_ status: OSStatus) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: SecCopyErrorMessageString(status, nil) as String? ?? "The secure vault is unavailable."])
    }
}

struct VaultView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var context: LAContext?
    @State private var entries: [VaultEntry] = []
    @State private var unlocked = false
    @State private var busy = false
    @State private var error: String?
    @State private var editing: VaultEntry?
    @State private var deleting: VaultEntry?
    @State private var search = ""
    @State private var unlockTask: Task<Void, Never>?
    @State private var unlockGate = VaultUnlockGate()
    @State private var authenticatedAttempt: UUID?
    @State private var visible = false
    @State private var recoveryPresented = false

    var body: some View {
        Group {
            if unlocked {
                List {
                    Section {
                        Text("Credentials are protected by this iPad’s Keychain and passcode. Use Encrypted Backup to keep a recovery copy protected by a separate passphrase. The vault does not sync or provide system AutoFill.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(entries.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.username.localizedCaseInsensitiveContains(search) }) { entry in
                        Button { editing = entry } label: {
                            HStack {
                                Image(systemName: "key.fill").foregroundStyle(NomadTheme.accent)
                                VStack(alignment: .leading) { Text(entry.title).foregroundStyle(.primary); Text(entry.username).font(.caption).foregroundStyle(.secondary) }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.secondary)
                            }
                        }.swipeActions { Button("Delete", role: .destructive) { deleting = entry } }
                    }
                }.searchable(text: $search)
                    .overlay { if entries.isEmpty { ContentUnavailableView("Your vault is empty", systemImage: "key", description: Text("Use Add to save a credential on this iPad.")) } }
                    .toolbar {
                        Button("Lock", systemImage: "lock.fill") { lock() }
                        Button("Encrypted Backup", systemImage: "externaldrive.badge.person.crop") { recoveryPresented = true }
                        Button("Add", systemImage: "plus") { editing = VaultEntry() }
                    }
            } else {
                ContentUnavailableView {
                    Label("Your private vault", systemImage: "lock.shield")
                } description: {
                    Text("Unlock with Face ID, Touch ID, or your iPad passcode. Credentials stay in this device’s protected Keychain.")
                } actions: {
                    Button(busy ? "Unlocking…" : "Unlock vault", systemImage: "lock.open") { unlock() }
                        .buttonStyle(.borderedProminent).disabled(busy)
                }
            }
        }
        .opacity(scenePhase == .active ? 1 : 0)
        .overlay { if scenePhase != .active { VaultPrivacyCover() } }
        .privacySensitive()
        .sheet(item: $editing) { entry in VaultEditor(entry: entry) { save($0) } }
        .sheet(isPresented: $recoveryPresented) {
            VaultRecoveryView(entries: entries, isUnlocked: { unlocked && visible && scenePhase == .active }, importEntries: importBackup)
        }
        .confirmationDialog("Delete this credential?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete credential", role: .destructive) {
                guard let deleting, let context, unlocked, scenePhase == .active else { return }
                do { let updated = entries.filter { $0.id != deleting.id }; try VaultKeychain.save(updated, context: context); entries = updated }
                catch { self.error = error.localizedDescription }
                self.deleting = nil
            }
        }
        .alert("Vault", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
        .onAppear { visible = true }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background || (phase != .active && unlocked) { lock() }
            else if phase == .active, let authenticatedAttempt { finishUnlock(authenticatedAttempt) }
        }
        .onDisappear { visible = false; lock() }
    }
    private func unlock() {
        guard visible, scenePhase == .active, !busy, !unlocked else { return }
        let attempt = unlockGate.begin()
        let authentication = LAContext()
        context = authentication // Lock can invalidate an in-flight authentication too.
        authenticatedAttempt = nil
        error = nil
        busy = true
        unlockTask = Task { @MainActor in
            do {
                let accepted = try await authentication.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock your offline NOMAD password vault")
                guard !Task.isCancelled, unlockGate.accepts(attempt), visible else { return }
                guard accepted else { lock(); return }
                authenticatedAttempt = attempt
                // Face ID may finish while its system sheet is still making the app inactive.
                // The active-scene callback completes this attempt after the sheet closes.
                finishUnlock(attempt)
            } catch {
                guard unlockGate.accepts(attempt) else { return }
                let cancelled = Task.isCancelled
                lock()
                if !cancelled { self.error = error.localizedDescription }
            }
        }
    }
    private func finishUnlock(_ attempt: UUID) {
        guard unlockGate.accepts(attempt), visible, scenePhase == .active, let context else { return }
        do {
            let saved = try VaultKeychain.load(context: context)
            guard Set(saved.map(\.id)).count == saved.count else { throw CocoaError(.fileReadCorruptFile) }
            entries = saved
            unlocked = true
            busy = false
            authenticatedAttempt = nil
            unlockGate.invalidate()
            unlockTask = nil
        } catch { lock(); self.error = error.localizedDescription }
    }
    private func save(_ entry: VaultEntry) {
        guard let context, unlocked, visible, scenePhase == .active else { return }
        var updated = entries
        if let i = updated.firstIndex(where: { $0.id == entry.id }) { updated[i] = entry } else { updated.append(entry) }
        do { try VaultKeychain.save(updated, context: context); entries = updated; editing = nil }
        catch { self.error = error.localizedDescription }
    }
    private func importBackup(_ imported: [VaultEntry]) throws {
        guard let context, unlocked, visible, scenePhase == .active else { throw VaultFailure.message("Unlock the vault again before importing.") }
        let result = try VaultBackupCodec.merge(existing: entries, imported: imported)
        // A single Keychain update happens only after all authentication,
        // decryption, validation, and user review have succeeded.
        try VaultKeychain.save(result.entries, context: context)
        entries = result.entries
    }
    private func lock() {
        unlockGate.invalidate()
        unlockTask?.cancel(); unlockTask = nil
        authenticatedAttempt = nil
        context?.invalidate(); context = nil
        editing = nil; deleting = nil; recoveryPresented = false; entries = []; search = ""
        unlocked = false; busy = false
    }
}

struct VaultPrivacyCover: View {
    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            Label("NOMAD Vault", systemImage: "lock.shield").font(.title2)
        }.accessibilityElement(children: .ignore).accessibilityLabel("Vault hidden")
    }
}

private struct VaultEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State var entry: VaultEntry
    let save: (VaultEntry) -> Void
    @State private var reveal = false
    @State private var generatorPresented = false
    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $entry.title)
                TextField("Username", text: $entry.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                HStack {
                    if reveal { TextField("Password", text: $entry.password).textInputAutocapitalization(.never).autocorrectionDisabled() }
                    else { SecureField("Password", text: $entry.password) }
                    Button { reveal.toggle() } label: { Image(systemName: reveal ? "eye.slash" : "eye") }.accessibilityLabel(reveal ? "Hide password" : "Show password")
                    Button("Copy") { UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: entry.password]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(45)]) }
                }
                Button("Generate a password", systemImage: "dice") { generatorPresented = true }
                TextField("Website", text: $entry.website).textInputAutocapitalization(.never).keyboardType(.URL)
                TextField("Notes", text: $entry.notes, axis: .vertical).lineLimit(3...8)
            }.navigationTitle("Credential")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Save") { save(entry) }.disabled(entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                }
        }
        .opacity(scenePhase == .active ? 1 : 0)
        .overlay { if scenePhase != .active { VaultPrivacyCover() } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { reveal = false } }
        .privacySensitive()
        .sheet(isPresented: $generatorPresented) {
            VaultPasswordGeneratorView { password in entry.password = password; reveal = false; generatorPresented = false }
        }
    }
}
