import Foundation
import os

/// 同一目录共用连接, 每次访问在数据库 actor 内同步完成, 事务不跨 await
actor HistoryDatabaseStore {
    private static let applicationStore = HistoryDatabaseStore(directoryURL: AppStorage.directoryURL().standardizedFileURL)
    private static let stores = OSAllocatedUnfairLock(initialState: [URL: WeakStore]())

    private struct WeakStore {
        weak var value: HistoryDatabaseStore?
    }

    private let directoryURL: URL
    private var database: HistoryDatabase?

    nonisolated static func shared(in directoryURL: URL) -> HistoryDatabaseStore {
        let directoryURL = directoryURL.standardizedFileURL
        if directoryURL == applicationStore.directoryURL {
            return applicationStore
        }
        return stores.withLock { stores in
            if let store = stores[directoryURL]?.value {
                return store
            }
            stores = stores.filter { $0.value.value != nil }
            let store = HistoryDatabaseStore(directoryURL: directoryURL)
            stores[directoryURL] = WeakStore(value: store)
            return store
        }
    }

    private init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    /// 释放当前连接, 已提交数据保留, 下次访问时按需重开
    func releaseConnection() {
        database = nil
    }

    func access<Value: Sendable>(_ operation: @Sendable (HistoryDatabase) throws -> Value) throws -> Value {
        try Task.checkCancellation()
        do {
            if let database, try !database.canReuseConnection() {
                releaseConnection()
            }
        } catch {
            guard let failure = error as? HistoryDatabase.Failure, failure.requiresReopening else { throw error }
            // 检查阶段还没有执行本次操作, 可以安全重开连接
            releaseConnection()
        }
        let database: HistoryDatabase
        if let existing = self.database {
            database = existing
        } else {
            database = try HistoryDatabase(directoryURL: directoryURL)
            self.database = database
        }
        // 失败回滚后仍有事务的连接不能交给下一位调用方
        defer {
            if database.hasOpenTransaction {
                releaseConnection()
            }
        }
        do {
            return try operation(database)
        } catch {
            if let failure = error as? HistoryDatabase.Failure, failure.requiresReopening {
                releaseConnection()
            }
            throw error
        }
    }
}
