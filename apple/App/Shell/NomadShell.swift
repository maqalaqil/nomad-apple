import SwiftUI
import FoundationModels

struct NomadShell: View {
    @Bindable var library: LibraryStore
    @State private var selected: NomadModule? = {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--module"), arguments.indices.contains(index + 1),
           let module = NomadModule(rawValue: arguments[index + 1]) { return module }
        #endif
        return .home
    }()
    @State private var preferredColumn: NavigationSplitViewColumn = .detail
    private let groups = ["Knowledge", "Create & organize", "Everyday essentials", "Manage"]

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $preferredColumn) {
            List(selection: $selected) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("NOMAD", systemImage: "mountain.2.fill")
                        .font(.system(size: 29, weight: .black, design: .rounded))
                        .foregroundStyle(NomadTheme.accent)
                    Text("KNOWLEDGE, WITH YOU.").font(.system(size: 9, weight: .bold)).tracking(2.2)
                        .foregroundStyle(NomadTheme.muted)
                }
                .padding(.vertical, 24).listRowBackground(Color.clear)
                NavigationLink(value: NomadModule.home) {
                    Label(NomadModule.home.title, systemImage: NomadModule.home.symbol)
                }
                ForEach(groups, id: \.self) { group in
                    Section(group) {
                        ForEach(NomadModule.allCases.filter { $0.group == group }) { module in
                            NavigationLink(value: module) { Label(module.title, systemImage: module.symbol) }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(NomadTheme.background)
            .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 310)
        } detail: {
            NavigationStack {
                content(for: selected ?? .home)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(NomadTheme.background)
                    .navigationTitle((selected ?? .home).title)
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
        .onChange(of: selected) { _, value in if value != nil { preferredColumn = .detail } }
    }

    @ViewBuilder private func content(for module: NomadModule) -> some View {
        switch module {
        case .home: DashboardView(library: library, selection: $selected)
        case .library: LibraryView(store: library)
        case .books: BooksLibraryView(store: library)
        case .files: FileWorkspaceView(library: library)
        case .assistant: AssistantView(library: library)
        case .models: GGUFModelView(library: library)
        case .knowledge: SemanticCollectionsView(library: library)
        case .notes: NotesView()
        case .tools: ToolsView()
        case .itTools: ITToolsView()
        case .pdf: PDFToolsView()
        case .translation: TranslationView()
        case .inventory: InventoryView()
        case .media: MediaLibraryView()
        case .sketch: SketchbookView()
        case .whiteboard: ExcalidrawView()
        case .vault: VaultView()
        case .education: EducationWorkspaceView()
        case .maps: MapWorkspaceView()
        case .depot: DepotView(library: library, selection: $selected)
        case .downloads: DownloadsView(library: library)
        case .setup: OfflinePreparationView(selection: $selected)
        case .benchmarks: BenchmarksView()
        case .settings: ReadinessView(library: library)
        case .reference: MedicalReferenceView()
        case .mesh: IntegrationView(module: module)
        }
    }
}

private struct EducationWorkspaceView: View {
    var body: some View {
        List {
            NavigationLink { CourseLibraryView() } label: { Label("Kolibri courses & learners", systemImage: "graduationcap.fill") }
            NavigationLink { EducationView() } label: { Label("Individual lesson files", systemImage: "doc.on.doc") }
            Text("Import exported Kolibri channels with their content files, or organize individual PDF, video, audio, and text lessons. Unsupported exercise formats are identified in the course reader.")
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }
}

private struct MapWorkspaceView: View {
    var body: some View {
        List {
            NavigationLink { PMTilesView() } label: {
                Label("NOMAD vector maps · PMTiles", systemImage: "map.fill")
            }
            NavigationLink { OfflinePlacesView() } label: {
                Label("Raster maps · MBTiles", systemImage: "square.3.layers.3d")
            }
            Text("Import your maps before going offline. Vector maps use NOMAD’s bundled local style, fonts, and sprites. Raster maps include their own images. Each reader reports unsupported archive formats.")
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }
}

struct DashboardView: View {
    @Bindable var library: LibraryStore
    @Binding var selection: NomadModule?
    @State private var preferences = DashboardPreferences()
    @State private var customizing = false
    @Environment(\.openURL) private var openURL
    private var featured: [NomadModule] { preferences.configuration.favorites.compactMap(NomadModule.init(rawValue:)) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 32) {
                        heroCopy
                        Image(systemName: "mountain.2.circle.fill")
                            .font(.system(size: 88)).foregroundStyle(NomadTheme.accent.opacity(0.8))
                            .accessibilityHidden(true)
                    }.fixedSize(horizontal: true, vertical: false)
                    heroCopy
                }
                .padding(30).frame(maxWidth: .infinity, alignment: .leading)
                .background(LinearGradient(colors: [NomadTheme.panel, NomadTheme.background], startPoint: .topLeading, endPoint: .bottomTrailing))
                .clipShape(RoundedRectangle(cornerRadius: 24))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                    DashboardStat(value: "\(library.documents.count)", label: "LOCAL DOCUMENTS", symbol: "doc.on.doc")
                    DashboardStat(value: ByteCountFormatter.string(fromByteCount: library.documents.reduce(0) { $0 + Int64($1.byteCount) }, countStyle: .file), label: "LIBRARY FILES ONLY", symbol: "internaldrive")
                    Button { selection = .setup } label: {
                        DashboardStat(value: "Check on device", label: "OFFLINE PREPARATION", symbol: "checklist")
                    }.buttonStyle(.plain)
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("Your workspace").font(.title2.bold())
                    HStack {
                        Button("Customize", systemImage: "slider.horizontal.3") { customizing = true }.disabled(!preferences.writable)
                        Spacer()
                        Button("All modules", systemImage: "arrow.right") { selection = .depot }
                    }
                }
                if let error = preferences.error { Text(error).foregroundStyle(.orange).font(.caption) }
                if !preferences.configuration.links.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Your links").font(.title2.bold())
                        Text("Opens in your browser · connectivity may be required").font(.caption).foregroundStyle(.secondary)
                        ForEach(preferences.configuration.links) { link in
                            Button { openURL(link.url) } label: {
                                HStack { Text(link.title); Spacer(); Image(systemName: "arrow.up.right.square") }
                            }.buttonStyle(.bordered)
                        }
                    }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 16)], spacing: 16) {
                    ForEach(featured) { module in
                        Button { selection = module } label: { ModuleCard(module: module) }
                            .buttonStyle(.plain)
                    }
                }
                if featured.isEmpty {
                    Text("Choose favorite modules with Customize, or open All modules.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    Image(systemName: "arrow.down.circle").font(.title2).foregroundStyle(NomadTheme.accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Start with something worth keeping.").font(.headline)
                        Text("Import supported documents to read and search offline. AI questions also require a prepared on-device model and indexed text.").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Open library") { selection = .library }.buttonStyle(.bordered)
                }.padding(22).background(NomadTheme.panel, in: RoundedRectangle(cornerRadius: 18))
                Button("Prepare for offline use", systemImage: "checklist") { selection = .setup }
                    .buttonStyle(.bordered).frame(maxWidth: .infinity, alignment: .leading)
            }.padding(28).frame(maxWidth: 1200)
                .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $customizing) { DashboardPreferencesView(store: preferences) }
    }

    private var heroCopy: some View {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("YOUR PERSONAL KNOWLEDGE STATION")
                            .font(.system(size: 10, weight: .bold)).tracking(2)
                            .foregroundStyle(NomadTheme.accent)
                        Text("A world of knowledge.\nAlways within reach.")
                            .font(.system(size: 39, weight: .semibold, design: .rounded))
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Build your library. Keep your tools close. Take it all with you.")
                            .foregroundStyle(.secondary).font(.subheadline)
                    }
    }
}

