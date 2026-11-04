import Foundation

/// Query-only state. Nothing is added to the installed dataset or its metadata format.
struct DrugSituationSelection: Hashable, Sendable {
    static let maximumGroups = 8
    var conditionIDs = Set<String>()
    var customTerms: [String] = []
    var count: Int { conditionIDs.count + customTerms.count }
    var conditions: [DrugCondition] { DrugConditionCatalog.conditions.filter { conditionIDs.contains($0.id) } }

    mutating func toggle(_ id: String) throws {
        guard DrugConditionCatalog.conditions.contains(where: { $0.id == id }) else { throw DrugReferenceError.message("Unknown situation search group.") }
        if conditionIDs.contains(id) { conditionIDs.remove(id); return }
        guard count < Self.maximumGroups else { throw DrugReferenceError.message("Select up to eight situation or custom text groups.") }
        conditionIDs.insert(id)
    }
    mutating func addCustom(_ raw: String) throws {
        let term = try Self.normalized([[raw]])[0][0]
        guard !customTerms.contains(where: { $0.caseInsensitiveCompare(term) == .orderedSame }) else { throw DrugReferenceError.message("That custom text group is already selected.") }
        guard count < Self.maximumGroups else { throw DrugReferenceError.message("Select up to eight situation or custom text groups.") }
        customTerms.append(term)
    }
    func termGroups() throws -> [[String]] {
        guard count <= Self.maximumGroups, conditions.count == conditionIDs.count else { throw DrugReferenceError.message("Invalid situation selection.") }
        return try Self.normalized(conditions.map(\.searchTerms) + customTerms.map { [$0] })
    }
    static func normalized(_ groups: [[String]]) throws -> [[String]] {
        guard groups.count <= maximumGroups else { throw DrugReferenceError.message("Search at most eight text groups at once.") }
        return try groups.map { group in
            guard (1...20).contains(group.count) else { throw DrugReferenceError.message("Each search group needs 1–20 alternative terms.") }
            var seen = Set<String>(), result: [String] = []
            for raw in group {
                let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !term.isEmpty, term.count <= 200, !term.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                    throw DrugReferenceError.message("Use search terms of 1–200 characters without control characters.")
                }
                if seen.insert(term.lowercased()).inserted { result.append(term) }
            }
            return result
        }
    }
}

extension DrugConditionCatalog {
    static var categories: [String] {
        var seen = Set<String>()
        return conditions.map(\.category).filter { seen.insert($0).inserted }
    }
    static func matching(indications: String) -> [DrugCondition] {
        guard !indications.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return conditions.filter { condition in
            condition.searchTerms.contains { indications.range(of: $0, options: .caseInsensitive) != nil }
        }
    }
}
