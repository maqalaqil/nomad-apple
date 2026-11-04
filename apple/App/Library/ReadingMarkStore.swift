import Foundation
import Observation
import CryptoKit

struct ReadingMark: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let bookKey: String
    let bookTitle: String
    let chapterPath: String
    let fragment: String?
    let fraction: Double
    var title: String
    var quote: String
    var note: String
    let createdAt: Date
    var updatedAt: Date

    func validate() throws {
        guard !bookKey.isEmpty, bookKey.utf8.count <= 255, !bookKey.contains("/"), !bookKey.contains("\\"), !bookKey.contains("\0"),
              !bookTitle.isEmpty, bookTitle.count <= 512, !chapterPath.isEmpty, chapterPath.utf8.count <= 4_096,
              !chapterPath.hasPrefix("/"), !chapterPath.contains("\\"), !chapterPath.contains("\0"),
              !chapterPath.split(separator: "/").contains(".."), (fragment?.utf8.count ?? 0) <= 2_048,
              fraction.isFinite, (0...1).contains(fraction), !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title.count <= 200, quote.count <= 4_000, note.count <= 8_000,
              createdAt.timeIntervalSince1970.isFinite, updatedAt.timeIntervalSince1970.isFinite else {
            throw ReadingMarkError.message("The reading mark has an invalid location or exceeds its text limits.")
        }
    }
}

enum ReadingMarkError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}

@MainActor @Observable
final class ReadingMarkStore {
    static let shared = ReadingMarkStore()
    private(set) var marks: [ReadingMark] = []
    private(set) var error: String?
    private(set) var canWrite = false
    let root: URL
    private var manifest: URL { root.appendingPathComponent("marks.json") }
    private let maximumBytes = 32 * 1_024 * 1_024
    @ObservationIgnored private var manifestDigest: SHA256.Digest?
    init(rootURL: URL? = nil) {
        root = rootURL ?? URL.applicationSupportDirectory.appendingPathComponent("NomadPad/ReadingAnnotations", isDirectory: true)
        reload()
    }
    func reload() {
        canWrite = false
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if let data = try readManifest() {
                let loaded = try JSONDecoder().decode([ReadingMark].self, from: data)
                try validate(loaded)
                marks = loaded
                manifestDigest = SHA256.hash(data: data)
            } else { marks = []; manifestDigest = nil }
            canWrite = true; error = nil
        } catch { self.error = "Saved reading marks could not be opened. The original data was preserved. \(error.localizedDescription)" }
    }
    func forBook(_ key: String) -> [ReadingMark] { marks.filter { $0.bookKey == key }.sorted { $0.createdAt > $1.createdAt } }
    func save(_ mark: ReadingMark, expectedUpdatedAt: Date? = nil) throws {
        try mark.validate()
        var updated = marks
        if let index = updated.firstIndex(where: { $0.id == mark.id }) {
            guard expectedUpdatedAt == updated[index].updatedAt else {
                throw ReadingMarkError.message("This note changed after it was opened. Reopen it before saving so the newer text is preserved.")
            }
            guard updated[index].bookKey == mark.bookKey, updated[index].chapterPath == mark.chapterPath,
                  updated[index].fragment == mark.fragment, updated[index].fraction == mark.fraction else {
                throw ReadingMarkError.message("A saved mark's original book location cannot be replaced while editing its note.")
            }
            updated[index] = mark
        } else {
            guard expectedUpdatedAt == nil else { throw ReadingMarkError.message("This note was removed after it was opened. The stale edit was not recreated.") }
            updated.append(mark)
        }
        try persist(updated); marks = updated
    }
    func delete(_ id: UUID, expectedUpdatedAt: Date? = nil) throws {
        guard let existing = marks.first(where: { $0.id == id }) else { return }
        guard existing.updatedAt == expectedUpdatedAt else { throw ReadingMarkError.message("This note changed after deletion was requested. Review the current note before deleting it.") }
        let updated = marks.filter { $0.id != id }
        try persist(updated); marks = updated
    }
    func export(bookKey: String? = nil) throws -> Data {
        guard canWrite else { throw ReadingMarkError.message(error ?? "Saved reading marks are unavailable.") }
        try requireUnchangedManifest()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(bookKey.map(forBook) ?? marks)
    }
    private func validate(_ values: [ReadingMark]) throws {
        guard values.count <= 2_000, Set(values.map(\.id)).count == values.count else { throw ReadingMarkError.message("Reading marks contain duplicate IDs or exceed the 2,000-mark limit.") }
        for value in values { try value.validate() }
    }
    private func persist(_ values: [ReadingMark]) throws {
        guard canWrite else { throw ReadingMarkError.message(error ?? "Unreadable reading notes were preserved; reload them before making changes.") }
        try validate(values)
        try requireUnchangedManifest()
        let data = try JSONEncoder().encode(values)
        guard data.count <= maximumBytes else { throw ReadingMarkError.message("Reading notes exceed their storage limit.") }
        try data.write(to: manifest, options: .atomic)
        manifestDigest = SHA256.hash(data: data)
    }
    private func requireUnchangedManifest() throws {
        let current = try readManifest().map { SHA256.hash(data: $0) }
        guard current == manifestDigest else { throw ReadingMarkError.message("Saved reading marks changed in another operation. Reload them before editing; the newer file was preserved.") }
    }
    private func readManifest() throws -> Data? {
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: manifest.path) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { return nil }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let count = attributes[.size] as? NSNumber, count.int64Value >= 0, count.int64Value <= maximumBytes else {
            throw ReadingMarkError.message("The reading notes file is unsafe or too large; symbolic links are not followed.")
        }
        let data = try Data(contentsOf: manifest)
        guard data.count <= maximumBytes else { throw ReadingMarkError.message("The reading notes file exceeds its storage limit.") }
        return data
    }
}
