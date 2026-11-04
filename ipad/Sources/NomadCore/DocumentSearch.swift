import Foundation

/// Local lexical retrieval. It returns source excerpts, never generated answers.
public enum DocumentSearch {
    private static let stopWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "by", "can", "do", "does", "for", "from",
        "how", "i", "in", "is", "it", "of", "on", "or", "the", "this", "to", "was", "what", "when",
        "where", "which", "who", "with", "you", "your"
    ]

    public static func terms(in text: String) -> Set<String> {
        Set(text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !stopWords.contains($0) })
    }

    static func search(_ query: String, records: [LibraryRecord], limit: Int = 30) -> [SearchHit] {
        let requested = terms(in: query)
        guard !requested.isEmpty else { return [] }
        var hits: [SearchHit] = []
        for record in records {
            let titleTerms = terms(in: record.document.title)
            let titleMatches = requested.intersection(titleTerms).count
            let chunks = passages(from: record.searchableText)
            var documentHits: [SearchHit] = []
            for (index, passage) in chunks.enumerated() {
                let matched = requested.intersection(terms(in: passage)).count
                guard matched > 0 else { continue }
                let coverage = Double(matched) / Double(requested.count)
                let score = coverage * 10 + Double(titleMatches) * 2
                documentHits.append(SearchHit(id: "\(record.document.id)-\(index)", documentID: record.document.id,
                    documentTitle: record.document.title, excerpt: passage, score: score))
            }
            if documentHits.isEmpty, titleMatches > 0 {
                documentHits.append(SearchHit(id: "\(record.document.id)-title", documentID: record.document.id,
                    documentTitle: record.document.title,
                    excerpt: chunks.first ?? "Title match. This file has no searchable text index.",
                    score: Double(titleMatches) / Double(requested.count) * 4, hasSourceText: !chunks.isEmpty))
            }
            hits.append(contentsOf: documentHits.sorted { $0.score > $1.score }.prefix(3))
        }
        return Array(hits.sorted {
            if $0.score == $1.score { return $0.id < $1.id }
            return $0.score > $1.score
        }.prefix(limit))
    }

    static func passages(from text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let words = text.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return [] }
        var result: [String] = []
        let window = 120
        let overlap = 25
        var start = 0
        while start < words.count {
            let end = min(start + window, words.count)
            result.append(words[start..<end].joined(separator: " "))
            if end == words.count { break }
            start = end - overlap
        }
        return result
    }
}
