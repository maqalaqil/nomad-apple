import Foundation
import Observation
import CryptoKit

public struct LocalNote: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var body: String
    public let createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), title: String = "", body: String = "", createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id; self.title = title; self.body = body; self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    /// Tags remain ordinary Markdown text. Fenced, indented and inline code is excluded.
    public var tags: [String] { NoteText.tags(in: body) }

    public func validate() throws {
        guard title.utf8.count <= 2_048, body.utf8.count <= NotesArchive.maximumNoteBytes,
              !title.contains("\0"), !body.contains("\0"),
              createdAt.timeIntervalSince1970.isFinite, updatedAt.timeIntervalSince1970.isFinite,
              !(title + body).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NotesError.message("A note is blank, contains invalid text or dates, or exceeds the 2 MB text / 2 KB title limit.")
        }
    }
}

/// Existing version-1 notes decode unchanged. Trash is additive and never purged automatically.
public struct NotesArchive: Codable, Sendable {
    public static let maximumNoteBytes = 2 * 1_024 * 1_024
    public static let maximumBytes = 64 * 1_024 * 1_024
    public static let maximumNotes = 10_000
    public let formatVersion: Int
    public var notes: [LocalNote]
    public var trash: [LocalNote]
    public init(notes: [LocalNote], trash: [LocalNote] = []) { formatVersion = 1; self.notes = notes; self.trash = trash }
    private enum CodingKeys: String, CodingKey { case formatVersion, notes, trash }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try values.decode(Int.self, forKey: .formatVersion)
        notes = try values.decode([LocalNote].self, forKey: .notes)
        trash = try values.decodeIfPresent([LocalNote].self, forKey: .trash) ?? []
    }
    public func validate() throws {
        let all = notes + trash
        guard formatVersion == 1, all.count <= Self.maximumNotes, Set(all.map(\.id)).count == all.count else {
            throw NotesError.message("The notes archive has an unsupported version, duplicate identifiers, or more than 10,000 notes including trash.")
        }
        for note in all { try note.validate() }
    }
    public static func decode(_ data: Data) throws -> NotesArchive {
        guard data.count <= maximumBytes else { throw NotesError.message("The notes archive exceeds 64 MB.") }
        let value = try JSONDecoder().decode(Self.self, from: data); try value.validate(); return value
    }
}

public enum NotesError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

public struct NotesImportResult: Sendable {
    public let added: Int
    public let skipped: Int
}

@MainActor @Observable
public final class NotesStore {
    public private(set) var notes: [LocalNote] = []
    public private(set) var trash: [LocalNote] = []
    public private(set) var lastError: String?
    public private(set) var canWrite = false
    @ObservationIgnored private let rootURL: URL
    @ObservationIgnored private var manifestDigest: SHA256.Digest?
    private var manifestURL: URL { rootURL.appendingPathComponent("notes.json") }

    public init(rootURL: URL? = nil) {
        self.rootURL = rootURL ?? LocalStorage.defaultRoot(component: "Notes")
        reload()
    }

    public func reload() {
        canWrite = false
        do {
            try prepareRoot()
            let data = try readManifest()
            let archive = try data.map(NotesArchive.decode) ?? NotesArchive(notes: [])
            notes = sorted(archive.notes); trash = sorted(archive.trash)
            manifestDigest = data.map { SHA256.hash(data: $0) }
            lastError = nil; canWrite = true
        } catch { lastError = "Saved notes were preserved but could not be opened. \(error.localizedDescription)" }
    }

