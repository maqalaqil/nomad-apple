import Foundation
import CryptoKit

enum InventoryFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

struct InventoryAttachment: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    let fileExtension: String
    let byteCount: Int
    let sha256: String
    let addedAt: Date
    var filename: String { id.uuidString.lowercased() + "." + fileExtension }
}

struct InventoryItem: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var location: String
    var quantity: Int
    var notes: String
    var updatedAt = Date()
    var tags: [String] = []
    var serialNumber = ""
    var model = ""
    var manufacturer = ""
    var purchaseDate: Date?
    var warrantyExpires: Date?
    var purchasePrice: String?
    var currencyCode = "USD"
    var minimumStock: Int?
    var attachments: [InventoryAttachment] = []
    var isLowStock: Bool { minimumStock.map { quantity <= $0 } ?? false }
    var searchableText: String { ([name, location, notes, serialNumber, model, manufacturer] + tags + attachments.map(\.name)).joined(separator: " ") }

    init(id: UUID = UUID(), name: String, location: String, quantity: Int, notes: String) {
        self.id = id; self.name = name; self.location = location; self.quantity = quantity; self.notes = notes
    }

    enum CodingKeys: String, CodingKey {
        case id, name, location, quantity, notes, updatedAt, tags, serialNumber, model, manufacturer,
             purchaseDate, warrantyExpires, purchasePrice, currencyCode, minimumStock, attachments
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); name = try c.decode(String.self, forKey: .name)
        location = try c.decode(String.self, forKey: .location); quantity = try c.decode(Int.self, forKey: .quantity)
        notes = try c.decode(String.self, forKey: .notes); updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        serialNumber = try c.decodeIfPresent(String.self, forKey: .serialNumber) ?? ""
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        manufacturer = try c.decodeIfPresent(String.self, forKey: .manufacturer) ?? ""
        purchaseDate = try c.decodeIfPresent(Date.self, forKey: .purchaseDate)
        warrantyExpires = try c.decodeIfPresent(Date.self, forKey: .warrantyExpires)
        purchasePrice = try c.decodeIfPresent(String.self, forKey: .purchasePrice)
        currencyCode = try c.decodeIfPresent(String.self, forKey: .currencyCode) ?? "USD"
        minimumStock = try c.decodeIfPresent(Int.self, forKey: .minimumStock)
        attachments = try c.decodeIfPresent([InventoryAttachment].self, forKey: .attachments) ?? []
    }
}

struct InventoryArchive: Codable, Equatable, Sendable {
    var version = 2
    var items: [InventoryItem]
}

struct InventoryEmbeddedFile: Codable, Sendable {
    let id: UUID
    let data: Data
}

struct InventoryPortableArchive: Codable, Sendable {
    var version = 2
    var items: [InventoryItem]
    var files: [InventoryEmbeddedFile]
    init(items: [InventoryItem], files: [InventoryEmbeddedFile]) { self.items = items; self.files = files }
    enum CodingKeys: String, CodingKey { case version, items, files }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        items = try c.decode([InventoryItem].self, forKey: .items)
        files = try c.decodeIfPresent([InventoryEmbeddedFile].self, forKey: .files) ?? []
    }
}

struct InventoryPreparedAttachment: Sendable {
    let attachment: InventoryAttachment
    let data: Data
}

enum InventoryValidation {
    static let maximumItems = 10_000
    static let maximumAttachmentBytes = 20 * 1_024 * 1_024
    static let maximumTotalAttachmentBytes = 100 * 1_024 * 1_024
    static let maximumManifestBytes = 20 * 1_024 * 1_024
    static let maximumArchiveBytes = 200 * 1_024 * 1_024
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func archive(_ archive: InventoryArchive) throws {
        guard [1, 2].contains(archive.version), archive.items.count <= maximumItems,
              Set(archive.items.map(\.id)).count == archive.items.count else { throw InventoryFailure.message("Unsupported inventory version, duplicate item IDs, or too many items.") }
        var attachmentIDs = Set<UUID>(), total = 0
        for item in archive.items {
            guard !item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  item.name.utf8.count <= 1_024, item.location.utf8.count <= 2_048,
                  item.notes.utf8.count <= 64 * 1_024, (0...1_000_000_000).contains(item.quantity),
                  item.minimumStock.map({ (0...1_000_000_000).contains($0) }) ?? true,
                  [item.serialNumber, item.model, item.manufacturer].allSatisfy({ $0.utf8.count <= 1_024 }),
                  item.updatedAt.timeIntervalSinceReferenceDate.isFinite,
                  [item.purchaseDate, item.warrantyExpires].compactMap({ $0 }).allSatisfy({ $0.timeIntervalSinceReferenceDate.isFinite }),
                  item.tags.count <= 100, Set(item.tags.map { $0.lowercased() }).count == item.tags.count,
                  item.tags.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 128 }),
                  item.currencyCode.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil,
                  item.purchasePrice.map({ $0.range(of: "^(0|[1-9][0-9]{0,11})(\\.[0-9]{1,4})?$", options: .regularExpression) != nil }) ?? true,
                  item.attachments.count <= 20 else { throw InventoryFailure.message("An inventory item contains invalid or oversized metadata. Quantities must be whole numbers from 0 to one billion; prices use up to 12 digits and 4 decimal places.") }
            for attachment in item.attachments {
                guard attachmentIDs.insert(attachment.id).inserted,
                      ["jpg", "png", "pdf"].contains(attachment.fileExtension),
                      !attachment.name.isEmpty, attachment.name.utf8.count <= 1_024,
                      attachment.byteCount > 0, attachment.byteCount <= maximumAttachmentBytes,
                      attachment.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                      attachment.addedAt.timeIntervalSinceReferenceDate.isFinite else { throw InventoryFailure.message("An attachment has an invalid identifier, format, size or checksum.") }
                total += attachment.byteCount
                guard total <= maximumTotalAttachmentBytes else { throw InventoryFailure.message("Inventory attachments exceed the 100 MB total limit.") }
            }
        }
    }

    static func portable(_ archive: InventoryPortableArchive) throws {
        try self.archive(InventoryArchive(version: archive.version, items: archive.items))
        let references = Dictionary(uniqueKeysWithValues: archive.items.flatMap(\.attachments).map { ($0.id, $0) })
        guard archive.files.count == references.count, Set(archive.files.map(\.id)).count == archive.files.count else {
            throw InventoryFailure.message("This inventory export is missing attachments or contains duplicate/extra files.")
        }
        for file in archive.files {
            guard let reference = references[file.id], file.data.count == reference.byteCount, hash(file.data) == reference.sha256 else {
                throw InventoryFailure.message("An attachment failed its length or SHA-256 check. Existing inventory was preserved.")
            }
        }
    }
}
