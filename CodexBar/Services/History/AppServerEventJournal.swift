import Foundation

nonisolated struct AppServerEventJournal {
    private var identities: [String: Set<String>] = [:]
    private var sizes: [String: UInt64] = [:]
    private var inodes: [String: UInt64] = [:]

    mutating func append(_ entry: AppServerEventRecord, in directoryURL: URL) throws {
        let dateKey = HistoryStorage.dateKey(for: entry.activity?.timestamp ?? entry.recordedAt)
        let eventsDirectory = directoryURL.appendingPathComponent("Events")
        let eventLogURL = HistoryStorage.eventLogURL(for: dateKey, in: eventsDirectory)
        let maintenanceURL = HistoryStorage.maintenanceURL(in: directoryURL)
        var maintenanceState = try JSONFileStorage.load(HistoryMaintenanceState.self, from: maintenanceURL) ?? HistoryMaintenanceState()
        let existingStat = HistoryStorage.fileStat(at: eventLogURL)
        var stateChanged = false
        if entry.deduplicationID != nil, sizes[dateKey] != existingStat?.size || inodes[dateKey] != existingStat?.identifier {
            let offset = sizes[dateKey].flatMap { size in
                inodes[dateKey] == existingStat?.identifier && size < (existingStat?.size ?? 0) ? size : nil
            } ?? 0
            var previous = offset > 0 ? identities[dateKey] ?? [] : []
            if existingStat != nil {
                try Self.read(at: eventLogURL, from: offset) { entry in
                    if let id = entry.deduplicationID {
                        previous.insert(id)
                    }
                }
            }
            identities[dateKey] = previous
        }
        if let identity = entry.deduplicationID, identities[dateKey]?.contains(identity) == true {
            if maintenanceState.markPending(dateKey) {
                try JSONFileStorage.save(maintenanceState, to: maintenanceURL)
            }
            return
        }

        if let existingStat {
            let day = maintenanceState.days[dateKey]
            let identifierChanged = day?.fileIdentifier != nil
                && day?.fileIdentifier != existingStat.identifier
            let fileShrank = day.map { existingStat.size < $0.offset } ?? false

            if identifierChanged || fileShrank {
                maintenanceState.startNewGeneration(
                    for: dateKey,
                    startedEmpty: existingStat.size == 0,
                    fileIdentifier: existingStat.identifier
                )
                stateChanged = true
            } else {
                stateChanged = maintenanceState.ensureGenerationID(
                    for: dateKey,
                    fileIdentifier: existingStat.identifier
                )
            }
        } else {
            maintenanceState.startNewGeneration(
                for: dateKey,
                startedEmpty: true,
                fileIdentifier: nil
            )
            stateChanged = true
        }

        try append(entry.jsonLineData(), to: eventLogURL)
        if let identity = entry.deduplicationID {
            identities[dateKey, default: []].insert(identity)
        }
        sizes[dateKey] = entry.deduplicationID != nil ? HistoryStorage.fileSize(at: eventLogURL) : nil
        inodes[dateKey] = HistoryStorage.fileStat(at: eventLogURL)?.identifier
        let oldest = HistoryStorage.dateKey(for: Date().addingTimeInterval(-2 * 86400))
        identities = identities.filter { $0.key >= oldest }
        sizes = sizes.filter { $0.key >= oldest }
        inodes = inodes.filter { $0.key >= oldest }

        if var day = maintenanceState.days[dateKey],
           day.fileIdentifier == nil,
           let identifier = HistoryStorage.fileStat(at: eventLogURL)?.identifier {
            day.fileIdentifier = identifier
            maintenanceState.days[dateKey] = day
            stateChanged = true
        }

        // 稳态下当天早已 pending, 跳过无变化的全量重写以缩短持锁时间
        if maintenanceState.markPending(dateKey) || stateChanged {
            try JSONFileStorage.save(maintenanceState, to: maintenanceURL)
        }
    }

    /// 分块扫描并限制单行大小, 截断或损坏的行不影响其他完整记录
    static func read(at url: URL, from offset: UInt64 = 0, onInvalidLine: (() -> Void)? = nil, consume: (AppServerEventRecord) throws -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        var buffer = Data()
        var droppingLine = false
        let maximumLineSize = 1024 * 1024
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: JSONLines.newlineByte) {
                let line = Data(buffer[..<newline])
                if !droppingLine, line.count <= maximumLineSize, let entry = try? AppServerEventRecord.decode(from: line) {
                    try consume(entry)
                } else if !droppingLine, !line.isEmpty {
                    onInvalidLine?()
                }
                droppingLine = false
                buffer.removeSubrange(...newline)
            }
            if buffer.count > maximumLineSize || droppingLine {
                if !droppingLine {
                    onInvalidLine?()
                }
                buffer.removeAll(keepingCapacity: true)
                droppingLine = true
            }
        }
        if !droppingLine, let entry = try? AppServerEventRecord.decode(from: buffer) {
            try consume(entry)
        } else if !droppingLine, !buffer.isEmpty {
            onInvalidLine?()
        }
    }

    private func append(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }

        let fileHandle = try FileHandle(forUpdating: url)
        defer {
            try? fileHandle.close()
        }

        let length = try fileHandle.seekToEnd()
        if length > 0 {
            try fileHandle.seek(toOffset: length - 1)
            let last = try fileHandle.read(upToCount: 1)
            try fileHandle.seekToEnd()
            if last != Data([0x0A]) {
                try fileHandle.write(contentsOf: Data([0x0A]))
            }
        }
        try fileHandle.write(contentsOf: data)
    }
}
