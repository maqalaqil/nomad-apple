import SwiftUI
import CoreFoundation

struct CatalogResource: Identifiable {
    let id: String
    let title: String
    let description: String
    let url: URL
    let bytes: Int64
    let exactBytes: Int64?
    let version: String
    let sha256: String?
    let sourceURL: URL?
    var sizeLabel: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
    var integrityLabel: String { sha256 == nil ? (exactBytes == nil ? "Publisher estimate; no checksum" : "Exact size; no published SHA-256") : "Publisher SHA-256 and size verified on download" }
}
struct CatalogSection: Identifiable {
    let id: String
    let title: String
    let resources: [CatalogResource]
}

enum OfflineContentCatalog {
    static func sections(bundle: Bundle = .main) throws -> [CatalogSection] {
        func json(_ name: String) throws -> [String: Any] {
            guard let url = bundle.resourceURL?.appendingPathComponent("Catalogs/\(name).json"),
                  let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
                throw CatalogError.message("The bundled content catalog is missing or invalid.")
            }
            return value
        }
        func resource(_ value: [String: Any], prefix: String) throws -> CatalogResource {
            guard let id = value["id"] as? String, !id.isEmpty, let title = (value["title"] ?? value["name"]) as? String, !title.isEmpty,
                  let urlText = value["url"] as? String, let url = URL(string: urlText), url.scheme == "https", url.host != nil,
                  url.user == nil, url.password == nil, url.fragment == nil,
                  let estimate = value["size_mb"] as? NSNumber, CFGetTypeID(estimate) != CFBooleanGetTypeID(),
                  estimate.doubleValue.isFinite, estimate.doubleValue > 0, estimate.doubleValue < 10_000_000 else {
                throw CatalogError.message("A bundled catalog entry has an invalid identity, HTTPS URL, or estimated size.")
            }
            let exact: Int64?
            if let supplied = value["size_bytes"] {
                guard let number = supplied as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
                      number.doubleValue >= 1, number.doubleValue <= 10_000_000_000_000 else {
                    throw CatalogError.message("The exact file size for \(title) is invalid. Its integrity requirement was not discarded.")
                }
                exact = number.int64Value
            } else { exact = nil }
            let hash: String?
            if let supplied = value["sha256"] {
                guard let text = supplied as? String, text.count == 64, text.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
                    throw CatalogError.message("The SHA-256 for \(title) is invalid. Its integrity requirement was not discarded.")
                }
                hash = text.lowercased()
            } else { hash = nil }
            let source = (value["source_url"] as? String).flatMap(URL.init(string:))
            return CatalogResource(id: prefix + id, title: title, description: value["description"] as? String ?? "", url: url,
                bytes: exact ?? Int64((estimate.doubleValue * 1_000_000).rounded(.up)), exactBytes: exact, version: value["version"] as? String ?? "", sha256: hash,
                sourceURL: source?.scheme == "https" && source?.host != nil && source?.user == nil && source?.password == nil ? source : nil)
        }
        var loaded: [CatalogSection] = []
        for name in ["wikipedia-ar", "wikipedia-en", "world-maps", "models"] {
            let value = try json(name)
            guard let options = value["options"] as? [[String: Any]], !options.isEmpty else { throw CatalogError.message("The \(name) catalog has no valid resource list.") }
            loaded.append(CatalogSection(id: name, title: value["title"] as? String ?? name,
                resources: try options.map { try resource($0, prefix: name + "-") }))
        }
        let wikipedia = try json("wikipedia")
        loaded.append(CatalogSection(id: "wikipedia", title: "NOMAD quick-reference editions · older snapshot",
            resources: try (wikipedia["options"] as? [[String: Any]] ?? []).filter { ($0["id"] as? String)?.hasPrefix("top-") == true }.map { try resource($0, prefix: "wiki-") }))
        let maps = try json("maps")
        for collection in maps["collections"] as? [[String: Any]] ?? [] {
            guard let id = collection["slug"] as? String, let name = collection["name"] as? String else { continue }
            loaded.append(CatalogSection(id: id, title: name, resources: try (collection["resources"] as? [[String: Any]] ?? []).map { try resource($0, prefix: id + "-") }))
        }
        let resources = loaded.flatMap(\.resources)
        guard Set(loaded.map(\.id)).count == loaded.count, Set(resources.map(\.id)).count == resources.count else { throw CatalogError.message("The bundled catalog contains duplicate identities.") }
        guard loaded.contains(where: { !$0.resources.isEmpty }) else { throw CatalogError.message("No compatible resources were found in the bundled catalog.") }
        return loaded
    }

    static func fullCollection() throws -> [CatalogResource] {
        let ids: Set<String> = ["wikipedia-ar-all-maxi", "wikipedia-en-all-maxi", "world-maps-world-streets-v4"]
        let selected = try sections().flatMap(\.resources).filter { ids.contains($0.id) }
        guard selected.count == ids.count else { throw CatalogError.message("The complete Arabic, English and worldwide collection is missing a catalog entry.") }
        return selected
    }

    /// Kept separate from filesystem inspection so overflow and import-copy accounting are testable.
    static func requiredBytes(newFiles: [Int64], pendingBytes: [Int64], importCopy: Int64) throws -> Int64 {
        var required: Int64 = 512 * 1_024 * 1_024
        for amount in newFiles + pendingBytes + [importCopy] {
            guard amount >= 0 else { throw CatalogError.message("A catalog storage estimate is invalid.") }
            let (next, overflow) = required.addingReportingOverflow(amount)
            guard !overflow else { throw CatalogError.message("The requested collection exceeds supported storage accounting.") }
            required = next
        }
        return required
    }

    @MainActor private static func importCopyBytes(_ resources: [CatalogResource], store: DownloadStore) throws -> Int64 {
        // This performs a real tiny filesystem check; platform identity is not proof.
        let canShareArchive = try InternalDownloadLink.probe(in: store.root)
        let directReaderFormats: Set<String> = ["zim", "pdf", "txt", "md", "epub", "pmtiles"]
        return resources.filter { !canShareArchive || !directReaderFormats.contains($0.url.pathExtension.lowercased()) }.map(\.bytes).max() ?? 0
    }

    @MainActor private static func preflight(_ resources: [CatalogResource], importCopy: Int64, store: DownloadStore) throws {
        guard store.canWrite else { throw CatalogError.message(store.error ?? "Download history is unavailable. No new downloads were added.") }
        let estimates = Dictionary(try sections().flatMap(\.resources).map { ($0.url, $0.bytes) }, uniquingKeysWith: max)
        let pending = store.items.filter { $0.state == .queued || $0.state == .downloading }.map { item in
            let total = max(0, item.expectedBytes ?? (item.expected > 0 ? item.expected : estimates[item.url] ?? 0))
            return total - min(total, max(0, item.received))
        }
        let required = try requiredBytes(newFiles: resources.map(\.bytes), pendingBytes: pending, importCopy: importCopy)
        guard let free = try? store.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage else {
            throw CatalogError.message("Available storage could not be checked. No new downloads were added.")
        }
        guard free >= required else {
            throw CatalogError.message("These downloads need about \(ByteCountFormatter.string(fromByteCount: required, countStyle: .file)) free now, including queued transfers and temporary room for one import copy. Available: \(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)). Free space or choose smaller editions; no new downloads were added.")
        }
    }

    @MainActor static func queue(_ resource: CatalogResource, store: DownloadStore? = nil) throws {
        let store = store ?? .shared
        guard !store.items.contains(where: { $0.url == resource.url }) else { throw CatalogError.message("This resource is already in Downloads. Open that entry to resume, retry, or use it.") }
        try preflight([resource], importCopy: importCopyBytes([resource], store: store), store: store)
        try store.add(urlText: resource.url.absoluteString, checksum: resource.sha256 ?? "", expectedBytes: resource.exactBytes)
    }

    /// A conservative capacity check includes all pending transfers plus room for one reader import copy.
    @MainActor static func queueFullCollection(store: DownloadStore? = nil) throws -> String {
        let store = store ?? .shared
        let resources = try fullCollection()
        let missing = resources.filter { resource in !store.items.contains { $0.url == resource.url } }
        if missing.isEmpty { return "This collection is already listed in Downloads. Resume paused entries or retry failed entries there; completed files remain available." }
        try preflight(missing, importCopy: importCopyBytes(resources, store: store), store: store)
        var added = 0
        do {
            for resource in missing { try store.add(urlText: resource.url.absoluteString, checksum: resource.sha256 ?? "", expectedBytes: resource.exactBytes); added += 1 }
        } catch {
            if added > 0 { throw CatalogError.message("Added \(added) archive(s), then the remaining queue could not be saved: \(error.localizedDescription) Open Downloads to review the entries already added.") }
            throw error
        }
        return "Added \(added) archives. Downloads processes them one at a time. Existing paused or failed entries need Resume in Downloads. Use Add to library or Add to offline maps on each completed entry, then check the content in its reader."
    }
}

