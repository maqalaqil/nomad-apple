import Foundation

struct Failure: Error { let text: String }
@MainActor func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw Failure(text: message) }
}

@MainActor final class DeferredProvider {
    private var pending: [Int: CheckedContinuation<String, Never>] = [:]
    private var waiting: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var count = 0
    func request() async -> String {
        let index = count; count += 1
        return await withCheckedContinuation { continuation in
            pending[index] = continuation
            let ready = waiting.filter { count >= $0.0 }; waiting.removeAll { count >= $0.0 }
            ready.forEach { $0.1.resume() }
        }
    }
    func waitFor(_ count: Int) async {
        if self.count >= count { return }
        await withCheckedContinuation { waiting.append((count, $0)) }
    }
    func resolve(_ index: Int, _ value: String) { pending.removeValue(forKey: index)!.resume(returning: value) }
}

@main struct TranslationStateRegression {
    @MainActor static func main() async throws {
        let enAR = TranslationLanguagePair(source: "en", target: "ar")
        let arEN = TranslationLanguagePair(source: "ar", target: "en")
        let state = TranslationRequestState(), provider = DeferredProvider()
        var selected = enAR
        // A manual check remains alive while the picker changes and a new check starts.
        let first = Task { await state.checkAvailability(pair: enAR, currentPair: { selected }, check: { _ in await provider.request() }) }
        await provider.waitFor(1); selected = arEN
        let second = Task { await state.checkAvailability(pair: arEN, currentPair: { selected }, check: { _ in await provider.request() }) }
        await provider.waitFor(2)
        provider.resolve(1, "supported"); let newStatus = await second.value
        provider.resolve(0, "installed"); let oldStatus = await first.value
        try check(newStatus == "supported", "current pair status accepted")
        try check(oldStatus == nil, "old pair cannot replace new pair status")

        // Merely changing a picker invalidates an old result even before its replacement check starts.
        let third = Task { await state.checkAvailability(pair: arEN, currentPair: { selected }, check: { _ in await provider.request() }) }
        await provider.waitFor(3); selected = enAR
        provider.resolve(2, "installed")
        let changedOnly = await third.value
        try check(changedOnly == nil, "pair identity is rechecked after suspension")

        // Two refreshes of the same pair may also complete out of order.
        let fourth = Task { await state.checkAvailability(pair: enAR, currentPair: { selected }, check: { _ in await provider.request() }) }
        await provider.waitFor(4)
        let fifth = Task { await state.checkAvailability(pair: enAR, currentPair: { selected }, check: { _ in await provider.request() }) }
        await provider.waitFor(5)
        provider.resolve(4, "installed"); let newest = await fifth.value
        provider.resolve(3, "supported"); let staleSamePair = await fourth.value
        try check(newest == "installed" && staleSamePair == nil, "latest same-pair refresh owns status")

        let cancelled = Task { await state.checkAvailability(pair: enAR, currentPair: { selected }, check: { _ in await provider.request() }) }
        await provider.waitFor(6); cancelled.cancel(); provider.resolve(5, "installed")
        let cancelledStatus = await cancelled.value
        try check(cancelledStatus == nil, "cancelled check cannot publish readiness")

        var current = TranslationTextRequest(pair: enAR, text: "Original sentence")
        let original = current, token = state.beginTextRequest(original)
        var submittedText = ""
        let translation = Task { () -> String? in
            submittedText = token.request.text
            let value = await provider.request()
            return state.accepts(token, currentRequest: current) ? value : nil
        }
        await provider.waitFor(7); current = .init(pair: enAR, text: "Edited while waiting")
        provider.resolve(6, "الجملة الأصلية")
        let staleText = await translation.value
        try check(submittedText == "Original sentence", "translator receives immutable submitted source")
        try check(staleText == nil, "result cannot appear below changed source text")
        current = original
        try check(state.accepts(token, currentRequest: current), "unchanged request identity accepts its result")
        current = .init(pair: arEN, text: original.text)
        try check(!state.accepts(token, currentRequest: current), "result cannot appear for a different direction")
        current = original
        let replacement = state.beginTextRequest(current)
        try check(!state.accepts(token, currentRequest: current) && state.accepts(replacement, currentRequest: current), "replaced text operation cannot publish")
        state.invalidate()
        try check(!state.accepts(replacement, currentRequest: current), "leaving the view invalidates pending response")
        let cancellationToken = state.beginTextRequest(current)
        let cancelledText = Task { () -> Bool in
            _ = await provider.request()
            return state.accepts(cancellationToken, currentRequest: current)
        }
        await provider.waitFor(8); cancelledText.cancel(); provider.resolve(7, "late")
        let acceptsCancelled = await cancelledText.value
        try check(!acceptsCancelled, "cancelled text task cannot publish")
        let supported = ["af", "ar-SA", "en-US", "ar-AE"].map(Locale.Language.init(identifier:))
        try check(TranslationLanguageResolver.resolve(preferredIdentifier: "ar", supported: supported)?.minimalIdentifier == "ar-AE", "generic Arabic resolves within Arabic, not the unrelated first entry")
        try check(TranslationLanguageResolver.resolve(preferredIdentifier: "ar-SA", supported: supported)?.minimalIdentifier == "ar-SA", "explicit supported Arabic variant is preserved")
        try check(TranslationLanguageResolver.resolve(preferredIdentifier: "ar_AE", supported: supported)?.minimalIdentifier == "ar-AE", "equivalent locale spelling resolves to supported identifier")
        try check(TranslationLanguageResolver.resolve(preferredIdentifier: "en", supported: supported)?.minimalIdentifier == "en", "English default resolves to its supported normalized identifier")
        try check(TranslationLanguageResolver.resolve(preferredIdentifier: "ja", supported: supported) == nil, "unsupported language returns explicit absence instead of another language")
        try check(TranslationLanguageResolver.resolve(baseCode: "ar", preferredIdentifiers: ["en", "ar-SA"], supported: supported)?.minimalIdentifier == "ar-SA", "diagnostic preserves saved prepared variant from either direction")
        print("PASS: 12 async state checks and 6 supported-language selection checks; no language models or network used")
    }
}
