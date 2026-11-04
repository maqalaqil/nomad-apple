import Foundation

struct TranslationLanguagePair: Equatable, Sendable {
    let source: String
    let target: String
}

struct TranslationTextRequest: Equatable, Sendable {
    let pair: TranslationLanguagePair
    let text: String
}

/// Drops late framework responses after selection changes, replacement checks, or cancellation.
/// Framework calls are injected so ordering can be checked without installed language models.
@MainActor
final class TranslationRequestState {
    private var availabilityID = UUID()
    private var textID = UUID()

    func checkAvailability<Result: Sendable>(pair: TranslationLanguagePair,
                                   currentPair: @MainActor () -> TranslationLanguagePair,
                                   check: @MainActor (TranslationLanguagePair) async -> Result) async -> Result? {
        let id = UUID(); availabilityID = id
        let result = await check(pair)
        guard !Task.isCancelled, id == availabilityID, pair == currentPair() else { return nil }
        return result
    }

    func beginTextRequest(_ request: TranslationTextRequest) -> Token {
        let id = UUID(); textID = id
        return Token(id: id, request: request)
    }

    func accepts(_ token: Token, currentRequest: TranslationTextRequest) -> Bool {
        !Task.isCancelled && token.id == textID && token.request == currentRequest
    }

    func invalidate() { availabilityID = UUID(); textID = UUID() }

    struct Token: Sendable {
        fileprivate let id: UUID
        let request: TranslationTextRequest
    }
}

/// Uses identifiers actually published by Apple's supported-language list. Generic "ar" may
/// resolve to "ar-AE"; an unsupported language never silently becomes the first unrelated entry.
enum TranslationLanguageResolver {
    static func resolve(preferredIdentifier: String, supported: [Locale.Language]) -> Locale.Language? {
        let preferred = Locale.Language(identifier: preferredIdentifier)
        if let exact = supported.first(where: { $0.minimalIdentifier == preferred.minimalIdentifier }) { return exact }
        guard let base = preferred.languageCode?.identifier else { return nil }
        return resolve(baseCode: base, preferredIdentifiers: [preferredIdentifier], supported: supported)
    }

    /// Diagnostics can pass both saved selections, preserving a prepared variant even after swapping.
    static func resolve(baseCode: String, preferredIdentifiers: [String], supported: [Locale.Language]) -> Locale.Language? {
        let base = Locale.Language(identifier: baseCode).languageCode?.identifier
        guard let base else { return nil }
        let matches = supported.filter { $0.languageCode?.identifier == base }
        for identifier in preferredIdentifiers {
            let preferred = Locale.Language(identifier: identifier)
            guard preferred.languageCode?.identifier == base else { continue }
            if let exact = matches.first(where: { $0.minimalIdentifier == preferred.minimalIdentifier }) { return exact }
        }
        if let generic = matches.first(where: { $0.minimalIdentifier == base }) { return generic }
        return matches.sorted { $0.minimalIdentifier < $1.minimalIdentifier }.first
    }
}
