import CloudKit
import Foundation

/// 只有已确认的局部错误允许继续, 未识别的云端错误保持停止当前轮次
nonisolated enum SyncRecovery {
    enum Failure: Error {
        case invalidCursor
        case unsupportedCacheVersion
        case missingRecordResult
    }

    static func decodeCursor(_ data: Data) throws -> CKServerChangeToken {
        do {
            guard let token = try NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data) else {
                throw Failure.invalidCursor
            }
            return token
        } catch {
            throw Failure.invalidCursor
        }
    }

    static func isInvalidCursor(_ error: Error) -> Bool {
        if case Failure.invalidCursor = error {
            return true
        }
        return (error as? CKError)?.code == .changeTokenExpired
    }

    static func isMissingZone(_ error: Error, zoneID: CKRecordZone.ID, queryingZone: Bool = false) -> Bool {
        isMissingZone(error, zoneID: zoneID, queryingZone: queryingZone, depth: 0)
    }

    private static func isMissingZone(_ error: Error, zoneID: CKRecordZone.ID, queryingZone: Bool, depth: Int) -> Bool {
        guard depth < 8, let error = error as? CKError else { return false }
        switch error.code {
        case .zoneNotFound, .userDeletedZone:
            return true
        case .unknownItem:
            // 查询单条记录时的 unknownItem 不能说明整个 zone 已不存在
            return queryingZone
        case .partialFailure:
            return (error.partialErrorsByItemID ?? [:]).contains { key, failure in
                if let id = key as? CKRecordZone.ID, id == zoneID {
                    return isMissingZone(failure, zoneID: zoneID, queryingZone: queryingZone, depth: depth + 1)
                }
                if let id = key as? CKRecord.ID, id.zoneID == zoneID {
                    return isMissingZone(failure, zoneID: zoneID, queryingZone: false, depth: depth + 1)
                }
                return false
            }
        default:
            return false
        }
    }

    static func isRecordFailure(_ error: Error) -> Bool {
        guard let error = error as? CKError else { return false }
        return [.serverRecordChanged, .constraintViolation, .unknownItem, .assetFileNotFound, .assetFileModified, .invalidArguments].contains(error.code)
    }

    static func stopsOtherSync(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        guard let error = error as? CKError else { return false }
        return !isRecordFailure(error) && error.code != .changeTokenExpired
    }
}

nonisolated struct SyncFailures {
    private(set) var first: Error?
    private(set) var stopping: Error?

    mutating func record(_ error: Error) {
        first = first ?? error
        if !SyncRecovery.isRecordFailure(error) {
            stopping = stopping ?? error
        }
    }

    func checkStopping() throws {
        if let stopping {
            throw stopping
        }
    }

    func check() throws {
        try checkStopping()
        if let first {
            throw first
        }
    }
}
