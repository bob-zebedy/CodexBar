import Foundation

/// app-server stdout 行读取器, 只向会话层暴露完整非空行
final nonisolated class JSONLineReader {
    private let buffer: PipeReadBuffer

    init(fileHandle: FileHandle) {
        buffer = PipeReadBuffer(fileHandle: fileHandle, parsesLines: true)
    }

    func nextLine(timeout: TimeInterval) -> String? {
        buffer.nextLine(timeout: timeout)
    }

    func stop() {
        buffer.stop()
    }

    var isClosed: Bool {
        buffer.hasNoMoreLines
    }
}

/// stderr 只需要及时 drain, 避免子进程因管道填满而阻塞
final nonisolated class PipeDrain {
    private let buffer: PipeReadBuffer

    init(fileHandle: FileHandle) {
        buffer = PipeReadBuffer(fileHandle: fileHandle)
    }

    func stop() {
        buffer.stop()
    }
}

/// 底层 pipe 读取桥接了 FileHandle, DispatchSourceRead 和 semaphore
/// 这些非 Sendable 类型
/// 对外 Sendable 边界只保留在这里
/// 可变状态全部经由 lock 保护, 读事件固定在 readQueue 上执行
final nonisolated class PipeReadBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let lineSemaphore = DispatchSemaphore(value: 0)
    private let closedSemaphore = DispatchSemaphore(value: 0)
    private let fileHandle: FileHandle
    private let readQueue: DispatchQueue
    private let readQueueKey = DispatchSpecificKey<Void>()
    private let readSource: DispatchSourceRead
    private let maxBytes: Int
    private let parsesLines: Bool
    private var collectedData = Data()
    private var lineBuffer = Data()
    private var lines: [String] = []
    private var closed = false
    private var readSourceCancelled = false

    init(fileHandle: FileHandle, maxBytes: Int = 0, parsesLines: Bool = false) {
        self.fileHandle = fileHandle
        self.maxBytes = max(maxBytes, 0)
        self.parsesLines = parsesLines
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

    func nextLine(timeout: TimeInterval) -> String? {
        if let line = popLine() {
            return line
        }

        if hasNoMoreLines {
            return nil
        }

        let result = lineSemaphore.wait(timeout: .now() + max(0, timeout))
        guard result == .success else {
            return nil
        }

        return popLine()
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

            guard parsesLines else {
                return
            }

            lineBuffer.append(data)

            while let newlineRange = lineBuffer.firstRange(of: Data([0x0A])) {
                let lineData = lineBuffer[..<newlineRange.lowerBound]
                lineBuffer.removeSubrange(...newlineRange.lowerBound)
                appendLineIfPresent(lineData, signal: true)
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
            appendRemainingLineIfNeeded()
            closed = true
            return collectedData
        }
        closedSemaphore.signal()
        lineSemaphore.signal()

        return snapshot
    }

    func stop() {
        _ = stopAndRead()
    }

    var hasNoMoreLines: Bool {
        withLock { closed && lines.isEmpty }
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
            appendRemainingLineIfNeeded()
            closed = true
        }
        closedSemaphore.signal()
        lineSemaphore.signal()
    }

    private func appendRemainingLineIfNeeded() {
        guard parsesLines, !lineBuffer.isEmpty else {
            return
        }

        appendLineIfPresent(lineBuffer, signal: false)
        lineBuffer.removeAll()
    }

    private func appendLineIfPresent(_ data: Data, signal: Bool) {
        guard let line = String(bytes: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !line.isEmpty else {
            return
        }

        lines.append(line)
        if signal {
            lineSemaphore.signal()
        }
    }

    private func popLine() -> String? {
        withLock {
            guard !lines.isEmpty else {
                return nil
            }

            return lines.removeFirst()
        }
    }

    private func withLock<T>(_ work: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return work()
    }
}
