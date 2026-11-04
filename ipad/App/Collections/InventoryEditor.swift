import SwiftUI
import PDFKit
import ImageIO
import UniformTypeIdentifiers

private struct InventoryAttachmentPreview: Identifiable {
    let id = UUID()
    let attachment: InventoryAttachment
    let data: Data
}

struct InventoryEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: InventoryStore
    let original: InventoryItem?
    @State private var item: InventoryItem
    @State private var quantityText: String
    @State private var minimumText: String
    @State private var tagsText: String
    @State private var priceText: String
    @State private var error: String?
    @State private var importing = false
    @State private var busy = false
    @State private var pending: [InventoryPreparedAttachment] = []
    @State private var removing: InventoryAttachment?
    @State private var preview: InventoryAttachmentPreview?
    @State private var task: Task<Void, Never>?
    @State private var generation = UUID()

    init(item: InventoryItem, store: InventoryStore, original: InventoryItem?) {
        self.store = store; self.original = original
        _item = State(initialValue: item); _quantityText = State(initialValue: String(item.quantity))
        _minimumText = State(initialValue: item.minimumStock.map(String.init) ?? "")
        _tagsText = State(initialValue: item.tags.joined(separator: ", "))
        _priceText = State(initialValue: item.purchasePrice ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Item") {
                    TextField("Name", text: $item.name)
                    TextField("Location", text: $item.location)
                    TextField("Quantity", text: $quantityText).keyboardType(.numberPad)
                    TextField("Minimum stock (optional)", text: $minimumText).keyboardType(.numberPad)
                    Text("Low stock means the quantity is at or below the minimum. Leave the minimum empty to disable the flag.").font(.caption).foregroundStyle(.secondary)
                    TextField("Tags, separated by commas", text: $tagsText)
                }
                Section("Identification") {
                    TextField("Manufacturer", text: $item.manufacturer)
                    TextField("Model", text: $item.model)
                    TextField("Serial number", text: $item.serialNumber).autocorrectionDisabled().textInputAutocapitalization(.never)
                }
                Section("Purchase and warranty") {
                    Toggle("Record purchase date", isOn: Binding(get: { item.purchaseDate != nil }, set: { item.purchaseDate = $0 ? (item.purchaseDate ?? Date()) : nil }))
                    if item.purchaseDate != nil {
                        DatePicker("Purchase date", selection: Binding(get: { item.purchaseDate ?? Date() }, set: { item.purchaseDate = $0 }), displayedComponents: .date)
                    }
                    HStack {
                        TextField("Purchase value", text: $priceText).keyboardType(.decimalPad)
                        TextField("Currency code", text: $item.currencyCode).textInputAutocapitalization(.characters).autocorrectionDisabled().frame(width: 90)
                    }
                    Text("Use a decimal point and a three-letter currency code, such as USD or SAR. Values in different currencies are not added together.").font(.caption).foregroundStyle(.secondary)
                    Toggle("Record warranty expiry", isOn: Binding(get: { item.warrantyExpires != nil }, set: { item.warrantyExpires = $0 ? (item.warrantyExpires ?? Date()) : nil }))
                    if item.warrantyExpires != nil {
                        DatePicker("Warranty expires", selection: Binding(get: { item.warrantyExpires ?? Date() }, set: { item.warrantyExpires = $0 }), displayedComponents: .date)
                    }
                }
                Section("Notes") { TextEditor(text: $item.notes).frame(minHeight: 120) }
                Section("Local photos and receipts") {
                    ForEach(item.attachments) { attachment in
                        HStack {
                            Button { showPreview(attachment) } label: {
                                VStack(alignment: .leading) {
                                    Label(attachment.name, systemImage: attachment.fileExtension == "pdf" ? "doc.text" : "photo")
                                    Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.byteCount), countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button("Remove", role: .destructive) { removing = attachment }
                        }.buttonStyle(.borderless)
                    }
                    Button("Attach photos or PDF receipts", systemImage: "paperclip") { importing = true }.disabled(busy || item.attachments.count >= 20)
                    if busy { HStack { ProgressView(); Text("Preparing local copies…"); Button("Cancel") { task?.cancel() } } }
                    Text("Up to 20 attachments per item, 20 MB per selected file and 100 MB for the whole inventory. Photos are resized to 2,048 pixels and saved as JPEG without original metadata; PDF receipts keep their original bytes. Attachments are committed when you save the item.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .accessibilityIdentifier("inventory.editor.form")
            .navigationTitle("Inventory item")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { task?.cancel(); dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(busy || item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.canWrite) }
            }
            .confirmationDialog("Remove attachment from this item?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
                Button("Remove when item is saved", role: .destructive) {
                    guard let removing else { return }
                    item.attachments.removeAll { $0.id == removing.id }; pending.removeAll { $0.attachment.id == removing.id }; self.removing = nil
                }
                Button("Keep attachment", role: .cancel) { removing = nil }
            }
            .sheet(item: $preview) { InventoryAttachmentViewer(preview: $0) }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.image, .pdf], allowsMultipleSelection: true) { result in
                do { try importFiles(result.get()) } catch { self.error = error.localizedDescription }
            }
            .onDisappear { generation = UUID(); task?.cancel() }
        }
    }

    private func showPreview(_ attachment: InventoryAttachment) {
        do {
            let bytes: Data
            if let draft = pending.first(where: { $0.attachment.id == attachment.id }) { bytes = draft.data }
            else { bytes = try store.attachmentData(attachment) }
            preview = InventoryAttachmentPreview(attachment: attachment, data: bytes)
        } catch { self.error = error.localizedDescription }
    }

    private func save() {
        do {
            guard let quantity = Int(quantityText.trimmingCharacters(in: .whitespacesAndNewlines)), (0...1_000_000_000).contains(quantity) else { throw InventoryFailure.message("Enter a whole quantity from zero to one billion.") }
            let minimum = minimumText.trimmingCharacters(in: .whitespacesAndNewlines)
            if minimum.isEmpty { item.minimumStock = nil }
            else {
                guard let number = Int(minimum), (0...1_000_000_000).contains(number) else { throw InventoryFailure.message("Minimum stock must be a nonnegative whole number.") }
                item.minimumStock = number
            }
            var seen = Set<String>()
            item.tags = tagsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
            item.name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
            item.quantity = quantity; item.updatedAt = Date()
            let price = priceText.trimmingCharacters(in: .whitespacesAndNewlines)
            item.purchasePrice = price.isEmpty ? nil : price
            item.currencyCode = item.currencyCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            try store.save(item, replacing: original, added: pending)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }

    private func importFiles(_ urls: [URL]) throws {
        guard !busy, !urls.isEmpty, urls.count + item.attachments.count <= 20 else { throw InventoryFailure.message("Keep at most 20 attachments on an item.") }
        busy = true; error = nil
        let token = UUID(); generation = token
        task = Task { @MainActor in
            let worker = Task.detached(priority: .userInitiated) {
                var files: [InventoryPreparedAttachment] = [], bytes = 0
                for url in urls {
                    try Task.checkCancellation()
                    let file = try autoreleasepool { try InventoryAttachmentFiles.prepare(url) }
                    bytes += file.data.count
                    guard bytes <= InventoryValidation.maximumTotalAttachmentBytes else { throw InventoryFailure.message("The selected attachment batch exceeds 100 MB.") }
                    files.append(file)
                }
                return files
            }
            do {
                let files = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                if generation == token {
                    let bytes = item.attachments.reduce(0, { $0 + $1.byteCount }) + files.reduce(0, { $0 + $1.data.count })
                    guard bytes <= InventoryValidation.maximumTotalAttachmentBytes else { throw InventoryFailure.message("The item's attachment drafts exceed 100 MB.") }
                    item.attachments.append(contentsOf: files.map(\.attachment)); pending.append(contentsOf: files)
                }
            } catch is CancellationError {} catch { if generation == token { self.error = error.localizedDescription } }
            if generation == token { busy = false; task = nil }
        }
    }
}

