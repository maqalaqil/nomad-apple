#if NOMAD_SEMANTIC_ENGINE_TESTS
import Foundation

@main
struct SemanticEngineTests {
    static func main() async throws {
        let waterID = UUID(), musicID = UUID()
        let passages = [
            SearchHit(id: "water-0", documentID: waterID, documentTitle: "TEST water", excerpt: "Boiling water kills disease-causing organisms. Bring drinking water to a rolling boil before cooling it in a clean container.", score: 0),
            SearchHit(id: "music-0", documentID: musicID, documentTitle: "TEST music", excerpt: "An electric guitar has six strings. Chords combine notes while amplifiers make the music louder.", score: 0)
        ]
        let snapshot = try await SemanticEngine.shared.build(passages, language: "en") { _ in }
        precondition(snapshot.passages.count == 2 && snapshot.dimension > 0)
        precondition(snapshot.documentIDs == [waterID, musicID])
        precondition(snapshot.passages.allSatisfy { $0.vector.count == snapshot.dimension && $0.vector.allSatisfy(\.isFinite) })
        let hits = try await SemanticEngine.shared.search("How can I make drinking water safe?", snapshot: snapshot, allowed: [waterID, musicID])
        precondition(hits.first?.documentID == waterID, "Actual semantic retrieval did not rank the related passage first.")
        precondition(hits.first?.excerpt == passages[0].excerpt)
        let removed = try await SemanticEngine.shared.search("How can I make drinking water safe?", snapshot: snapshot, allowed: [musicID])
        precondition(removed.allSatisfy { $0.documentID != waterID }, "A removed source leaked into results.")
        let empty = try await SemanticEngine.shared.search("water", snapshot: snapshot, allowed: [])
        precondition(empty.isEmpty)
        let data = try JSONEncoder().encode(snapshot)
        let restored = try JSONDecoder().decode(SemanticSnapshot.self, from: data)
        let afterRestart = try await SemanticEngine.shared.search("How can I make drinking water safe?", snapshot: restored, allowed: [waterID])
        precondition(afterRestart.first?.id == "water-0" && afterRestart.first?.documentTitle == "TEST water")
        let canceled = Task { try await SemanticEngine.shared.build(passages, language: "en") { _ in } }
        canceled.cancel()
        do { _ = try await canceled.value; preconditionFailure("Canceled indexing unexpectedly succeeded.") }
        catch is CancellationError { }
        do { _ = try await SemanticEngine.shared.build([], language: "en") { _ in }; preconditionFailure("Empty index unexpectedly succeeded.") }
        catch { precondition(!(error is CancellationError)) }
        print("PASS: real sentence embeddings, ranking, source fidelity, active-source filtering, persisted-index retrieval, cancellation, and empty-input rejection.")
    }
}
#endif
