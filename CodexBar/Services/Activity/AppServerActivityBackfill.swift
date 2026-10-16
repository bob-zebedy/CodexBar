import Foundation

/// 历史执行项的接收与解析独立执行, 不能占住实时采集 actor
actor AppServerActivityBackfill {
    struct Page: Sendable {
        let items: [ActivityItemEntry]
        let nextCursor: String?
        let limit: Int
    }

    private let socketURL: URL
    private let logStorage: AppServerLogStore?
    private let maximumMessageSize: Int

    init(socketURL: URL, logStorage: AppServerLogStore?, maximumMessageSize: Int = AppServerSession.defaultMaximumMessageSize) {
        self.socketURL = socketURL
        self.logStorage = logStorage
        self.maximumMessageSize = maximumMessageSize
    }

    func readPage(reference: ActivityTurnReference, cursor: String?, limit: Int, timeout: TimeInterval) throws -> Page {
        // 缩小分页后的重试共用本次截止时间, 避免重连反复延长读取上限
        let budget = AppServerRequestBudget(deadline: Date().addingTimeInterval(timeout))
        return try AppServerRequestBudget.$current.withValue(budget) {
            var connection: AppServerSession?
            defer { connection?.close() }
            func read(limit: Int) throws -> ActivityItemsPage {
                try budget.check()
                if connection == nil {
                    let opened = try AppServerSession(
                        socketURL: socketURL, retainsNotifications: false, logStorage: logStorage,
                        connectionName: "activity/backfill", maximumMessageSize: maximumMessageSize
                    )
                    connection = opened
                    try opened.initialize(clientName: "codex_bar_activity_backfill", minimumVersion: CodexVersionReader.minimumAppServerVersion)
                }
                let request = ActivityRequests.items(reference, limit: limit, cursor: cursor)
                let page: ActivityItemsPage = try connection!.request(request.method, params: request.params)
                try budget.check()
                guard page.nextCursor == nil || page.nextCursor != cursor else { throw CodexStatusError.invalidServerResponse }
                return page
            }
            var pageLimit = limit
            while true {
                do {
                    let page = try read(limit: pageLimit)
                    guard page.data.allSatisfy({ $0.turnId == reference.turnID }) else { throw CodexStatusError.invalidServerResponse }
                    return Page(items: page.data, nextCursor: page.nextCursor, limit: pageLimit)
                } catch let error as CodexStatusError {
                    guard case .messageTooLarge = error else { throw error }
                    // 超大消息会关闭连接, 清除旧会话后缩小分页并重新握手
                    connection?.close()
                    connection = nil
                    if pageLimit > 1 {
                        pageLimit = max(1, pageLimit / 2)
                        continue
                    }
                    throw error
                }
            }
        }
    }
}
