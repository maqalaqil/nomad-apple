import SwiftUI
import UniformTypeIdentifiers

struct InventoryView: View {
    @StateObject private var store = InventoryStore()
    @State private var query = ""
    @State private var location = ""
    @State private var tag = ""
    @State private var lowStockOnly = false
    @State private var expiredWarrantyOnly = false
    @State private var sort = "name"
    @State private var editing: InventoryItem?
    @State private var adding = false
    @State private var deleting: InventoryItem?
    @State private var importing = false
    @State private var pendingImport: InventoryPortableArchive?
    @State private var exporting = false
    @State private var exportDocument = CollectionExportDocument(data: Data())
    @State private var importTask: Task<Void, Never>?
    @State private var busy = false
    @State private var generation = UUID()
    @State private var error: String?

    private var visibleItems: [InventoryItem] {
        store.items.filter { item in
            (query.isEmpty || item.searchableText.localizedCaseInsensitiveContains(query)) &&
            (location.isEmpty || item.location == location) && (tag.isEmpty || item.tags.contains(tag)) &&
            (!lowStockOnly || item.isLowStock) && (!expiredWarrantyOnly || (item.warrantyExpires.map { $0 < Calendar.current.startOfDay(for: Date()) } ?? false))
        }.sorted { lhs, rhs in
            if sort == "updated", lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            if sort == "quantity", lhs.quantity != rhs.quantity { return lhs.quantity < rhs.quantity }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    var body: some View {
        List {
            Section {
                Text("\(store.items.count) items · \(store.items.filter(\.isLowStock).count) at or below minimum stock")
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Filters and sorting") {
                    Picker("Location", selection: $location) {
                        Text("All locations").tag("")
                        ForEach(Array(Set(store.items.map(\.location).filter { !$0.isEmpty })).sorted(), id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Tag", selection: $tag) {
                        Text("All tags").tag("")
                        ForEach(Array(Set(store.items.flatMap(\.tags))).sorted(), id: \.self) { Text($0).tag($0) }
                    }
                    Toggle("At or below minimum stock", isOn: $lowStockOnly)
                    Toggle("Expired warranty", isOn: $expiredWarrantyOnly)
                    Picker("Sort", selection: $sort) {
                        Text("Name").tag("name"); Text("Recently updated").tag("updated"); Text("Lowest quantity").tag("quantity")
                    }
                    Button("Clear filters") { query = ""; location = ""; tag = ""; lowStockOnly = false; expiredWarrantyOnly = false }
                }
            }
            if store.items.isEmpty {
                ContentUnavailableView("Your inventory is empty", systemImage: "shippingbox", description: Text("Track supplies, equipment, receipts and warranty details locally."))
            } else if visibleItems.isEmpty { ContentUnavailableView.search(text: query) }
            ForEach(visibleItems) { item in
                Button { editing = item } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name).font(.headline).foregroundStyle(.primary)
                            if !item.location.isEmpty { Text(item.location).font(.subheadline).foregroundStyle(.secondary) }
                            if !item.tags.isEmpty { Text(item.tags.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
                            if !item.notes.isEmpty { Text(item.notes).lineLimit(2).font(.caption).foregroundStyle(.secondary) }
                            if !item.attachments.isEmpty { Label("\(item.attachments.count) attachments", systemImage: "paperclip").font(.caption).foregroundStyle(.secondary) }
                            if item.isLowStock { Label("At or below minimum stock", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange) }
                        }
                        Spacer(); Text(item.quantity.formatted()).monospacedDigit().foregroundStyle(.secondary)
                    }
                }.disabled(!store.canWrite || busy)
                    .swipeActions { Button("Delete", role: .destructive) { deleting = item }.disabled(!store.canWrite || busy) }
            }
            if busy { HStack { ProgressView(); Text("Reading inventory archive…"); Button("Cancel") { importTask?.cancel() } } }
            Section {
                Text("Portable JSON includes local photos and receipts, up to 100 MB of attachments. Version 1 inventories remain importable. This is the NOMAD native inventory format, not a Homebox database import.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Inventory")
        .searchable(text: $query, prompt: "Names, tags, serials, models, locations or notes")
        .toolbar {
            ToolbarItem(placement: .primaryAction) { Button("Add item", systemImage: "plus") { adding = true }.disabled(!store.canWrite || busy) }
            ToolbarItem(placement: .secondaryAction) {
                Menu("Inventory files", systemImage: "ellipsis.circle") {
                    Button("Import inventory and attachments", systemImage: "square.and.arrow.down") { importing = true }
                    Button("Export inventory and attachments", systemImage: "square.and.arrow.up") {
                        do { exportDocument = CollectionExportDocument(data: try store.export()); exporting = true } catch { self.error = error.localizedDescription }
                    }
                }.disabled(!store.canWrite || busy)
            }
        }
        .sheet(isPresented: $adding) { InventoryEditor(item: InventoryItem(name: "", location: "", quantity: 1, notes: ""), store: store, original: nil) }
        .sheet(item: $editing) { item in InventoryEditor(item: item, store: store, original: item) }
        .confirmationDialog("Delete \(deleting?.name ?? "item")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete item and its attachments", role: .destructive) {
                guard let deleting else { return }
                do { try store.remove(deleting) } catch { self.error = error.localizedDescription }
                self.deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: { Text("Export the item first if you need to retain its local photos and receipts.") }
        .confirmationDialog("Replace inventory?", isPresented: Binding(get: { pendingImport != nil }, set: { if !$0 { pendingImport = nil } }), titleVisibility: .visible) {
            Button("Replace with \(pendingImport?.items.count ?? 0) imported items", role: .destructive) {
                guard let pendingImport else { return }
                do { try store.replace(with: pendingImport) } catch { self.error = error.localizedDescription }
                self.pendingImport = nil
            }
            Button("Cancel", role: .cancel) { pendingImport = nil }
        } message: { Text("Your current \(store.items.count) items and attachments will be replaced by the validated archive. Export them first if needed.") }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do { startImport(try result.get()) } catch { self.error = error.localizedDescription }
        }
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .json, defaultFilename: "nomad-inventory.json") {
            if case .failure(let failure) = $0 { error = failure.localizedDescription }
        }
        .alert("Inventory", isPresented: Binding(get: { error != nil || store.error != nil }, set: { if !$0 { error = nil; store.error = nil } })) {
            Button("OK") { error = nil; store.error = nil }
        } message: { Text(error ?? store.error ?? "") }
        .onDisappear { generation = UUID(); importTask?.cancel(); importTask = nil; busy = false }
    }

    private func startImport(_ url: URL) {
        busy = true
        let token = UUID(); generation = token
        importTask = Task { @MainActor in
            let worker = Task.detached(priority: .userInitiated) {
                let data = try InventoryAttachmentFiles.selected(url, maximum: InventoryValidation.maximumArchiveBytes)
                let portable = try JSONDecoder().decode(InventoryPortableArchive.self, from: data)
                try InventoryValidation.portable(portable)
                let references = Dictionary(uniqueKeysWithValues: portable.items.flatMap(\.attachments).map { ($0.id, $0) })
                for file in portable.files { try Task.checkCancellation(); try InventoryAttachmentFiles.validate(file.data, descriptor: references[file.id]!) }
                return portable
            }
            do {
                let portable = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                if generation == token { pendingImport = portable }
            } catch is CancellationError {} catch { if generation == token { self.error = error.localizedDescription } }
            if generation == token { busy = false; importTask = nil }
        }
    }
}
