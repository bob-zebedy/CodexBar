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

    func wait(timeout: Duration = .seconds(3)) async throws -> Bool {
        try await waitForCondition(timeout: timeout, pollInterval: .milliseconds(5)) { self.isSignaled }
    }

    /// 模拟取消后仍返回的依赖, 调用方必须在 defer 中释放等待
    func waitIgnoringCancellation() async {
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
