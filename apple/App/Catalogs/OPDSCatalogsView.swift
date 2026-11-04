import SwiftUI

private struct OPDSRoute: Hashable {
    let catalogID: UUID
    let url: URL
    let title: String
}

struct OPDSCatalogsView: View {
    @State private var store = OPDSCatalogStore.shared
    @State private var adding = false
    @State private var name = ""
    @State private var urlText = ""
    @State private var error: String?
    @State private var removing: OPDSCatalog?

    var body: some View {
        List {
            Section {
                Text("Add a public OPDS 1.x catalog to browse books or offline archives. Opened pages are saved locally; refreshing, new searches and downloads need a connection.")
                Text("Only HTTPS feeds and direct file acquisitions are supported. Sign-in, purchases, loans, DRM and OPDS 2 JSON are not supported. Catalogs control their descriptions, links and licensing.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let message = store.error {
                Section("Saved catalogs unavailable") {
                    Text(message).foregroundStyle(.orange)
                    Button("Reload saved settings") { store.reload() }
                }
            }
            Section("Your catalogs") {
                if store.catalogs.isEmpty {
                    ContentUnavailableView("No custom catalogs", systemImage: "books.vertical", description: Text("Use Add Catalog with the HTTPS OPDS URL supplied by a publisher or library."))
                }
                ForEach(store.catalogs) { catalog in
                    NavigationLink(value: OPDSRoute(catalogID: catalog.id, url: catalog.url, title: catalog.name)) {
                        VStack(alignment: .leading) {
                            Text(catalog.name)
                            Text(catalog.url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }.swipeActions { Button("Remove", role: .destructive) { removing = catalog } }
                }
                Button("Add Catalog", systemImage: "plus") { adding = true }.disabled(!store.canWrite)
                Button("Use Kiwix Library URL", systemImage: "books.vertical") {
                    name = "Kiwix Library"; urlText = "https://library.kiwix.org/catalog/v2/root.xml"; adding = true
                }.disabled(!store.canWrite)
            }
            if !store.acquisitions.isEmpty {
                Section("Recent acquisition requests") {
                    ForEach(store.acquisitions.prefix(20)) { receipt in
                        DisclosureGroup(receipt.entryTitle) {
                            LabeledContent("Catalog", value: receipt.catalogName)
                            Text(receipt.feedURL.absoluteString).textSelection(.enabled)
                            Text(receipt.acquisitionURL.absoluteString).textSelection(.enabled)
                            if let url = receipt.resolvedURL, url != receipt.acquisitionURL { Text("Resolved file: \(url.absoluteString)").textSelection(.enabled) }
                            if let hash = receipt.sha256 { Text("Publisher SHA-256: \(hash)").textSelection(.enabled) }
                            Text(receipt.requestedAt, style: .date)
                            Text("Check Downloads for transfer state. A request is not proof that a file finished downloading.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Custom OPDS Catalogs")
        .navigationDestination(for: OPDSRoute.self) { route in OPDSFeedView(route: route, store: store) }
        .sheet(isPresented: $adding) {
            NavigationStack {
                Form {
                    TextField("Catalog name", text: $name)
                    TextField("https://…/catalog.xml", text: $urlText).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("Saving a catalog does not download its publications. Open it to fetch a bounded metadata page.").font(.footnote).foregroundStyle(.secondary)
                }
                .navigationTitle("Add OPDS Catalog")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { adding = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add") {
                            do { try store.add(name: name, urlText: urlText); adding = false; name = ""; urlText = "" }
                            catch { self.error = error.localizedDescription }
                        }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .alert("Catalog needs attention", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                    Button("OK") { error = nil }
                } message: { Text(error ?? "") }
            }
        }
        .alert("Catalog needs attention", isPresented: Binding(get: { error != nil && !adding }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
        .confirmationDialog("Remove this catalog and its cached pages? Downloaded and imported publications stay available.", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("Remove Catalog", role: .destructive) {
                do { if let removing { try store.remove(removing.id) }; removing = nil }
                catch { self.error = error.localizedDescription }
            }
        }
    }
}

private struct OPDSAcquisitionChoice: Identifiable {
    let entry: OPDSEntry
    let link: OPDSLink
    var id: String { entry.id + link.id }
}

private struct OPDSFeedView: View {
    let route: OPDSRoute
    let store: OPDSCatalogStore
    @State private var page: OPDSPage?
    @State private var filter = ""
    @State private var category = ""
    @State private var searchText = ""
    @State private var searchResult: OPDSRoute?
    @State private var error: String?
    @State private var notice: String?
    @State private var busy = false
    @State private var work: Task<Void, Never>?
    @State private var acquisition: OPDSAcquisitionChoice?
    @State private var resolvedAcquisition: OPDSResolvedAcquisition?
    @State private var resolutionError: String?
    @State private var inheritedSearchLink: OPDSLink?
    private var catalog: OPDSCatalog? { store.catalogs.first { $0.id == route.catalogID } }
    private var entries: [OPDSEntry] {
        page?.entries.filter { entry in
            (category.isEmpty || entry.categories.contains(category)) &&
            (filter.isEmpty || ([entry.title, entry.summary] + entry.authors + entry.categories).contains { $0.localizedCaseInsensitiveContains(filter) })
        } ?? []
    }
    private var searchLink: OPDSLink? { page?.links.first { $0.relation == "search" } ?? inheritedSearchLink }

    var body: some View {
        List {
            if catalog == nil {
                ContentUnavailableView("Catalog removed", systemImage: "books.vertical", description: Text("Return to Custom OPDS Catalogs to add it again."))
            } else {
                statusSection
                if let page {
                    searchSection(page)
                    navigationSection(page)
                    if entries.isEmpty {
                        ContentUnavailableView("No entries on this page", systemImage: "magnifyingglass", description: Text(filter.isEmpty && category.isEmpty ? "Try another category or page." : "Clear the page filter or choose another category."))
                    }
                    ForEach(entries) { entry in entrySection(entry) }
                    pagingSection(page)
                } else if !busy {
                    ContentUnavailableView("Catalog page unavailable", systemImage: "wifi.slash", description: Text("Use Refresh when connected. Pages you open successfully are cached for later offline browsing."))
                }
            }
        }
        .navigationTitle(page?.title ?? route.title)
        .searchable(text: $filter, prompt: "Filter this page")
        .task(id: route) {
            work = Task { await load(preferCache: true) }
            await work?.value
        }
        .onDisappear { work?.cancel() }
        .navigationDestination(isPresented: Binding(get: { searchResult != nil }, set: { if !$0 { searchResult = nil } })) {
            if let searchResult { OPDSFeedView(route: searchResult, store: store) }
        }
        .alert("Catalog needs attention", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
        .alert("Download queued", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK") { notice = nil }
        } message: { Text(notice ?? "") }
        .sheet(item: $acquisition) { choice in acquisitionSheet(choice) }
    }

    private var statusSection: some View {
        Section {
            HStack {
                if busy { ProgressView() }
                Button("Refresh page", systemImage: "arrow.clockwise") { work = Task { await load(preferCache: false) } }.disabled(busy)
                if busy { Button("Cancel") { work?.cancel() } }
            }
            if let page {
                Text("Saved \(page.fetchedAt.formatted(date: .abbreviated, time: .shortened)). This is a snapshot, not a live availability check.")
                    .font(.caption).foregroundStyle(.secondary)
                Text(page.sourceURL.absoluteString).font(.caption).textSelection(.enabled)
                if page.ignoredUnsafeLinks > 0 { Text("\(page.ignoredUnsafeLinks) insecure or invalid links were omitted.").font(.caption).foregroundStyle(.orange) }
            } else { Text(route.url.absoluteString).font(.caption).textSelection(.enabled) }
        }
    }
    @ViewBuilder private func searchSection(_ page: OPDSPage) -> some View {
        if !page.categories.isEmpty || searchLink != nil {
            Section("Find publications") {
                if !page.categories.isEmpty {
                    Picker("Category on this page", selection: $category) {
                        Text("All categories").tag("")
                        ForEach(page.categories, id: \.self) { Text($0).tag($0) }
                    }
                }
                if searchLink != nil {
                    TextField("Search the catalog", text: $searchText).onSubmit { startSearch() }
                    Button("Search catalog", systemImage: "magnifyingglass") { startSearch() }.disabled(busy || searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Text("Catalog search contacts the provider unless the same result page is already cached. Filter this page searches the saved entries locally.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
    @ViewBuilder private func navigationSection(_ page: OPDSPage) -> some View {
        let links = page.links.filter { ($0.isFacet || $0.isFeed) && !["self", "next", "previous", "prev", "first", "last", "search"].contains($0.relation) }
        if !links.isEmpty {
            Section("Browse catalog") {
                ForEach(Array(Dictionary(links.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values).sorted { $0.id < $1.id }) { link in
                    NavigationLink(value: OPDSRoute(catalogID: route.catalogID, url: link.url, title: link.title.isEmpty ? link.relation : link.title)) {
                        Text([link.facetGroup, link.title.isEmpty ? link.relation : link.title].compactMap { $0 }.joined(separator: " · "))
                    }
                }
            }
        }
    }
    private func entrySection(_ entry: OPDSEntry) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 7) {
                Text(entry.title).font(.headline)
                if !entry.authors.isEmpty { Text(entry.authors.joined(separator: ", ")).foregroundStyle(.secondary) }
                if !entry.summary.isEmpty { Text(entry.summary).font(.callout).lineLimit(6) }
                if !entry.language.isEmpty { Text("Language: \(entry.language)").font(.caption) }
                if !entry.rights.isEmpty { Text(entry.rights).font(.caption).foregroundStyle(.secondary) }
            }
            ForEach(Array(Dictionary(entry.links.filter { $0.isFeed || $0.isAcquisition }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values).sorted { $0.id < $1.id }) { link in
                if link.isFeed {
                    NavigationLink(link.title.isEmpty ? "Browse \(entry.title)" : link.title, value: OPDSRoute(catalogID: route.catalogID, url: link.url, title: entry.title))
                } else if link.isDirectAcquisition {
                    Button {
                        resolvedAcquisition = nil; resolutionError = nil
                        acquisition = OPDSAcquisitionChoice(entry: entry, link: link)
                    } label: {
                        Label("\(link.isSample ? "Download sample" : "Download") · \(link.formatLabel)\(link.length.map { " · " + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "")", systemImage: "arrow.down.circle")
                    }
                } else {
                    Text("\(link.formatLabel): \(link.unavailableReason ?? "This acquisition requires a provider workflow that is not supported.")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !entry.links.contains(where: { $0.isFeed || $0.isAcquisition }) {
                Text("This entry has no supported browsing or acquisition link.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    @ViewBuilder private func pagingSection(_ page: OPDSPage) -> some View {
        let links = page.links.filter { ["next", "previous", "prev", "first", "last"].contains($0.relation) }
        if !links.isEmpty {
            Section("Pages") {
                ForEach(Array(Dictionary(links.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values).sorted { $0.id < $1.id }) { link in
                    NavigationLink(link.title.isEmpty ? link.relation.capitalized + " page" : link.title,
                        value: OPDSRoute(catalogID: route.catalogID, url: link.url, title: route.title))
                }
            }
        }
    }
    private func acquisitionSheet(_ choice: OPDSAcquisitionChoice) -> some View {
        NavigationStack {
            Form {
                Text(choice.entry.title).font(.headline)
                LabeledContent("Format", value: choice.link.formatLabel)
                LabeledContent("Size", value: (resolvedAcquisition?.length ?? choice.link.length).map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Not published")
                Text(choice.link.url.absoluteString).textSelection(.enabled)
                if let resolvedAcquisition {
                    if resolvedAcquisition.url != choice.link.url { Text("Resolved HTTPS file: \(resolvedAcquisition.url.absoluteString)").font(.caption).textSelection(.enabled) }
                    Text(resolvedAcquisition.sha256 == nil ? "No SHA-256 checksum was published for this acquisition. If a byte length is published, Downloads checks it exactly." : "The publisher's Metalink supplies SHA-256 and an exact size; Downloads checks both.").font(.footnote)
                    if let catalogLength = choice.link.length, let exact = resolvedAcquisition.length, catalogLength != exact {
                        Text("The Kiwix catalog estimate is rounded to KiB (\(catalogLength.formatted()) bytes). The Metalink's exact size is \(exact.formatted()) bytes; that exact value is enforced.").font(.caption).foregroundStyle(.secondary)
                    }
                } else if let resolutionError { Text(resolutionError).foregroundStyle(.orange) }
                else { ProgressView("Checking acquisition metadata…") }
                Text("The catalog supplied this link. Inspect the publication’s rights and trust the provider before downloading.").font(.footnote)
                if choice.link.fileExtension == nil {
                    Text("This format has no native reader mapping. The file can be saved or shared from Downloads, but this app may not open it.").font(.footnote).foregroundStyle(.orange)
                }
                Text("Downloads checks current free space for known queued sizes. Unknown-size files may still fill storage; large external-format imports may require an additional copy.").font(.caption).foregroundStyle(.secondary)
                Button("Queue download", systemImage: "arrow.down.circle") { queue(choice) }.disabled(!store.canWrite || DownloadStore.shared.isReconnecting || resolvedAcquisition == nil)
            }
            .navigationTitle(choice.link.isSample ? "Download sample" : "Download publication")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { acquisition = nil } } }
            .task(id: choice.id) {
                do {
                    let resolved = try await OPDSResolvedAcquisition.resolve(choice.link)
                    try Task.checkCancellation()
                    if acquisition?.id == choice.id { resolvedAcquisition = resolved }
                } catch { if !Task.isCancelled, acquisition?.id == choice.id { resolutionError = error.localizedDescription } }
            }
        }
    }
    private func load(preferCache: Bool) async {
        guard catalog != nil, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            if let catalog, route.url != catalog.url {
                inheritedSearchLink = try store.cachedPage(catalogID: route.catalogID, url: catalog.url)?.links.first { $0.relation == "search" }
            }
            if preferCache, let cached = try store.cachedPage(catalogID: route.catalogID, url: route.url) { page = cached; return }
            let fetched = try await OPDSClient.page(route.url)
            try Task.checkCancellation()
            try store.cache(fetched, catalogID: route.catalogID, requestedURL: route.url)
            page = fetched
            if !fetched.categories.contains(category) { category = "" }
        } catch is CancellationError { }
        catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
    private func startSearch() {
        guard !busy, let link = searchLink else { return }
        work = Task {
            busy = true
            defer { busy = false }
            do {
                let template: OPDSSearchTemplate
                if let saved = try store.cachedSearch(catalogID: route.catalogID, link: link) { template = saved }
                else {
                    template = try await OPDSClient.searchTemplate(link)
                    try Task.checkCancellation()
                    try store.cacheSearch(template, catalogID: route.catalogID, link: link)
                }
                searchResult = OPDSRoute(catalogID: route.catalogID, url: try template.url(query: searchText), title: "Search: \(searchText)")
            } catch is CancellationError { }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
    private func queue(_ choice: OPDSAcquisitionChoice) {
        guard let catalog, let page, let resolved = resolvedAcquisition else { return }
        acquisition = nil
        var receipt: UUID?
        do {
            let downloads = DownloadStore.shared
            guard !downloads.items.contains(where: { $0.url == resolved.url }) else { throw OPDSError.invalid("This publication is already in Downloads. Resume, retry or use its existing entry there.") }
            receipt = try store.recordAcquisition(catalog: catalog, page: page, entry: choice.entry, link: choice.link, resolved: resolved)
            let sanitized = choice.entry.title.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && !"/\\:".unicodeScalars.contains($0) }
            var name = String(String.UnicodeScalarView(sanitized))
            while name.utf8.count > 180 { name.removeLast() }
            if name.isEmpty || name == "." || name == ".." { name = "Publication" }
            let suggested = resolved.filename ?? choice.link.fileExtension.map { name + "." + $0 }
            try downloads.add(urlText: resolved.url.absoluteString, checksum: resolved.sha256 ?? "", expectedBytes: resolved.length, suggestedFilename: suggested)
            notice = "Added to Downloads. Open its completed entry to add a supported file to the library. The catalog source and acquisition URL were saved with this request."
        } catch {
            if let receipt { try? store.removeAcquisition(receipt) }
            self.error = error.localizedDescription
        }
    }
}
