import SwiftUI
import Observation
import UniformTypeIdentifiers

private enum BackupPlatformInstructions {
    static var restart: String {
        #if os(macOS)
        "Quit NOMAD with Command-Q, then open it again. Closing its windows alone does not restart the app."
        #else
        "Close NOMAD completely using the app switcher, then reopen it."
        #endif
    }
    static var copy: String {
        #if os(macOS)
        "Copy the complete folder to another device or drive with Finder."
        #else
        "Copy the complete folder to another device or drive with Files."
        #endif
    }
}

@MainActor @Observable
private final class BackupViewModel {
    var selected = Set(BackupCatalog.components.map(\.id))
    var withContent = Set<String>()
    var restoreSelection = Set<String>()
    var review: BackupReview?
    var progress: BackupProgress?
    var lastExport: URL?
    var message: String?
    var error: String?
    var pending = false
    var recovery = false
    var recoveryPhase: String?
    var working = false
    @ObservationIgnored private var task: Task<Void, Never>?

    func refresh() {
        pending = BackupRestoreCoordinator.hasPendingRestore()
        recovery = BackupRestoreCoordinator.hasRecovery()
        do { recoveryPhase = try BackupRestoreCoordinator.recoveryPhase() }
        catch { recoveryPhase = nil; self.error = error.localizedDescription }
    }
    func export() {
        let choices = BackupCatalog.components.filter { selected.contains($0.id) }.map {
            BackupSelection(component: $0.id, includeContent: withContent.contains($0.id) && $0.hasOptionalContent)
        }
        execute({ progress in try BackupEngine().export(selections: choices, progress: progress) }) { output in
            self.lastExport = output
            self.message = "Backup saved. \(BackupPlatformInstructions.copy) This package is not encrypted."
        }
    }
    func inspect(_ url: URL) {
        execute({ _ in try BackupEngine().inspect(url) }) { value in
            self.review = value
            self.restoreSelection = Set(value.manifest.selections.map(\.component).filter { value.issues[$0] == nil })
        }
    }
    func scheduleRestore() {
        guard let review else { return }
        let source = review.directory, selected = restoreSelection
        execute({ progress in
            let engine = BackupEngine()
            let staged = try engine.stageSelected(source, selected: selected, progress: progress)
            do {
                try Task.checkCancellation()
                try BackupRestoreCoordinator.schedule(staged, selected: selected, engine: engine)
            } catch {
                try? BackupRestoreCoordinator.discard(staged)
                throw error
            }
            return true
        }) { _ in
            self.review = nil
            self.message = "Restore scheduled. \(BackupPlatformInstructions.restart) Selected records will be replaced before modules open. Until then, the current data remains active. Earlier files will be retained for rollback."
        }
    }
    func cancel() { task?.cancel() }
    func cancelPending() {
        do { try BackupRestoreCoordinator.cancelPending(); message = "Scheduled restore cancelled. Active data was not changed." }
        catch { self.error = error.localizedDescription }
        refresh()
    }
    func rollback() {
        do { try BackupRestoreCoordinator.requestRollback(); message = "Rollback scheduled. \(BackupPlatformInstructions.restart) Current files will also be preserved in recovery storage." }
        catch { self.error = error.localizedDescription }
        refresh()
    }
    func discardRecovery() {
        do { try BackupRestoreCoordinator.discardRecovery(); message = "Retained recovery files were removed. Current module data was not changed." }
        catch { self.error = error.localizedDescription }
        refresh()
    }
    private func execute<T: Sendable>(_ operation: @escaping @Sendable (@escaping @Sendable (BackupProgress) -> Void) throws -> T,
                                      completed: @escaping (T) -> Void) {
        guard !working else { return }
        working = true; progress = nil; error = nil; message = nil
        task = Task {
            defer { working = false; task = nil; refresh() }
            let worker = Task.detached(priority: .utility) {
                try operation { [weak self] value in Task { @MainActor in self?.progress = value } }
            }
            do {
                let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                completed(result)
            } catch {
                self.error = error is CancellationError ? "Operation cancelled. Existing app data was preserved." : error.localizedDescription
            }
        }
    }
}

