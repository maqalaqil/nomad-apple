import SwiftUI

@main
struct NomadAppleApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(NomadAppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        #if os(macOS)
        // Stores share one on-disk workspace; independent windows must not race saves.
        Window("NOMAD Apple", id: "workspace") { workspaceRoot }
        #else
        WindowGroup {
            workspaceRoot
        }
        #endif
    }

    private var workspaceRoot: some View {
        WorkspaceStartupGate { appContent }
            .tint(NomadTheme.accent)
            .preferredColorScheme(.dark)
            #if os(macOS)
            .frame(minWidth: 700, minHeight: 500)
            #endif
    }

    @ViewBuilder private var appContent: some View {
        #if DEBUG
        if CommandLine.arguments.contains("--device-validation") {
            DeviceValidationView()
        } else if CommandLine.arguments.contains("--prepare-requested-content") {
            ContentPreparationView()
        } else {
            NomadWorkspace()
        }
        #else
        NomadWorkspace()
        #endif
    }
}

private struct NomadWorkspace: View {
    @State private var library = LibraryStore()
    #if DEBUG && os(iOS)
    @State private var previousIdleSetting: Bool?
    #endif
    var body: some View {
        NomadShell(library: library)
            .task { _ = DownloadStore.shared }
            #if DEBUG && os(iOS)
            .onAppear {
                // Explicit connected-device preparation only; normal launches retain auto-lock.
                if CommandLine.arguments.contains("--keep-awake-for-preparation"), previousIdleSetting == nil {
                    previousIdleSetting = UIApplication.shared.isIdleTimerDisabled
                    UIApplication.shared.isIdleTimerDisabled = true
                }
            }
            .onDisappear {
                if let previousIdleSetting { UIApplication.shared.isIdleTimerDisabled = previousIdleSetting }
                previousIdleSetting = nil
            }
            #endif
    }
}
