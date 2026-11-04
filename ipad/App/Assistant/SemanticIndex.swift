import Foundation
import NaturalLanguage
import Observation

struct KnowledgeCollection: Codable, Identifiable {
    var id = UUID()
    var name: String
    var documentIDs: Set<UUID>
    var enabled = true
}

struct SemanticPassage: Codable, Identifiable, Sendable {
    let id: String
    let documentID: UUID
    let title: String
    let text: String
    let vector: [Double]
}

struct SemanticSnapshot: Codable, Sendable {
    let version: Int
    let language: String
    let revision: Int
    let dimension: Int
    let createdAt: Date
    let documentIDs: Set<UUID>
    let passages: [SemanticPassage]
}

private enum SemanticError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}

/// All Natural Language model access runs on this actor, outside the UI actor.
actor SemanticEngine {
    static let shared = SemanticEngine()

    func build(_ passages: [SearchHit], language: String, progress: @Sendable (Int) async -> Void) async throws -> SemanticSnapshot {
        guard !passages.isEmpty else { throw SemanticError.message("No extracted document text is selected. Import PDF or text files first.") }
        guard let model = NLEmbedding.sentenceEmbedding(for: NLLanguage(rawValue: language)) else {
            throw SemanticError.message("The system sentence-embedding model for this language is unavailable on this device. Lexical search remains available.")
        }
        var result: [SemanticPassage] = []
        for (index, passage) in passages.enumerated() {
            try Task.checkCancellation()
            guard let vector = model.vector(for: passage.excerpt), vector.count == model.dimension,
                  vector.allSatisfy(\.isFinite) else {
                throw SemanticError.message("An embedding could not be generated. The previous index has been preserved.")
            }
            result.append(SemanticPassage(id: passage.id, documentID: passage.documentID,
                                          title: passage.documentTitle, text: passage.excerpt, vector: vector))
            if index % 10 == 0 { await progress(index + 1) }
        }
        try Task.checkCancellation()
        await progress(passages.count)
        return SemanticSnapshot(version: 1, language: language, revision: model.revision, dimension: model.dimension,
                                createdAt: Date(), documentIDs: Set(passages.map(\.documentID)), passages: result)
    }

    func search(_ query: String, snapshot: SemanticSnapshot, allowed: Set<UUID>, limit: Int = 12) throws -> [SearchHit] {
        guard let model = NLEmbedding.sentenceEmbedding(for: NLLanguage(rawValue: snapshot.language), revision: snapshot.revision),
              model.dimension == snapshot.dimension, let queryVector = model.vector(for: query),
              queryVector.count == snapshot.dimension, queryVector.allSatisfy(\.isFinite) else {
            throw SemanticError.message("The embedding model used for this index is unavailable. Rebuild the index or choose lexical retrieval.")
        }
        let queryNorm = sqrt(queryVector.reduce(0) { $0 + $1 * $1 })
        guard queryNorm > 0 else { return [] }
        var hits: [SearchHit] = []
        for passage in snapshot.passages where allowed.contains(passage.documentID) {
            try Task.checkCancellation()
            let norm = sqrt(passage.vector.reduce(0) { $0 + $1 * $1 })
            guard norm > 0 else { continue }
            let score = zip(queryVector, passage.vector).reduce(0) { $0 + $1.0 * $1.1 } / (queryNorm * norm)
            guard score.isFinite, score > 0 else { continue }
            hits.append(SearchHit(id: passage.id, documentID: passage.documentID, documentTitle: passage.title, excerpt: passage.text, score: score))
        }
        return Array(hits.sorted { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }.prefix(limit))
    }
}

@MainActor @Observable
final class SemanticIndexStore {
    static let shared = SemanticIndexStore()
    private(set) var snapshot: SemanticSnapshot?
    private(set) var collections: [KnowledgeCollection] = []
    private(set) var error: String?
    private(set) var progress = 0
    private(set) var total = 0
    private(set) var busy = false
    private(set) var message: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var indexFile = LocalManifestFile(url: URL.applicationSupportDirectory.appendingPathComponent("NomadPad/Knowledge/index.json"))
    @ObservationIgnored private var collectionFile = LocalManifestFile(url: URL.applicationSupportDirectory.appendingPathComponent("NomadPad/Knowledge/collections.json"))

    private init() { reload() }
    var writable: Bool { indexFile.isReady && collectionFile.isReady }

