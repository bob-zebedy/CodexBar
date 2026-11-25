import Foundation

/// 多次读取和重连共享同一预算, 单调时钟防止系统时间回拨延长请求
nonisolated struct AppServerRequestBudget: Sendable {
    @TaskLocal static var current: AppServerRequestBudget?

    /// Bridge 在共享连接上发出请求后要读完响应, 下次发送前再检查调用方是否已取消
    @TaskLocal static var finishesCurrentExchange = false

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
        if !Self.finishesCurrentExchange {
            try Task.checkCancellation()
        }
        guard Date() < wallDeadline, ContinuousClock.now < deadline else {
            throw AppServerError.serverTimeout
        }
    }

    /// 超大响应会关闭连接, 用同一游标和截止时间缩页重试
    func readPage<Page>(limit: inout Int, closeConnection: () -> Void = {}, read: (Int) throws -> Page) throws -> Page {
        while true {
            try check()
            do {
                let page = try read(limit)
                try check()
                return page
            } catch let error as AppServerError {
                guard case .messageTooLarge = error else { throw error }
                closeConnection()
                guard limit > 1 else { throw error }
                limit /= 2
            }
        }
    }

    static func checkCurrent() throws {
        if let current {
            try current.check()
        } else if !finishesCurrentExchange {
            try Task.checkCancellation()
        }
    }
}
