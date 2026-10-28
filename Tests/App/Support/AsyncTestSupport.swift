import Foundation

@MainActor
func waitForCondition(
    timeout: Duration,
    pollInterval: Duration,
    _ condition: () async -> Bool
) async throws -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while await !condition(), ContinuousClock.now < deadline {
        try await Task.sleep(for: pollInterval)
    }
    return await condition()
}

@MainActor
final class TestCheckpoint {
    private var isSignaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isSignaled else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func signal() {
        isSignaled = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}
