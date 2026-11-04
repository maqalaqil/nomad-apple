#if DEBUG
import Foundation

/// Keeps platform objects on the main actor across a checked continuation.
@MainActor final class DeviceProbePayload<Value> {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// Resumes at most once even when a platform callback arrives after cancellation or timeout.
@MainActor final class DeviceProbeDeadline<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Error>?
    private var watchdog: Task<Void, Never>?
    private var finished = false

    struct Timeout: LocalizedError {
        var errorDescription: String? { "The local renderer did not respond before its deadline." }
    }

    func wait(seconds: Double, start: (@escaping (Result<Value, Error>) -> Void) -> Void) async throws -> Value {
        try Task.checkCancellation()
        guard seconds.isFinite, seconds > 0 else { throw Timeout() }
        let value = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                watchdog = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                    self?.finish(.failure(Timeout()))
                }
                start { [weak self] result in
                    // WebKit delivers these completion handlers on the main queue.
                    // Deferring also makes synchronously completed test callbacks safe.
                    Task { @MainActor in self?.finish(result) }
                }
            }
        }, onCancel: { [weak self] in
            Task { @MainActor in self?.cancel() }
        })
        try Task.checkCancellation()
        return value
    }

    func cancel() { finish(.failure(CancellationError())) }

    private func finish(_ result: Result<Value, Error>) {
        guard !finished, let continuation else { return }
        finished = true; self.continuation = nil
        watchdog?.cancel(); watchdog = nil
        continuation.resume(with: result)
    }
}
#endif
