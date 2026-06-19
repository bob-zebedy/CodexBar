import Foundation

nonisolated final class JSONLineReader: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private let fileHandle: FileHandle
    private var buffer = Data()
    private var lines: [String] = []
    private var closed = false
    
    init(fileHandle: FileHandle) {
        self.fileHandle = fileHandle
        fileHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                self?.markClosed()
                return
            }
            self?.append(data)
        }
    }
    
    func nextLine(timeout: TimeInterval) -> String? {
        if let line = popLine() {
            return line
        }
        
        if isClosed {
            return nil
        }
        
        let result = semaphore.wait(timeout: .now() + timeout)
        guard result == .success else {
            return nil
        }
        
        return popLine()
    }
    
    func stop() {
        fileHandle.readabilityHandler = nil
        markClosed()
    }
    
    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        
        return closed && lines.isEmpty
    }
    
    private func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        
        buffer.append(data)
        
        while let newlineRange = buffer.firstRange(of: Data([0x0A])) {
            let lineData = buffer[..<newlineRange.lowerBound]
            buffer.removeSubrange(...newlineRange.lowerBound)
            
            if let line = String(data: lineData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !line.isEmpty {
                lines.append(line)
                semaphore.signal()
            }
        }
    }
    
    private func markClosed() {
        lock.lock()
        defer {
            lock.unlock()
            semaphore.signal()
        }
        
        if !buffer.isEmpty {
            if let line = String(data: buffer, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !line.isEmpty {
                lines.append(line)
            }
            buffer.removeAll()
        }
        
        closed = true
    }
    
    private func popLine() -> String? {
        lock.lock()
        defer { lock.unlock() }
        
        guard !lines.isEmpty else {
            return nil
        }
        
        return lines.removeFirst()
    }
}

nonisolated final class PipeDrain: @unchecked Sendable {
    private let fileHandle: FileHandle
    
    init(fileHandle: FileHandle) {
        self.fileHandle = fileHandle
        fileHandle.readabilityHandler = { handle in
            guard !handle.availableData.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
        }
    }
    
    func stop() {
        fileHandle.readabilityHandler = nil
    }
}
