import Foundation

/// 底层 pipe 读取桥接了 FileHandle, DispatchSourceRead 和 semaphore
/// 这些非 Sendable 类型
/// 对外 Sendable 边界只保留在这里
/// 可变状态全部经由 lock 保护, 读事件固定在 readQueue 上执行
final nonisolated class PipeReadBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let closedSemaphore = DispatchSemaphore(value: 0)
    private let fileHandle: FileHandle
    private let readQueue: DispatchQueue
    private let readQueueKey = DispatchSpecificKey<Void>()
    private let readSource: DispatchSourceRead
    private let maxBytes: Int
    private var collectedData = Data()
    private var closed = false
    private var readSourceCancelled = false

    init(fileHandle: FileHandle, maxBytes: Int) {
        self.fileHandle = fileHandle
        self.maxBytes = max(maxBytes, 0)
        readQueue = DispatchQueue(label: "CodexBar.pipe-read", qos: .userInitiated)
        readSource = DispatchSource.makeReadSource(
            fileDescriptor: fileHandle.fileDescriptor,
            queue: readQueue
        )

        readQueue.setSpecific(key: readQueueKey, value: ())
        readSource.setEventHandler { [weak self] in
            self?.readAvailableData()
        }
        readSource.resume()
    }

    private func readAvailableData() {
        let data = fileHandle.availableData
        guard !data.isEmpty else {
            cancelReadSourceIfNeeded()
            markClosed()
            return
        }

        append(data)
    }

    private func append(_ data: Data) {
        withLock {
            if maxBytes > 0, collectedData.count < maxBytes {
                collectedData.append(data.prefix(maxBytes - collectedData.count))
            }
        }
    }

    func waitUntilClosed(timeout: TimeInterval) -> Bool {
        let isClosed = withLock { closed }

        guard !isClosed else {
            return true
        }

        return closedSemaphore.wait(timeout: .now() + max(0, timeout)) == .success
    }

    func stopAndRead() -> Data {
        cancelReadSourceIfNeeded()
        waitForReadQueueToDrain()
        try? fileHandle.close()

        let snapshot = withLock {
            closed = true
            return collectedData
        }
        closedSemaphore.signal()

        return snapshot
    }

    private func cancelReadSourceIfNeeded() {
        let shouldCancel = withLock {
            guard !readSourceCancelled else {
                return false
            }

            readSourceCancelled = true
            return true
        }

        if shouldCancel {
            readSource.cancel()
        }
    }

    private func waitForReadQueueToDrain() {
        guard DispatchQueue.getSpecific(key: readQueueKey) == nil else {
            return
        }

        readQueue.sync {}
    }

    private func markClosed() {
        withLock {
            closed = true
        }
        closedSemaphore.signal()
    }

    private func withLock<T>(_ work: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return work()
    }
}