struct CatalogDownloadsView: View {
    @State private var sections: [CatalogSection] = []
    @State private var query = ""
    @State private var selected: CatalogResource?
    @State private var error: String?
    @State private var catalogError: String?
    @State private var confirmation: String?
    @State private var confirmCollection = false
    private let store = DownloadStore.shared

    var body: some View {
        List {
            Section {
                Text("Prepare Wikipedia, worldwide street maps and a small local AI model. The catalog works offline; new downloads need Wi-Fi. Verify content in its reader before disconnecting.").foregroundStyle(.secondary)
                Text("Arabic/English and world-map metadata checked November 3, 2026. US regional catalog: NOMAD February 2026. File editions and source dates are shown below; links can change.").font(.caption).foregroundStyle(.secondary)
                Button("Prepare Arabic + English + worldwide maps", systemImage: "globe") { confirmCollection = true }.disabled(catalogError != nil || sections.isEmpty)
                Text("Full-image Wikipedia editions plus the world street basemap total about 281 GB. Direct imports from Downloads avoid duplicate archive storage when supported; otherwise temporary copies need additional space. This does not include every Wikimedia media file, satellite imagery or navigation routing.").font(.footnote).foregroundStyle(.secondary)
            }
            if let catalogError {
                Section("Catalog unavailable") {
                    Text(catalogError).foregroundStyle(.orange)
                    Button("Reload bundled catalog") { load() }
                }
            } else if !sections.isEmpty && !sections.contains(where: { $0.resources.contains(where: matches) }) {
                ContentUnavailableView.search(text: query)
            }
            ForEach(sections) { section in
                let results = section.resources.filter(matches)
                if !results.isEmpty {
                    Section(section.title) {
                        ForEach(results) { resource in
                            VStack(alignment: .leading, spacing: 7) {
                                Button { selected = resource } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack { Text(resource.title).font(.headline); Spacer(); Image(systemName: "arrow.down.circle") }
                                        Text(resource.description).font(.subheadline).foregroundStyle(.secondary)
                                        Text("\(resource.exactBytes == nil ? "About " : "")\(resource.sizeLabel) · \(resource.version)").font(.caption).foregroundStyle(.secondary)
                                        Text(resource.integrityLabel).font(.caption).foregroundStyle(.secondary)
                                    }
                                }.buttonStyle(.plain)
                                if let source = resource.sourceURL { Link("Publisher details (online)", destination: source).font(.caption) }
                            }.padding(.vertical, 6)
                        }
                    }
                }
            }
        }
        .navigationTitle("Content catalog")
        .searchable(text: $query, prompt: "Find Wikipedia or a map region")
        .task { load() }
        .confirmationDialog("Download \(selected?.title ?? "this resource")?", isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } }), titleVisibility: .visible) {
            Button("Download over Wi-Fi") { if let selected { queue(selected) }; selected = nil }
        } message: { Text("\(selected?.sizeLabel ?? ""). Importing may temporarily need another copy. \(selected?.integrityLabel ?? "")") }
        .confirmationDialog("Download the complete Arabic, English and world-map collection?", isPresented: $confirmCollection, titleVisibility: .visible) {
            Button("Queue 281 GB over Wi-Fi") {
                do { confirmation = try OfflineContentCatalog.queueFullCollection() }
                catch { self.error = error.localizedDescription }
            }
        } message: { Text("The app checks available storage and whether direct reader imports need another copy before queuing. Downloads are serial and can take many hours or days. Open Downloads for progress and pause controls.") }
        .alert("Content catalog", isPresented: Binding(get: { error != nil || confirmation != nil }, set: { if !$0 { error = nil; confirmation = nil } })) {
            Button("OK") { error = nil; confirmation = nil }
        } message: { Text(error ?? confirmation ?? "") }
    }

    private func matches(_ resource: CatalogResource) -> Bool { query.isEmpty || (resource.title + " " + resource.description).localizedCaseInsensitiveContains(query) }
    private func load() {
        guard sections.isEmpty else { return }
        do { sections = try OfflineContentCatalog.sections(); catalogError = nil }
        catch { catalogError = error.localizedDescription }
    }
    private func queue(_ resource: CatalogResource) {
        do {
            try OfflineContentCatalog.queue(resource, store: store)
            confirmation = "Added \(resource.title). Open Downloads to see progress."
        } catch { self.error = error.localizedDescription }
    }
}

enum CatalogError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}
