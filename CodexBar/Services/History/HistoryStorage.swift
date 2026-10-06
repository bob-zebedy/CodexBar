import CryptoKit
import Darwin
import Foundation
import os

/// 活动统计文件路径, 保留期和跨进程 flock 都集中在这里
nonisolated enum HistoryStorage {
    private static let retentionDayCount = 210
    private static let identifierRetentionDayCount = 3

    // MARK: - 存储路径

    static func eventsDirectoryURL(in root: URL = directoryURL()) -> URL {
        root
            .appendingPathComponent("Events", isDirectory: true)
    }

    static func eventLogURL(for dateKey: String, in directoryURL: URL = eventsDirectoryURL()) -> URL {
        directoryURL.appendingPathComponent("\(dateKey).jsonl", isDirectory: false)
    }

    static func dailyURL(in root: URL = directoryURL()) -> URL {
        root.appendingPathComponent("Aggregates/activity.jsonl", isDirectory: false)
    }

    static func lockURL(in root: URL = directoryURL()) -> URL {
        root.appendingPathComponent("Locks/events.lock", isDirectory: false)
    }

    static func maintenanceURL(in root: URL = directoryURL()) -> URL {
        root.appendingPathComponent("State/aggregation.json", isDirectory: false)
    }

    static func syncDirectoryURL(in root: URL = directoryURL()) -> URL {
        root.appendingPathComponent("Sync", isDirectory: true)
    }

    static func directoryURL() -> URL {
        AppStorage.directoryURL()
    }

    static func withExclusiveLock<T>(
        in root: URL = directoryURL(),
        _ work: () throws -> T
    ) throws -> T {
        try FileManager.default.createDirectory(
            at: lockURL(in: root).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // 创建与打开必须是同一次调用: 分开做时两个进程可能各自创建,
        // 后创建的会 unlink 掉前者正在锁的 inode, 于是双方都以为自己独占
        let fileDescriptor = open(lockURL(in: root).path, O_RDWR | O_CREAT, 0o600)
        guard fileDescriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer {
            close(fileDescriptor)
        }

        // 采集与维护使用独立服务实例, 文件事务必须共享同一把锁
        guard flock(fileDescriptor, LOCK_EX) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        defer {
            flock(fileDescriptor, LOCK_UN)
        }

        return try work()
    }

    static func loadMaintenanceState(in root: URL = directoryURL()) -> HistoryMaintenanceState {
        let url = maintenanceURL(in: root)
        guard let data = try? Data(contentsOf: url), !data.isEmpty,
              let state = try? JSONLines.decoder.decode(HistoryMaintenanceState.self, from: data) else {
            return HistoryMaintenanceState()
        }

        return state
    }

    static func saveMaintenanceState(_ state: HistoryMaintenanceState, in root: URL = directoryURL()) throws {
        let url = maintenanceURL(in: root)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let data = try JSONLines.stableEncoder.encode(state)
        try data.write(to: url, options: .atomic)
    }

    static func fileSize(at url: URL) -> UInt64 {
        fileStat(at: url)?.size ?? 0
    }

    /// 单次 stat 同时返回大小与 inode 标识, 文件缺失或不可读时为 nil
    /// 维护流程需要批量读取文件状态, 直接使用 stat(2) 避免逐个构造属性字典
    /// 内存保留纳秒精度用于检测改写, 落盘时间统一使用整数毫秒
    /// 沿用 attributesOfItem 的语义跟随符号链接, 因此用 stat 而非 lstat
    static func fileStat(at url: URL) -> HistoryFileStat? {
        var info = Darwin.stat()
        guard stat(url.path, &info) == 0 else {
            return nil
        }

        return HistoryFileStat(
            size: UInt64(clamping: info.st_size),
            identifier: UInt64(info.st_ino),
            modifiedAtNanoseconds: Int64(info.st_mtimespec.tv_sec) * 1000000000
                + Int64(info.st_mtimespec.tv_nsec)
        )
    }

    /// 枚举目录中文件名为合法日期键的 .jsonl 事件日志, 返回升序日期键
    static func eventLogDateKeys(in directoryURL: URL = eventsDirectoryURL()) -> [String] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return contents
            .filter { $0.pathExtension == "jsonl" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .filter { isValidDateKey($0) }
            .sorted()
    }

    /// 返回保留窗口内且本机原始事件文件非空的日期, 供设置页标记和筛选实际重建项
    static func rebuildableEventDateKeys(
        in directoryURL: URL = eventsDirectoryURL()
    ) -> [String] {
        let cutoffKey = dateKey(for: retentionCutoffDate())
        return eventLogDateKeys(in: directoryURL)
            .filter { dateKey in
                dateKey >= cutoffKey
                    && fileSize(at: eventLogURL(for: dateKey, in: directoryURL)) > 0
            }
            .sorted(by: >)
    }

    static func retentionCutoffDate(today: Date = Date(), calendar: Calendar = .current) -> Date {
        cutoffDate(dayCount: retentionDayCount, today: today, calendar: calendar)
    }

    static func identifierRetentionCutoffDate(today: Date = Date(), calendar: Calendar = .current) -> Date {
        cutoffDate(dayCount: identifierRetentionDayCount, today: today, calendar: calendar)
    }

    private static func cutoffDate(dayCount: Int, today: Date, calendar: Calendar) -> Date {
        let todayStart = calendar.startOfDay(for: today)
        return calendar.date(
            byAdding: .day,
            value: -(dayCount - 1),
            to: todayStart
        ) ?? todayStart
    }

    static func dateKey(for date: Date) -> String {
        CodexDateFormat.dayString(from: date)
    }

    static func isValidDateKey(_ dateKey: String) -> Bool {
        CodexDateFormat.dayDate(from: dateKey) != nil
    }
}

nonisolated struct HistoryFileStat: Equatable {
    let size: UInt64
    let identifier: UInt64
    let modifiedAtNanoseconds: Int64

    var modificationTime: Int64 {
        modifiedAtNanoseconds / 1000000
    }
}