struct BackupView: View {
    @State private var model = BackupViewModel()
    @State private var importer = false
    @State private var confirmRestore = false
    @State private var confirmRollback = false
    @State private var confirmDiscard = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        List {
            Section("Native data backup") {
                Text("Save selected app data as a versioned folder with file checksums. Backups contain private documents, conversations and settings in readable form. Store them securely; use Vault’s separate encrypted recovery for passwords.")
                Text("The download queue and its files are excluded. Backup and restore do not replace active transfers.").font(.footnote).foregroundStyle(.secondary)
            }
            if model.working {
                Section {
                    if let progress = model.progress {
                        ProgressView(value: Double(progress.completedBytes), total: Double(max(1, progress.totalBytes)))
                        Text(progress.message)
                        Text("\(bytes(progress.completedBytes)) of \(bytes(progress.totalBytes))").font(.caption)
                    } else { ProgressView("Preparing…") }
                    Button("Cancel operation", role: .cancel) { model.cancel() }
                }
            }
            if let message = model.message { Section { Text(message).textSelection(.enabled) } }
            if let error = model.error { Section { Text(error).foregroundStyle(.orange).textSelection(.enabled) } }
            if model.pending {
                Section("Restore scheduled") {
                    Text("\(BackupPlatformInstructions.restart) This activates the selected backup. Changes made before that restart are retained in recovery storage.")
                    Button("Cancel scheduled restore", role: .cancel) { model.cancelPending() }.disabled(model.working)
                }
            }
            if model.recovery {
                Section("Previous restore recovery") {
                    Text("Earlier files are retained until you explicitly remove them. A rollback also preserves the files it displaces.")
                    if model.recoveryPhase == "committed" {
                        Button("Restore the retained previous state") { confirmRollback = true }.disabled(model.working)
                    } else if model.recoveryPhase == "rolledBack" {
                        Text("Rollback completed. The displaced replacement files remain available in recovery storage.").font(.footnote)
                    } else {
                        Text("Restart the app to finish the scheduled recovery or cleanup before opening another restore.").font(.footnote)
                    }
                    if ["committed", "rolledBack", "discarding"].contains(model.recoveryPhase ?? "") {
                        Button("Remove retained recovery files", role: .destructive) { confirmDiscard = true }.disabled(model.working)
                    }
                }
            }
            Section("Include in export") {
                ForEach(BackupCatalog.components) { component in
                    VStack(alignment: .leading, spacing: 5) {
                        Toggle(component.title, isOn: selection(component.id, values: $model.selected))
                        Text(component.description).font(.caption).foregroundStyle(.secondary)
                        if component.hasOptionalContent, model.selected.contains(component.id) {
                            Toggle("Include large content files", isOn: selection(component.id, values: $model.withContent)).font(.subheadline)
                        }
                    }
                }
                Text("State-only library, course, media and map records require their matching content to exist when restored. Include content for a portable backup. Files absent from a backup are not deleted during restore.").font(.footnote)
                Button("Create backup folder", systemImage: "externaldrive.badge.plus") { model.export() }
                    .disabled(model.working || model.selected.isEmpty)
                if let url = model.lastExport { ShareLink("Share or save complete backup folder", item: url) }
            }.disabled(model.working)
            Section("Restore") {
                Button("Review a backup folder", systemImage: "folder.badge.gearshape") { importer = true }
                    .disabled(model.working || model.pending || model.recovery)
                Text("Review components first. Only selected files are copied into private staging and checked. Restoring replaces the selected saved records on the next cold launch, with previous files retained for rollback.").font(.footnote)
            }
            if let review = model.review {
                Section("Review selected backup") {
                    Text(review.manifest.createdAt, style: .date)
                    Text("Format \(review.manifest.formatVersion) · \(review.manifest.entries.filter { !$0.directory }.count) files · \(bytes(review.manifest.totalBytes))")
                    ForEach(review.manifest.selections, id: \.component) { item in
                        VStack(alignment: .leading) {
                            Toggle((try? BackupCatalog.component(item.component).title) ?? item.component,
                                   isOn: selection(item.component, values: $model.restoreSelection))
                                .disabled(review.issues[item.component] != nil || model.working)
                            if let issue = review.issues[item.component] { Text(issue).font(.caption).foregroundStyle(.orange) }
                        }
                    }
                    Text("This review checks metadata and required content. File checksums are validated while staging, before the restore is scheduled.").font(.caption)
                    Button("Validate and schedule selected restore", role: .destructive) { confirmRestore = true }
                        .disabled(model.working || model.restoreSelection.isEmpty || model.pending || model.recovery)
                    Button("Cancel review", role: .cancel) { model.review = nil }.disabled(model.working)
                }
            }
            Section("Explicit exclusions") {
                ForEach(BackupCatalog.exclusions, id: \.self) { Text($0).font(.footnote) }
            }
        }
        .navigationTitle("Backup and restore")
        .task { model.refresh() }
        .onDisappear { model.cancel() }
        .onChange(of: scenePhase) { _, phase in if phase == .background { model.cancel() } }
        .fileImporter(isPresented: $importer, allowedContentTypes: [.folder]) { result in
            do { model.inspect(try result.get()) } catch { model.error = error.localizedDescription }
        }
        .confirmationDialog("Replace selected saved records on next launch?", isPresented: $confirmRestore, titleVisibility: .visible) {
            Button("Stage and schedule restore", role: .destructive) { model.scheduleRestore() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Current records will be retained for rollback. Unselected modules, the download queue and Vault remain unchanged. \(BackupPlatformInstructions.restart)") }
        .confirmationDialog("Roll back the previous restore on next launch?", isPresented: $confirmRollback, titleVisibility: .visible) {
            Button("Schedule rollback", role: .destructive) { model.rollback() }
        } message: { Text("Current replacement files are preserved in recovery storage before the earlier versions return.") }
        .confirmationDialog("Permanently remove retained recovery copies?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Remove recovery files", role: .destructive) { model.discardRecovery() }
        } message: { Text("This removes the previous restore’s recovery copies, not the active module data. This cannot be undone.") }
    }
    private func selection(_ id: String, values: Binding<Set<String>>) -> Binding<Bool> {
        Binding(get: { values.wrappedValue.contains(id) }, set: { on in
            if on { values.wrappedValue.insert(id) } else { values.wrappedValue.remove(id) }
        })
    }
    private func bytes(_ count: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(min(count, UInt64(Int64.max))), countStyle: .file) }
}
