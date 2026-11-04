import SwiftUI

@main
struct NomadPadApp: App {
    @UIApplicationDelegateAdaptor(NomadAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            WorkspaceStartupGate { appContent }
                .tint(NomadTheme.accent)
                .preferredColorScheme(.dark)
        }
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
    #if DEBUG
    @State private var previousIdleSetting: Bool?
    #endif
    var body: some View {
        NomadShell(library: library)
            .task { _ = DownloadStore.shared }
            #if DEBUG
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