private struct InventoryAttachmentViewer: View {
    let preview: InventoryAttachmentPreview
    @Environment(\.dismiss) private var dismiss
    @State private var exporting = false
    @State private var error: String?
    private var type: UTType { preview.attachment.fileExtension == "pdf" ? .pdf : preview.attachment.fileExtension == "png" ? .png : .jpeg }
    var body: some View {
        NavigationStack {
            Group {
                if preview.attachment.fileExtension == "pdf", let document = PDFDocument(data: preview.data) {
                    if document.isLocked { ContentUnavailableView("Protected receipt", systemImage: "lock.doc", description: Text("Export this receipt to open it with its password.")) }
                    else { InventoryPDFPreview(document: document) }
                } else if let source = CGImageSourceCreateWithData(preview.data as CFData, nil),
                          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 2_048] as CFDictionary) {
                    Image(decorative: image, scale: 1).resizable().scaledToFit().padding()
                } else { ContentUnavailableView("Preview unavailable", systemImage: "doc") }
            }
            .navigationTitle(preview.attachment.name).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("Export attachment", systemImage: "square.and.arrow.up") { exporting = true } }
            }
            .fileExporter(isPresented: $exporting, document: CollectionExportDocument(data: preview.data), contentType: type,
                          defaultFilename: (preview.attachment.name as NSString).deletingPathExtension + "." + preview.attachment.fileExtension) {
                if case .failure(let failure) = $0 { error = failure.localizedDescription }
            }
            .alert("Attachment export", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
        }
    }
}

private struct InventoryPDFPreview: UIViewRepresentable {
    let document: PDFDocument
    func makeUIView(context: Context) -> PDFView { let view = PDFView(); view.autoScales = true; view.document = document; return view }
    func updateUIView(_ view: PDFView, context: Context) { if view.document !== document { view.document = document } }
}
