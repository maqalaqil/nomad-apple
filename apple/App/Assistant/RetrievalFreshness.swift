import Foundation
#if canImport(NomadCore)
import NomadCore
#endif

enum RetrievalFreshness {
    /// A saved vector ranks only the exact passage it embedded. A rename may update
    /// display metadata; changed/removed text must never borrow the old vector score.
    static func currentHits(_ candidates: [SearchHit], passages: [SearchHit]) -> [SearchHit] {
        let current = Dictionary(passages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return candidates.compactMap { hit in
            guard let fresh = current[hit.id], hit.hasSourceText, fresh.hasSourceText,
                  hit.documentID == fresh.documentID, hit.excerpt == fresh.excerpt else { return nil }
            return SearchHit(id: fresh.id, documentID: fresh.documentID, documentTitle: fresh.documentTitle,
                             excerpt: fresh.excerpt, score: hit.score, hasSourceText: true)
        }
    }
}
