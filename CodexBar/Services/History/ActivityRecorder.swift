import Foundation

/// 采集器只写已观察到的活动, 初始快照不进入历史
actor ActivityRecorder {
    private let directoryURL: URL
    private var journal = AppServerEventJournal()

    init(directoryURL: URL = HistoryStorage.directoryURL()) {
        self.directoryURL = directoryURL
    }

    func record(event: ActivityRecord) throws {
        guard event.id != nil else { return }
        try HistoryStorage.withExclusiveLock(in: directoryURL) {
            try journal.append(AppServerEventRecord(activity: event), in: directoryURL)
        }
    }
}

// 调用方持有 events.lock, 活动与 Token 共用追加和维护状态事务