struct DashboardStat: View {
    let value: String
    let label: String
    let symbol: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Image(systemName: symbol).foregroundStyle(NomadTheme.muted); Spacer(); Text(label).font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(.secondary) }
            Text(value).font(.title2.bold())
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(NomadTheme.panel.opacity(0.65), in: RoundedRectangle(cornerRadius: 16))
    }
}

struct ModuleCard: View {
    let module: NomadModule
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Image(systemName: module.symbol).font(.title2).foregroundStyle(NomadTheme.accent)
                    .frame(width: 48, height: 48).background(NomadTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 13))
                Spacer()
                Image(systemName: "arrow.up.right").foregroundStyle(NomadTheme.muted)
            }
            Text(module.title).font(.headline)
            if module.needsIntegration {
                Label("Unavailable in this build", systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.orange)
            }
            Text(module.summary).font(.subheadline).foregroundStyle(.secondary).frame(minHeight: 38, alignment: .topLeading)
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            .background(NomadTheme.panel, in: RoundedRectangle(cornerRadius: 20))
    }
}

struct DepotView: View {
    @Bindable var library: LibraryStore
    @Binding var selection: NomadModule?
    @State private var downloads = DownloadStore.shared
    @State private var modelStore = GGUFModelStore.shared
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Choose your tools and content.").font(.largeTitle.bold())
                Text("Open a module for its supported formats and setup steps. Readers need imported content; AI and translation need prepared models. Unavailable integrations are marked below.")
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180))]) {
                    NavigationLink { CatalogDownloadsView() } label: { Label("Get content", systemImage: "arrow.down.circle") }
                    NavigationLink { OPDSCatalogsView() } label: { Label("Custom catalogs", systemImage: "books.vertical") }
                    NavigationLink { StorageAuditView() } label: { Label("Storage report", systemImage: "internaldrive") }
                }.buttonStyle(.bordered)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Installed content").font(.headline)
                    Text("\(library.documents.count) library documents · \(modelStore.models.count) GGUF models · \(downloads.items.filter { $0.state == .ready }.count) completed downloads")
                    Text("\(downloads.items.filter { [.queued, .downloading, .verifying].contains($0.state) }.count) queued or active downloads · \(downloads.items.filter { $0.state == .paused }.count) paused")
                    if let error = downloads.error { Text(error).foregroundStyle(.orange) }
                    if let error = library.lastError { Text(error).foregroundStyle(.orange) }
                    Button("Manage transfers") { selection = .downloads }
                    Text("Tools are included with the app. Manage or remove imported content inside its module; deleting a shared archive from one module keeps other modules’ copies available. Export important records before removing them.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding().frame(maxWidth: .infinity, alignment: .leading).background(NomadTheme.panel, in: RoundedRectangle(cornerRadius: 16))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 16)], spacing: 16) {
                    ForEach(NomadModule.allCases.filter { ![.home, .depot, .settings].contains($0) }) { module in
                        Button { selection = module } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                ModuleCard(module: module)
                                Text(availability(module)).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 22).padding(.bottom, 10)
                            }.background(NomadTheme.panel, in: RoundedRectangle(cornerRadius: 20))
                        }.buttonStyle(.plain)
                    }
                }
            }.padding(28)
        }
    }
    private func availability(_ module: NomadModule) -> String {
        switch module {
        case .mesh: return "Requires a radio and protocol integration"
        case .library, .books: return "\(library.documents.count) library documents available"
        case .models: return "\(modelStore.models.count) imported models · \(modelStore.loadedID == nil ? "none loaded" : "one loaded")"
        case .assistant:
            if case .available = SystemLanguageModel.default.availability { return "Apple’s on-device model is available" }
            return "Apple model preparation required"
        case .translation: return "Prepare each language pair before disconnecting"
        case .maps, .media, .education, .reference: return "Reader included · import compatible content"
        case .knowledge: return "Select documents and build the local index"
        case .downloads: return downloads.isReconnecting ? "Reconnecting transfers" : "\(downloads.items.count) saved transfers"
        default: return "Included in this build"
        }
    }

}

