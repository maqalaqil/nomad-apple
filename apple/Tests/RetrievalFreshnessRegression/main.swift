import Foundation

@main struct RetrievalFreshnessRegression {
    static func main() {
        let document = UUID()
        func hit(_ id: String = "p-0", text: String = "Current passage", title: String = "Title", doc: UUID? = nil, source: Bool = true) -> SearchHit {
            SearchHit(id: id, documentID: doc ?? document, documentTitle: title, excerpt: text, score: 0.75, hasSourceText: source)
        }
        let old = hit(title: "Old title")
        let renamed = RetrievalFreshness.currentHits([old], passages: [hit(title: "New title")])
        precondition(renamed.count == 1 && renamed[0].documentTitle == "New title" && renamed[0].score == old.score)
        precondition(RetrievalFreshness.currentHits([old], passages: [hit(text: "Replacement content")]).isEmpty)
        precondition(RetrievalFreshness.currentHits([old], passages: []).isEmpty)
        precondition(RetrievalFreshness.currentHits([old], passages: [hit(doc: UUID())]).isEmpty)
        precondition(RetrievalFreshness.currentHits([old], passages: [hit(source: false)]).isEmpty)
        precondition(RetrievalFreshness.currentHits([hit(source: false)], passages: [hit()]).isEmpty)
        let kept = RetrievalFreshness.currentHits([old, hit("p-1", text: "Withdrawn")], passages: [hit(), hit("p-1", text: "New source")])
        precondition(kept.count == 1 && kept[0].id == old.id)
        precondition(RetrievalFreshness.currentHits([old], passages: [hit("other-id")]).isEmpty)
        print("PASS: 8 retrieval freshness checks for renamed, changed, removed and excluded source passages")
    }
}
