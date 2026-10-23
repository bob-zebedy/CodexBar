import Foundation

/// 实时通知和历史执行项共用数据库事件身份去重
nonisolated struct ActivityDataRecorder: Sendable {
    private let database: HistoryDatabaseStore

    init(directoryURL: URL = AppStorage.directoryURL()) {
        database = HistoryDatabaseStore.shared(in: directoryURL)
    }

    func record(event: ActivityDataRecord) async throws {
        guard event.id != nil else { return }
        _ = try await database.access { try $0.append(AppServerEventRecord(activityData: event)) }
    }

    func record(events: [ActivityDataRecord]) async throws {
        try await database.access { try $0.appendActivityData(events) }
    }
}