    /// Existing callers compare the draft's original updatedAt. Editors should also pass their original
    /// record so an edit cannot recreate a note that was removed while the editor was open.
    @discardableResult public func save(_ note: LocalNote, replacing original: LocalNote? = nil) throws -> LocalNote {
        try note.validate()
        var next = note
        if next.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            next.title = String(note.body.split(separator: "\n").first?.prefix(80) ?? "Untitled")
        }
        if let current = notes.first(where: { $0.id == note.id }) {
            guard current.updatedAt == note.updatedAt, current.createdAt == note.createdAt,
                  original == nil || original == current else { throw conflict() }
        } else if original != nil || trash.contains(where: { $0.id == note.id }) { throw conflict() }
        try next.validate()
        next.updatedAt = Date(timeIntervalSince1970: max(Date().timeIntervalSince1970, note.updatedAt.timeIntervalSince1970 + 0.000_001))
        try persist(notes: notes.filter { $0.id != note.id } + [next], trash: trash)
        return next
    }

    public func delete(_ note: LocalNote) throws {
        guard notes.first(where: { $0.id == note.id }) == note else { throw conflict() }
        try persist(notes: notes.filter { $0.id != note.id }, trash: trash + [note])
    }

    public func restore(_ note: LocalNote) throws {
        guard trash.first(where: { $0.id == note.id }) == note else { throw conflict() }
        try persist(notes: notes + [note], trash: trash.filter { $0.id != note.id })
    }

    public func permanentlyDelete(_ note: LocalNote) throws {
        guard trash.first(where: { $0.id == note.id }) == note else { throw conflict() }
        try persist(notes: notes, trash: trash.filter { $0.id != note.id })
    }

    public func exportArchive() throws -> Data {
        try requireUnchangedManifest()
        return try encoded(NotesArchive(notes: notes, trash: trash))
    }

    /// Imports are additive. Exact text duplicates are skipped; conflicting IDs are assigned new IDs.
    /// Existing notes and trash are never overwritten by an imported archive.
    public func importArchive(_ archive: NotesArchive) throws -> NotesImportResult {
        try archive.validate()
        var active = notes, deleted = trash, ids = Set((notes + trash).map(\.id))
        var fingerprints = Set((notes + trash).map(contentFingerprint))
        var added = 0, skipped = 0
        for (values, isTrash) in [(archive.notes, false), (archive.trash, true)] {
            for note in values {
                guard fingerprints.insert(contentFingerprint(note)).inserted else { skipped += 1; continue }
                let value = ids.contains(note.id) ? LocalNote(title: note.title, body: note.body, createdAt: note.createdAt, updatedAt: note.updatedAt) : note
                ids.insert(value.id)
                if isTrash { deleted.append(value) } else { active.append(value) }; added += 1
            }
        }
        try persist(notes: active, trash: deleted)
        return NotesImportResult(added: added, skipped: skipped)
    }

    public nonisolated static func markdownNote(data: Data, filename: String) throws -> LocalNote {
        guard data.count <= NotesArchive.maximumNoteBytes, ["md", "markdown", "txt"].contains((filename as NSString).pathExtension.lowercased()),
              let text = String(data: data, encoding: .utf8) else {
            throw NotesError.message("Choose a UTF-8 .md, .markdown or .txt file no larger than 2 MB.")
        }
        let body = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        let note = LocalNote(title: (filename as NSString).deletingPathExtension, body: body)
        try note.validate(); return note
    }

    public var allTags: [String] { Array(Set(notes.flatMap(\.tags))).sorted() }
    public func search(_ query: String) throws -> [LocalNote] {
        let filter = try NoteQuery(query)
        return notes.filter { filter.matches($0) }
    }
    public func linkedNotes(title: String) -> [LocalNote] {
        notes.filter { $0.title.compare(title, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }

    private func contentFingerprint(_ note: LocalNote) -> String {
        // Length-prefix prevents ambiguity between titles and body text.
        SHA256.hash(data: Data("\(note.title.utf8.count):\(note.title)\(note.body)".utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func conflict() -> NotesError { .message("This note changed or was removed after you opened it. Keep your draft, reload the notebook, and reopen the current note, or save the draft as a new copy.") }
    private func sorted(_ values: [LocalNote]) -> [LocalNote] { values.sorted { $0.updatedAt == $1.updatedAt ? $0.id.uuidString < $1.id.uuidString : $0.updatedAt > $1.updatedAt } }
    private func encoded(_ archive: NotesArchive) throws -> Data {
        try archive.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(archive)
        guard data.count <= NotesArchive.maximumBytes else { throw NotesError.message("Notes and trash exceed the 64 MB notebook limit. Export and permanently remove unwanted notes.") }
        return data
    }
    private func persist(notes: [LocalNote], trash: [LocalNote]) throws {
        do {
            let data = try encoded(NotesArchive(notes: notes, trash: trash))
            try requireUnchangedManifest()
            try data.write(to: manifestURL, options: .atomic)
            self.notes = sorted(notes); self.trash = sorted(trash); manifestDigest = SHA256.hash(data: data); lastError = nil
        } catch { lastError = error.localizedDescription; throw error }
    }
    private func requireUnchangedManifest() throws {
        guard canWrite else { throw NotesError.message(lastError ?? "Reload the preserved notes file before making changes.") }
        guard try readManifest().map({ SHA256.hash(data: $0) }) == manifestDigest else {
            throw NotesError.message("The notebook changed in another operation. Reload it before saving. The newer file was preserved.")
        }
    }
    private func prepareRoot() throws {
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: rootURL.path) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
            try LocalStorage.prepare(rootURL)
            guard try FileManager.default.attributesOfItem(atPath: rootURL.path)[.type] as? FileAttributeType == .typeDirectory else { throw NotesError.message("The Notes storage root is not a regular directory.") }
            return
        }
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw NotesError.message("The Notes storage root is unsafe. Symbolic links are not followed.") }
    }
    private func readManifest() throws -> Data? {
        guard try FileManager.default.attributesOfItem(atPath: rootURL.path)[.type] as? FileAttributeType == .typeDirectory else { throw NotesError.message("The Notes storage root changed or is unsafe.") }
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: manifestURL.path) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { return nil }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let count = attributes[.size] as? NSNumber, count.int64Value >= 0, count.int64Value <= NotesArchive.maximumBytes else {
            throw NotesError.message("The notes file is unsafe or too large. Symbolic links are not followed.")
        }
        let data = try Data(contentsOf: manifestURL)
        guard data.count <= NotesArchive.maximumBytes else { throw NotesError.message("The notes file exceeds 64 MB.") }
        return data
    }
}