struct IntegrationView: View {
    let module: NomadModule
    var body: some View {
        ContentUnavailableView {
            Label(module.title, systemImage: module.symbol)
        } description: {
            Text(module == .mesh
                 ? "Radio protocol integration is not available in this build. Sending mesh messages also requires a compatible external Meshtastic or MeshCore radio."
                 : "This integration is not available in this build.")
        }
    }
}

struct ReadinessView: View {
    @Bindable var library: LibraryStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var assistantStatus = "Checking model availability…"
    var body: some View {
        Form {
            Section("This device") {
                LabeledContent("Knowledge Library documents", value: "\(library.documents.count)")
                LabeledContent("Knowledge Library file size", value: ByteCountFormatter.string(fromByteCount: library.documents.reduce(0) { $0 + Int64($1.byteCount) }, countStyle: .file))
                Text("Includes Books stored in the Knowledge Library. Excludes search indexes, downloads, maps, models, media, and other modules’ storage.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Available storage estimate", value: freeStorage)
                Text("The system estimate can include reclaimable space. Imports may need room for both the source and its local copy.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("System", value: ProcessInfo.processInfo.operatingSystemVersionString)
                LabeledContent("Physical memory", value: ByteCountFormatter.string(fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory), countStyle: .memory))
                LabeledContent("Build", value: buildVersion)
            }
            Section("Manage this workspace") {
                NavigationLink { BackupView() } label: { Label("Backup and restore", systemImage: "externaldrive.badge.checkmark") }
                NavigationLink { StorageAuditView() } label: { Label("Detailed storage report", systemImage: "internaldrive") }
                NavigationLink { OPDSCatalogsView() } label: { Label("Custom book catalogs", systemImage: "books.vertical") }
                NavigationLink { OfflineHelpView() } label: { Label("Offline help", systemImage: "questionmark.circle") }
            }
            Section("Offline readiness") {
                Label("Imported documents and saved records stay on this device.", systemImage: "checkmark.circle")
                LabeledContent("AI Assistant") { Text(assistantStatus).multilineTextAlignment(.trailing) }
                Label("Local AI Models requires a compatible imported GGUF file on an iPhone, iPad, or Mac. Test the chosen model before going offline.", systemImage: "sparkles")
                Label("Translation requires downloaded language packs.", systemImage: "character.bubble")
                Text("Before relying on the app offline, turn off Wi-Fi and cellular, restart the app, and open every resource you need.")
            }
            Section("Development status") {
                Text("Full NOMAD feature parity is in development. A working module does not imply every feature of its upstream application is implemented. The repository’s feature checklist records the remaining work.")
                Text("ZIM archives, PMTiles and raster MBTiles, and imported drug-label datasets have local readers. Full Kolibri exercise coverage, mesh radio protocols, and several upstream workflows still need integration. There is no cloud AI fallback.")
            }
            if let error = library.lastError {
                Section("Library needs attention") { Text(error).foregroundStyle(.orange) }
            }
        }
        .onAppear { refreshAvailability() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { refreshAvailability() } }
    }
    private var buildVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
        return "\(version) (\(build))"
    }
    private func refreshAvailability() {
        switch SystemLanguageModel.default.availability {
        case .available: assistantStatus = "Apple’s on-device model is available. Test your documents before disconnecting."
        case .unavailable(.deviceNotEligible): assistantStatus = "Apple’s model is not supported on this device."
        case .unavailable(.appleIntelligenceNotEnabled): assistantStatus = "Enable Apple Intelligence in Settings and finish its model download."
        case .unavailable(.modelNotReady): assistantStatus = "Apple’s model is not ready. Complete setup in Settings while online."
        case .unavailable: assistantStatus = "Apple’s model is unavailable. There is no cloud fallback."
        }
    }
    private var freeStorage: String {
        let values = try? URL.documentsDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Unavailable"
    }
}