    func reload() {
        guard !busy else { return }
        do {
            snapshot = try indexFile.load(SemanticSnapshot.self) { value in
                guard value.version == 1, value.dimension > 0, value.dimension <= 4_096,
                      value.passages.count <= 4_000, Set(value.passages.map(\.id)).count == value.passages.count,
                      value.passages.allSatisfy({ $0.vector.count == value.dimension && $0.vector.allSatisfy(\.isFinite) && value.documentIDs.contains($0.documentID) }) else {
                    throw SemanticError.message("The saved semantic index is invalid.")
                }
            }
            collections = try collectionFile.load([KnowledgeCollection].self) { value in
                guard value.count <= 100, Set(value.map(\.id)).count == value.count,
                      value.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                    throw SemanticError.message("The saved collection list is invalid.")
                }
            } ?? []
            error = nil
        } catch { self.error = "Knowledge data could not be opened. The original files are preserved. \(error.localizedDescription)" }
    }

    func allowedDocuments(in library: LibraryStore) -> Set<UUID> {
        let existing = Set(library.documents.map(\.id))
        guard !collections.isEmpty else { return existing }
        return collections.filter(\.enabled).reduce(into: Set<UUID>()) { $0.formUnion($1.documentIDs) }.intersection(existing)
    }

    func saveCollection(_ collection: KnowledgeCollection) throws {
        var updated = collections
        guard updated.count < 100 || updated.contains(where: { $0.id == collection.id }) else { throw SemanticError.message("The collection limit is 100.") }
        guard !collection.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SemanticError.message("Give the collection a name.") }
        if let index = updated.firstIndex(where: { $0.id == collection.id }) { updated[index] = collection }
        else { updated.append(collection) }
        try collectionFile.save(updated)
        collections = updated
    }

    func deleteCollection(_ id: UUID) throws {
        let updated = collections.filter { $0.id != id }
        try collectionFile.save(updated)
        collections = updated
    }

    func rebuild(passages: [SearchHit], language: String) {
        guard !busy, writable else { return }
        guard passages.count <= 4_000 else {
            error = "This index supports up to 4,000 passages. Select a smaller collection before rebuilding; no content was silently omitted."
            return
        }
        busy = true; progress = 0; total = passages.count; error = nil; message = nil
        task = Task {
            defer { busy = false; task = nil }
            do {
                let built = try await SemanticEngine.shared.build(passages, language: language) { count in
                    await MainActor.run { self.progress = count }
                }
                try Task.checkCancellation()
                try indexFile.save(built)
                snapshot = built
                message = "Indexed \(built.passages.count) passages from \(built.documentIDs.count) documents."
            } catch is CancellationError { message = "Indexing stopped. The previous index is preserved." }
            catch { self.error = error.localizedDescription }
        }
    }
    func cancel() { task?.cancel() }

    func search(_ query: String, library: LibraryStore, semantic: Bool) async throws -> [SearchHit] {
        guard writable else { throw SemanticError.message(error ?? "Knowledge storage is unavailable.") }
        let allowed = allowedDocuments(in: library)
        let lexical = library.search(query, documentIDs: allowed).filter(\.hasSourceText)
        guard semantic else { return lexical }
        guard let snapshot else { throw SemanticError.message("Build the semantic index in Knowledge Collections first, or choose lexical retrieval.") }
        let semanticHits = try await SemanticEngine.shared.search(query, snapshot: snapshot, allowed: allowed)
        try Task.checkCancellation()
        let stillAllowed = allowedDocuments(in: library)
        let candidateDocuments = Set(semanticHits.map(\.documentID)).intersection(stillAllowed)
        let currentPassages = library.retrievalPassages(documentIDs: candidateDocuments)
        let currentSemantic = RetrievalFreshness.currentHits(semanticHits, passages: currentPassages)
        // Library records and titles may change while the embedding actor is working.
        let currentLexical = library.search(query, documentIDs: stillAllowed).filter(\.hasSourceText)
        if currentSemantic.count < semanticHits.count {
            message = "Changed or unavailable semantic passages were excluded. Rebuild the index to include the latest document text."
            if currentSemantic.isEmpty && currentLexical.isEmpty {
                throw SemanticError.message("The matching indexed passages changed or were removed. Rebuild the index in Knowledge Collections, or use current keyword retrieval.")
            }
        }
        // Reciprocal-rank fusion keeps cosine scores and lexical term scores on comparable footing.
        var ranked: [String: (SearchHit, Double)] = [:]
        for list in [currentSemantic, currentLexical] {
            for (rank, hit) in list.enumerated() where stillAllowed.contains(hit.documentID) {
                let score = (ranked[hit.id]?.1 ?? 0) + 1 / Double(60 + rank + 1)
                ranked[hit.id] = (hit, score)
            }
        }
        return ranked.values.sorted { $0.1 == $1.1 ? $0.0.id < $1.0.id : $0.1 > $1.1 }.map(\.0)
    }
}
