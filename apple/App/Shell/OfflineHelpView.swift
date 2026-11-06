import SwiftUI

struct OfflineHelpView: View {
    var body: some View {
        List {
            Section("Prepare your content") {
                Text("Keep Wi-Fi connected while Downloads acquires and verifies archives. When a file is ready, choose Add to library or Add to offline maps. An unfinished download cannot be opened offline. Imports from external Files locations need room for a local copy.")
                Text("Wikipedia editions include the language and image coverage shown in their catalog. The worldwide map is a street basemap; it does not include satellite imagery, every possible detail level, or turn-by-turn routing.")
            }
            Section("Ask your library") {
                Text("Import PDF or text documents, choose enabled sources in Knowledge Collections, then build the semantic index if you want semantic retrieval. ZIM and EPUB reading is separate from this text index.")
                Text("Apple’s assistant requires a prepared Apple Intelligence model. Local AI Models uses an imported GGUF model. Load a small model first. Each engine has its own saved conversations, settings and JSON exports. Library answers show the passages supplied to the model; always check those passages.")
            }
            Section("Read, learn and translate") {
                Text("Open ZIM and EPUB files from the library. Education accepts supported Kolibri channel exports with their matching content, or individual lessons. Unsupported exercises are identified in the reader.")
                Text("Prepare translation language packs while online. Language availability depends on Apple’s models. Keep the original text available when evaluating a translation.")
            }
            Section("Protect your records") {
                Text("Use backup and restore for native workspace records, and export the Vault’s separate encrypted recovery file. Keep a copy outside the device. Export web-editor documents to Files before backing up; unsaved browser drafts are not included.")
                Text("Removing a catalog entry or imported file does not erase its external source. Removing a completed download can leave a shared library or map copy intact. Use each module’s confirmation screen to check what is being removed.")
            }
            Section("When something stops") {
                Text("A download may pause because Wi-Fi or free storage is unavailable. Resume it from Downloads. Some servers require restarting a transfer. Keep the queue instead of reinstalling the app: reinstalling can erase local data.")
                Text("If a saved manifest is unreadable, the app preserves it and disables changes in that module. Restore a validated backup or recover the original file before replacing it. A model that runs out of working memory may need a smaller file or shorter conversation context.")
            }
            Section("Check offline operation") {
                Text("After preparation, test every needed module with Airplane Mode enabled and Wi-Fi off, then close and reopen the app. A successful online test does not prove network isolation. Radio messaging additionally requires compatible external hardware.")
                Text("A free Apple ID development installation expires and needs renewal through Xcode. The installed development build is not a permanent offline distribution. Preserve backups before changing installation methods.")
            }
            Section("About this build") {
                Text("NOMAD Apple provides native workflows and bundled local tools. Feature coverage and physical-device validation remain in progress. Linux containers, always-running servers, gated content entitlements, and unsupported radio protocols do not become available simply by opening a module.")
                NavigationLink("Privacy & network use") { PrivacyPolicyView() }
            }
        }
        .navigationTitle("Offline help")
        .textSelection(.enabled)
    }
}
