import SwiftUI
import Observation

/// Process-wide guard: a second scene must never activate a newly scheduled restore
/// against stores already opened in the first scene. Activation requires a cold launch.
@MainActor @Observable
private final class WorkspaceStartupState {
    static let shared = WorkspaceStartupState()
    private(set) var ready = false
    private(set) var running = false
    private(set) var error: String?
    var notice: String?
    var canCancelPending: Bool { !ready && !running && BackupRestoreCoordinator.hasPendingRestore() && !BackupRestoreCoordinator.hasRecovery() }
    func start() {
        guard !ready, !running else { return }
        running = true; error = nil
        Task {
            defer { running = false }
            do {
                let outcome = try await Task.detached(priority: .userInitiated) {
                    try BackupRestoreCoordinator.activatePendingRestore()
                }.value
                notice = outcome.message
                ready = true
            } catch { self.error = error.localizedDescription }
        }
    }
    func cancelInvalidPending() {
        guard canCancelPending else { return }
        running = true; error = nil
        Task {
            do {
                try await Task.detached(priority: .userInitiated) { try BackupRestoreCoordinator.cancelPending() }.value
                running = false
                start()
            } catch { running = false; self.error = error.localizedDescription }
        }
    }
}

struct WorkspaceStartupGate<Content: View>: View {
    @State private var startup = WorkspaceStartupState.shared
    @State private var confirmCancel = false
    @ViewBuilder let content: () -> Content
    var body: some View {
        Group {
            if startup.ready { content() }
            else {
                VStack(spacing: 20) {
                    Image(systemName: "externaldrive.badge.checkmark").font(.largeTitle)
                    Text(startup.running ? "Opening your workspace…" : "Workspace recovery needs attention").font(.title2)
                    if startup.running { ProgressView() }
                    if let error = startup.error {
                        Text(error).foregroundStyle(.orange).textSelection(.enabled)
                        Text("Saved data is preserved. The workspace will stay closed until recovery succeeds; the download queue is kept separately.")
                        Button("Retry recovery") { startup.start() }.buttonStyle(.borderedProminent)
                        if startup.canCancelPending {
                            Button("Cancel the pending restore", role: .destructive) { confirmCancel = true }
                        }
                    }
                }.padding(32).frame(maxWidth: 700)
            }
        }
        .task { startup.start() }
        .confirmationDialog("Cancel this pending restore?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Discard staged restore and open current workspace", role: .destructive) { startup.cancelInvalidPending() }
        } message: {
            Text("Activation has not started. This removes the pending plan and its private staging copy; your current workspace and original backup remain intact. An interrupted activation cannot be bypassed this way.")
        }
        .alert("Workspace recovery", isPresented: Binding(get: { startup.notice != nil }, set: { if !$0 { startup.notice = nil } })) {
            Button("Continue") { startup.notice = nil }
        } message: { Text(startup.notice ?? "") }
    }
}
