import Foundation
import os
import Testing

/// 通过注入时钟暂停存储队列, 主 actor 只查询状态和发送释放信号
final nonisolated class AppServerLogReadGate: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (shouldBlock: false, didBlock: false))
    private let semaphore = DispatchSemaphore(value: 0)

    var didBlock: Bool {
        state.withLock { $0.didBlock }
    }

    func arm() {
        state.withLock { $0.shouldBlock = true }
    }

    func release() {
        semaphore.signal()
    }

    func now() -> Date {
        let shouldBlock = state.withLock { state in
            guard state.shouldBlock else { return false }
            state.shouldBlock = false
            state.didBlock = true
            return true
        }
        if shouldBlock {
            #expect(semaphore.wait(timeout: .now() + 5) == .success)
        }
        return Date()
    }
}