/// Markdown-aware tag scanning shared by search and the UI; never changes stored Markdown.
public enum NoteText {
    public static func tags(in body: String) -> [String] {
        var found = Set<String>(), fence: Character?, fenceLength = 0
        let expression = try! NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}\\p{M}_#])#([\\p{L}\\p{N}\\p{M}_-]+)")
        for raw in body.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let marker = line.first, marker == "`" || marker == "~" {
                let count = line.prefix(while: { $0 == marker }).count
                if count >= 3 {
                    if fence == marker, count >= fenceLength, line.dropFirst(count).trimmingCharacters(in: .whitespaces).isEmpty { fence = nil }
                    else if fence == nil { fence = marker; fenceLength = count }
                    continue
                }
            }
            guard fence == nil, !raw.hasPrefix("    "), !raw.hasPrefix("\t") else { continue }
            let plain = removingInlineCode(line)
            for match in expression.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) {
                if let range = Range(match.range(at: 1), in: plain) { found.insert(String(plain[range]).lowercased()) }
            }
        }
        return found.sorted()
    }
    private static func removingInlineCode(_ text: String) -> String {
        var output = "", index = text.startIndex
        while index < text.endIndex {
            guard text[index] == "`" else { output.append(text[index]); index = text.index(after: index); continue }
            let start = index
            while index < text.endIndex, text[index] == "`" { index = text.index(after: index) }
            let delimiter = String(text[start..<index])
            if let end = text.range(of: delimiter, range: index..<text.endIndex) { output += " "; index = end.upperBound }
            else { output += delimiter }
        }
        return output
    }
}

