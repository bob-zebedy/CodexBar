import Foundation

/// 多次读取和重连共享同一预算, 单调时钟防止系统时间回拨延长请求
nonisolated struct AppServerRequestBudget: Sendable {
    @TaskLocal static var current: AppServerRequestBudget?

    let wallDeadline: Date
    let deadline: ContinuousClock.Instant

    init(deadline: Date, now: Date = Date()) {
        wallDeadline = deadline
        self.deadline = ContinuousClock.now.advanced(by: .seconds(max(0, deadline.timeIntervalSince(now))))
    }

    private init(wallDeadline: Date, deadline: ContinuousClock.Instant) {
        self.wallDeadline = wallDeadline
        self.deadline = deadline
    }

    func constrained(to date: Date, now: Date = Date()) -> Self {
        Self(wallDeadline: min(wallDeadline, date), deadline: min(deadline, ContinuousClock.now.advanced(by: .seconds(max(0, date.timeIntervalSince(now))))))
    }

    func check() throws {
        try Task.checkCancellation()
        guard Date() < wallDeadline, ContinuousClock.now < deadline else {
            throw CodexStatusError.serverTimeout
        }
    }

    static func checkCurrent() throws {
        try Task.checkCancellation()
        try current?.check()
    }
}
