import Foundation

@main struct DeviceProbeRegression {
    @MainActor static func main() async throws {
        let synchronous = try await DeviceProbeDeadline<Int>().wait(seconds: 1) { $0(.success(7)) }
        precondition(synchronous == 7)
        do { _ = try await DeviceProbeDeadline<Int>().wait(seconds: 0.01) { _ in }; fatalError("Missing callback hung") }
        catch is DeviceProbeDeadline<Int>.Timeout { }
        var late: ((Result<Int, Error>) -> Void)?
        do { _ = try await DeviceProbeDeadline<Int>().wait(seconds: 0.01) { late = $0 }; fatalError("Timeout accepted") }
        catch is DeviceProbeDeadline<Int>.Timeout { }
        late?(.success(9)); late?(.failure(CancellationError()))
        let gate = DeviceProbeDeadline<Int>()
        let cancelled = Task { try await gate.wait(seconds: 60) { _ in } }
        try await Task.sleep(for: .milliseconds(10)); cancelled.cancel()
        do { _ = try await cancelled.value; fatalError("Cancellation accepted") } catch is CancellationError { }
        let before = Task { try Task.checkCancellation(); return try await DeviceProbeDeadline<Int>().wait(seconds: 60) { _ in } }
        before.cancel()
        do { _ = try await before.value; fatalError("Early cancellation accepted") } catch is CancellationError { }
        let explicit = DeviceProbeDeadline<Int>()
        let wait = Task { try await explicit.wait(seconds: 60) { _ in } }
        try await Task.sleep(for: .milliseconds(10)); explicit.cancel()
        do { _ = try await wait.value; fatalError("Button cancellation accepted") } catch is CancellationError { }
        do { _ = try await DeviceProbeDeadline<Int>().wait(seconds: 1) { $0(.failure(CocoaError(.fileReadCorruptFile))) }; fatalError("Failure swallowed") }
        catch let error as CocoaError { precondition(error.code == .fileReadCorruptFile) }
        let duplicate = try await DeviceProbeDeadline<Int>().wait(seconds: 1) { done in done(.success(1)); done(.success(2)) }
        precondition(duplicate == 1)
        try await Task.sleep(for: .milliseconds(20))
        print("PASS: 8 callback deadline, late completion and cancellation checks")
    }
}
