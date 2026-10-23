import Foundation

/// App 数据根目录下的文件和锁路径在这里统一定义
nonisolated struct AppStorage {
    enum Lock: String {
        case appInstance
        case tokenUsageRecording
        case protectionState
        case activityDataSyncCache
        case tokenUsageSyncCache
        case tokenUsageSync
    }

    let rootURL: URL

    init(rootURL: URL = Self.directoryURL()) {
        self.rootURL = rootURL
    }

    var historyDatabaseURL: URL {
        rootURL.appendingPathComponent("event.db")
    }

    var logDirectoryURL: URL {
        rootURL.appendingPathComponent("Logs", isDirectory: true)
    }

    var protectionStateURL: URL {
        rootURL.appendingPathComponent("Protection/state.json")
    }

    var activityDataSyncCacheURL: URL {
        rootURL.appendingPathComponent("Sync/activityData.json")
    }

    var tokenUsageSyncCacheURL: URL {
        rootURL.appendingPathComponent("Sync/tokenUsage.json")
    }

    func lockURL(_ lock: Lock) -> URL {
        rootURL.appendingPathComponent("Locks/\(lock.rawValue).lock")
    }

    #if DEBUG
        static let directoryName = "CodexBar Data Debug"
    #else
        static let directoryName = "CodexBar Data"
    #endif

    static func directoryURL(fileManager: FileManager = .default) -> URL {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
        return applicationSupport.appendingPathComponent(directoryName, isDirectory: true)
    }
}
