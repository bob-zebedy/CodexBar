import Foundation

/// 实时通知和历史执行项共用数据库事件身份去重
actor ActivityDataRecorder {
    private let directoryURL: URL

    init(directoryURL: URL = HistoryStorage.directoryURL()) {
        self.directoryURL = directoryURL
    }

    func record(event: ActivityDataRecord) throws {
        guard event.id != nil else { return }
        try HistoryDatabase(directoryURL: directoryURL).append(AppServerEventRecord(activityData: event))
    }

    func record(events: [ActivityDataRecord]) throws {
        try HistoryDatabase(directoryURL: directoryURL).appendActivityData(events)
    }
}
