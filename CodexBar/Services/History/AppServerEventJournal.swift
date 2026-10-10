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
        if !FileManager.default.fileExists(atPath: eventLogURL.path) {
            let header = Header(version: Header.currentVersion, date: dateKey, generationID: UUID().uuidString.lowercased())
            try FileManager.default.createDirectory(at: eventsDirectory, withIntermediateDirectories: true)
            try (JSONLines.stableEncoder.encode(header) + Data([JSONLines.newlineByte])).write(to: eventLogURL, options: .atomic)
        }
        let header = try Self.header(at: eventLogURL)
        guard header.date == dateKey else { throw StorageCompatibilityError.sourceConflict }
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

        if maintenanceState.days[dateKey]?.generationID != header.generationID {
            maintenanceState.days[dateKey] = HistoryDayMaintenanceState(
                generationID: header.generationID, fileIdentifier: existingStat?.identifier
            )
            maintenanceState.markDirty(dateKey)
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
    static func read(
        at url: URL,
        from offset: UInt64 = 0,
        upTo endOffset: UInt64? = nil,
        onInvalidLine: (() -> Void)? = nil,
        consume: (AppServerEventRecord) throws -> Void
    ) throws {
        if let endOffset, endOffset <= offset {
            return
        }
        let header = try Self.header(at: url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        var remaining = endOffset.map { $0 > offset ? $0 - offset : 0 } ?? UInt64.max
        var buffer = Data()
        var droppingLine = false
        let maximumLineSize = 1024 * 1024
        var firstLine = offset == 0
        func consumeLine(_ data: Data) throws {
            try Task.checkCancellation()
            if firstLine {
                firstLine = false
                let decoded = try JSONLines.decoder.decode(Header.self, from: data)
                guard decoded == header else { throw StorageCompatibilityError.sourceConflict }
                return
            }
            if let text = String(bytes: data, encoding: .utf8), text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return
            }
            let entry: AppServerEventRecord
            do {
                try StorageVersion.validate(data, current: AppServerEventRecord.currentVersion, name: "Event")
                entry = try AppServerEventRecord.decode(from: data)
            } catch is DecodingError {
                onInvalidLine?()
                return
            }
            try consume(entry)
        }
        while remaining > 0 {
            try Task.checkCancellation()
            let readSize = Int(min(remaining, 64 * 1024))
            guard let chunk = try handle.read(upToCount: readSize), !chunk.isEmpty else { break }
            remaining -= UInt64(chunk.count)
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: JSONLines.newlineByte) {
                let line = Data(buffer[..<newline])
                if !droppingLine {
                    if line.count <= maximumLineSize {
                        try consumeLine(line)
                    } else {
                        onInvalidLine?()
                    }
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
        if !droppingLine, !buffer.isEmpty {
            try consumeLine(buffer)
        }
    }

    struct Header: Codable, Equatable {
        static let currentVersion = 1
        let version: Int
        let date: String
        let generationID: String
    }

    static func header(at url: URL) throws -> Header {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let data = try handle.read(upToCount: 4096), let end = data.firstIndex(of: JSONLines.newlineByte) else {
            throw StorageCompatibilityError.incompleteSource
        }
        let line = Data(data[..<end])
        try StorageVersion.validate(line, current: Header.currentVersion, name: "EventJournal")
        let header = try JSONLines.decoder.decode(Header.self, from: line)
        guard HistoryStorage.isValidDateKey(header.date), !header.generationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StorageCompatibilityError.sourceConflict
        }
        return header
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
