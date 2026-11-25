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
            var pageLimit = limit
            let page: ActivityItemsPage = try budget.readPage(limit: &pageLimit) { limit in
                let connection = try AppServerSession(
                    socketURL: socketURL, retainsNotifications: false, logStorage: logStorage,
                    connectionName: "activity/backfill", maximumMessageSize: maximumMessageSize
                )
                defer { connection.close() }
                try connection.initialize(clientName: "codex_bar_activity_backfill", minimumVersion: CodexVersionReader.minimumAppServerVersion)
                let request = ActivityRequests.items(reference, limit: limit, cursor: cursor)
                return try connection.request(request.method, params: request.params)
            }
            guard page.nextCursor == nil || page.nextCursor != cursor, page.data.allSatisfy({ $0.turnId == reference.turnID }) else { throw AppServerError.invalidServerResponse }
            return Page(items: page.data, nextCursor: page.nextCursor, limit: pageLimit)
        }
    }
}