/// A bounded, explicit subset of Flatnotes search. Unsupported syntax is rejected, never silently ignored.
public struct NoteQuery: Sendable {
    private struct Term: Sendable { let field: String; let value: String; let negated: Bool }
    private let groups: [[Term]]
    public init(_ query: String) throws {
        guard query.count <= 1_024 else { throw NotesError.message("Use a search query of at most 1,024 characters.") }
        var tokens: [String] = [], token = "", quoted = false
        for character in query {
            if character == "\"" { quoted.toggle(); token.append(character) }
            else if character.isWhitespace && !quoted { if !token.isEmpty { tokens.append(token); token = "" } }
            else { token.append(character) }
        }
        guard !quoted else { throw NotesError.message("Close the quoted search phrase.") }
        if !token.isEmpty { tokens.append(token) }
        guard tokens.count <= 64 else { throw NotesError.message("Use at most 64 search terms and operators.") }
        var groups: [[Term]] = [[]], negate = false, awaitingTerm = false
        for token in tokens {
            if token == "OR" {
                guard !groups[groups.count - 1].isEmpty, !awaitingTerm else { throw NotesError.message("OR needs a search term on both sides.") }
                groups.append([]); awaitingTerm = true; continue
            }
            if token == "AND" {
                guard !groups[groups.count - 1].isEmpty, !awaitingTerm else { throw NotesError.message("AND needs a search term on both sides.") }
                awaitingTerm = true; continue
            }
            if token == "NOT" { guard !negate else { throw NotesError.message("Put a search term after NOT.") }; negate = true; awaitingTerm = true; continue }
            var field = "", value = token
            if token.hasPrefix("#") { field = "tags"; value = String(token.dropFirst()) }
            else if !token.hasPrefix("\""), let colon = token.firstIndex(of: ":") {
                field = String(token[..<colon]); value = String(token[token.index(after: colon)...])
                guard ["title", "content", "tags"].contains(field) else { throw NotesError.message("Supported fields are title:, content: and tags:. Use the sort menu for dates.") }
            }
            if value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
            guard !value.isEmpty, !value.contains("\""), !value.contains("("), !value.contains(")"), !value.contains("["), !value.contains("]") else {
                throw NotesError.message("Use words, quoted phrases, #tags, title:, content:, tags:, AND, OR or NOT. Grouping and date ranges are not supported.")
            }
            groups[groups.count - 1].append(Term(field: field, value: value, negated: negate)); negate = false; awaitingTerm = false
        }
        guard !awaitingTerm else { throw NotesError.message("Finish the query with a search term.") }
        self.groups = groups
    }
    public func matches(_ note: LocalNote) -> Bool {
        groups.contains { group in
            group.allSatisfy { term in
                let values: [String]
                switch term.field { case "title": values = [note.title]; case "content": values = [note.body]; case "tags": values = note.tags; default: values = [note.title, note.body] }
                let match = values.contains { value in
                    if term.value.contains("*") || term.value.contains("?") {
                        // Wildcards match individual whitespace-delimited words; bounded glob avoids regex construction.
                        return value.split(whereSeparator: \.isWhitespace).contains { Self.glob(term.value, String($0)) }
                    }
                    if term.field == "tags" { return value.compare(term.value, options: .caseInsensitive) == .orderedSame }
                    return value.range(of: term.value, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                }
                return term.negated ? !match : match
            }
        }
    }
    private static func glob(_ pattern: String, _ text: String) -> Bool {
        let pattern = Array(pattern.lowercased()), text = Array(text.lowercased())
        // Classic greedy glob: no regex construction/backtracking and constant auxiliary storage.
        var p = 0, t = 0, star: Int?, consumed = 0
        while t < text.count {
            if p < pattern.count, pattern[p] == "?" || (p < pattern.count && pattern[p] == text[t]) { p += 1; t += 1 }
            else if p < pattern.count, pattern[p] == "*" { star = p; p += 1; consumed = t }
            else if let star { consumed += 1; t = consumed; p = star + 1 }
            else { return false }
        }
        while p < pattern.count, pattern[p] == "*" { p += 1 }
        return p == pattern.count
    }
}

/// Common block Markdown used by the native read-only preview. Unsupported syntax remains visible text.
public enum NoteMarkdownBlock: Equatable, Sendable {
    case heading(Int, String), code(String), quote(String), list(String, String), paragraph(String), rule
    public static func parse(_ text: String) -> [NoteMarkdownBlock] {
        var blocks: [NoteMarkdownBlock] = [], paragraph: [String] = [], code: [String] = []
        var fence: Character?, fenceLength = 0
        func flush() { if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] } }
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let marker = line.first, marker == "`" || marker == "~" {
                let count = line.prefix(while: { $0 == marker }).count
                if count >= 3 {
                    if fence == marker, count >= fenceLength, line.dropFirst(count).trimmingCharacters(in: .whitespaces).isEmpty {
                        blocks.append(.code(code.joined(separator: "\n"))); code = []; fence = nil; continue
                    } else if fence == nil { flush(); fence = marker; fenceLength = count; continue }
                }
            }
            if fence != nil { code.append(raw); continue }
            if line.isEmpty { flush(); continue }
            if raw.hasPrefix("    ") || raw.hasPrefix("\t") { flush(); blocks.append(.code(String(raw.dropFirst(raw.hasPrefix("\t") ? 1 : 4)))); continue }
            let heading = line.prefix(while: { $0 == "#" }).count
            if (1...6).contains(heading), line.dropFirst(heading).first == " " {
                flush(); blocks.append(.heading(heading, String(line.dropFirst(heading + 1)))); continue
            }
            if ["---", "***", "___"].contains(line.replacingOccurrences(of: " ", with: "")) { flush(); blocks.append(.rule); continue }
            if line.hasPrefix(">") { flush(); blocks.append(.quote(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))); continue }
            if ["- ", "* ", "+ "].contains(String(line.prefix(2))) {
                flush(); let value = String(line.dropFirst(2))
                if value.hasPrefix("[ ] ") { blocks.append(.list("☐", String(value.dropFirst(4)))) }
                else if value.lowercased().hasPrefix("[x] ") { blocks.append(.list("☑", String(value.dropFirst(4)))) }
                else { blocks.append(.list("•", value)) }; continue
            }
            let digits = line.prefix(while: \.isNumber)
            if !digits.isEmpty, digits.count <= 9, line.dropFirst(digits.count).hasPrefix(". ") {
                flush(); blocks.append(.list(String(digits) + ".", String(line.dropFirst(digits.count + 2)))); continue
            }
            paragraph.append(raw)
        }
        if fence != nil { blocks.append(.code(code.joined(separator: "\n"))) }; flush(); return blocks
    }
}
