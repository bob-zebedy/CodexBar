import Darwin
import Foundation
import Synchronization
import Testing

struct HistoryMaintenanceTests {
    @Test func normalizationWaitsForWriterAndUsesLatestAggregate() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let sync = SyncService(directoryURL: HistoryStorage.syncDirectoryURL(in: directory.url), isEnabled: { false })
        let service = HistoryService(directoryURL: directory.url, syncService: sync)
        let date = HistoryStorage.dateKey(for: HistoryStorage.identifierRetentionCutoffDate().addingTimeInterval(-86400))
        var aggregate = ActivityAggregate(date: date)
        aggregate.eventCount = 1
        aggregate.threadIDs = ["session"]
        aggregate.turnIDs = ["turn"]
        let dailyURL = HistoryStorage.dailyURL(in: directory.url)
        try FileManager.default.createDirectory(at: dailyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try aggregate.jsonLineData().write(to: dailyURL)
        try FileManager.default.createDirectory(at: HistoryStorage.lockURL(in: directory.url).deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(HistoryStorage.lockURL(in: directory.url).path, O_CREAT | O_RDWR, 0o600)
        try #require(descriptor >= 0)
        defer { flock(descriptor, LOCK_UN)
            close(descriptor)
        }
        try #require(flock(descriptor, LOCK_EX) == 0)
        let started = Mutex(false)
        let finished = Mutex(false)
        let normalization = Task.detached {
            started.withLock { $0 = true }
            try await service.normalizeDailyAggregatesIfNeeded()
            finished.withLock { $0 = true }
        }
        for _ in 0 ..< 100 where !started.withLock({ $0 }) {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(started.withLock { $0 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(!finished.withLock { $0 })
        aggregate.eventCount = 7
        try aggregate.jsonLineData().write(to: dailyURL, options: .atomic)
        #expect(flock(descriptor, LOCK_UN) == 0)
        try await normalization.value
        let normalized = try #require(JSONLines.decode(ActivityAggregate.self, from: Data(contentsOf: dailyURL)).first)
        #expect(normalized.eventCount == 7)
        #expect(normalized.threadIDs == nil)
        #expect(normalized.turnIDs == nil)
    }

    @Test func explicitRebuildRecalculatesFromEventsWithoutChangingFormatOrSource() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let now = Date()
        let date = HistoryStorage.dateKey(for: now)
        let records = ["request-a", "request-b"].map {
            AppServerEventRecord(activity: TestFixtures.event(.approvalRequested, at: now, turn: $0), recordedAt: now)
        }
        let recordsData = try records.reduce(into: Data()) { result, record in try result.append(record.jsonLineData()) }
        let journalURL = try directory.writeJournal(recordsData, to: "Events/\(date).jsonl")
        let data = try Data(contentsOf: journalURL)
        let sync = SyncService(directoryURL: HistoryStorage.syncDirectoryURL(in: directory.url), isEnabled: { false })
        let service = HistoryService(directoryURL: directory.url, syncService: sync)
        _ = await service.loadSnapshotWithMaintenance(synchronize: false, trigger: .manual)
        var aggregate = try #require(JSONLines.decode(ActivityAggregate.self, from: Data(contentsOf: HistoryStorage.dailyURL(in: directory.url))).first)
        aggregate.approvalRequestedCount = 1
        try aggregate.jsonLineData().write(to: HistoryStorage.dailyURL(in: directory.url))
        var state = try HistoryStorage.loadMaintenanceState(in: directory.url)
        state.markDirty(date)
        try HistoryStorage.saveMaintenanceState(state, in: directory.url)
        _ = await service.loadSnapshotWithMaintenance(synchronize: false, trigger: .manual)
        let rebuilt = try #require(JSONLines.decode(ActivityAggregate.self, from: Data(contentsOf: HistoryStorage.dailyURL(in: directory.url))).first)
        #expect(rebuilt.approvalRequestedCount == 2)
        #expect(rebuilt.eventCount == 2)
        #expect(rebuilt.generationID == aggregate.generationID)
        #expect(try HistoryStorage.loadMaintenanceState(in: directory.url).version == HistoryMaintenanceState.currentVersion)
        #expect(try Data(contentsOf: directory.url.appendingPathComponent("Events/\(date).jsonl")) == data)
    }

    @Test func historyMaintenanceUsesOnlyInjectedRoot() async throws {
        let first = try TestDirectory()
        let second = try TestDirectory()
        defer { try? first.remove()
            try? second.remove()
        }
        let recorder = ActivityRecorder(directoryURL: first.url)
        let event = ActivityRecord(
            timestamp: Date(), name: ActivityEventKind.turnStarted.rawValue, origin: .main,
            cwd: nil, toolName: nil, model: nil, effort: nil, threadID: "session", turnID: "turn", agentID: nil, id: "isolated"
        )
        try await recorder.record(event: event)
        let sync = SyncService(directoryURL: HistoryStorage.syncDirectoryURL(in: first.url), isEnabled: { false })
        let service = HistoryService(directoryURL: first.url, syncService: sync)
        let result = await service.loadSnapshotWithMaintenance(synchronize: false, trigger: .manual)
        #expect(result.counts?.events == 1)
        #expect(FileManager.default.fileExists(atPath: HistoryStorage.dailyURL(in: first.url).path))
        #expect(!FileManager.default.fileExists(atPath: HistoryStorage.dailyURL(in: second.url).path))
        #expect(try !HistoryStorage.loadMaintenanceState(in: first.url).days.isEmpty)
        #expect(try HistoryStorage.loadMaintenanceState(in: second.url).days.isEmpty)
    }
}

extension HistoryMaintenanceTests {
    @Test func boundaryVerificationDetectsSameMillisecondRewriteAndSurvivesRestart() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let now = Date()
        let date = HistoryStorage.dateKey(for: now)
        var originalEvent = TestFixtures.event(.turnStarted, at: now)
        originalEvent.context = nil
        let original = try AppServerEventRecord(activity: originalEvent, recordedAt: now).jsonLineData()
        let replacement = try AppServerEventRecord(activity: TestFixtures.event(.toolStarted, at: now), recordedAt: now).jsonLineData()
        #expect(original.count == replacement.count)
        let url = try directory.writeJournal(original, to: "Events/\(date).jsonl")
        let seconds = Int(now.timeIntervalSince1970)
        let firstTimes = [timespec(tv_sec: seconds, tv_nsec: 1000100), timespec(tv_sec: seconds, tv_nsec: 1000100)]
        #expect(utimensat(AT_FDCWD, url.path, firstTimes, 0) == 0)
        let sync = SyncService(directoryURL: HistoryStorage.syncDirectoryURL(in: directory.url), isEnabled: { false })
        let service = HistoryService(directoryURL: directory.url, syncService: sync)
        _ = await service.loadSnapshotWithMaintenance(synchronize: false, trigger: .manual)
        let stateBefore = try HistoryStorage.loadMaintenanceState(in: directory.url)
        let maintenanceBefore = try #require(HistoryStorage.fileStat(at: HistoryStorage.maintenanceURL(in: directory.url)))
        _ = await service.loadSnapshotWithMaintenance(synchronize: false, trigger: .manual)
        #expect(HistoryStorage.fileStat(at: HistoryStorage.maintenanceURL(in: directory.url)) == maintenanceBefore)
        let before = try #require(HistoryStorage.fileStat(at: url))
        let handle = try FileHandle(forWritingTo: url)
        try handle.seek(toOffset: UInt64(#require(Data(contentsOf: url).firstIndex(of: 10)) + 1))
        try handle.write(contentsOf: replacement)
        try handle.close()
        let secondTimes = [timespec(tv_sec: seconds, tv_nsec: 1000900), timespec(tv_sec: seconds, tv_nsec: 1000900)]
        #expect(utimensat(AT_FDCWD, url.path, secondTimes, 0) == 0)
        let after = try #require(HistoryStorage.fileStat(at: url))
        #expect(before.modificationTime == after.modificationTime)
        #expect(before.modifiedAtNanoseconds != after.modifiedAtNanoseconds)
        _ = await service.loadSnapshotWithMaintenance(synchronize: false, trigger: .manual)
        let rebuilt = try #require(JSONLines.decode(ActivityAggregate.self, from: Data(contentsOf: HistoryStorage.dailyURL(in: directory.url))).first)
        #expect(rebuilt.toolStartedCount == 1)
        #expect(rebuilt.turnStartedCount == 0)
        #expect(rebuilt.generationID == stateBefore.days[date]?.generationID)
        let restarted = HistoryService(directoryURL: directory.url, syncService: sync)
        let maintenanceAfter = try #require(HistoryStorage.fileStat(at: HistoryStorage.maintenanceURL(in: directory.url)))
        _ = await restarted.loadSnapshotWithMaintenance(synchronize: false, trigger: .manual)
        #expect(HistoryStorage.fileStat(at: HistoryStorage.maintenanceURL(in: directory.url)) == maintenanceAfter)
    }

    @Test func historyLockIsExclusiveAndReleasedWhenWorkThrows() throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        enum TestError: Error { case expected }
        #expect(throws: TestError.self) {
            try HistoryStorage.withExclusiveLock(in: directory.url) {
                let descriptor = open(HistoryStorage.lockURL(in: directory.url).path, O_RDWR)
                #expect(descriptor >= 0)
                guard descriptor >= 0 else { throw TestError.expected }
                defer { close(descriptor) }
                let result = flock(descriptor, LOCK_EX | LOCK_NB)
                let lockError = errno
                #expect(result == -1)
                #expect(lockError == EWOULDBLOCK)
                throw TestError.expected
            }
        }
        let descriptor = open(HistoryStorage.lockURL(in: directory.url).path, O_RDWR)
        #expect(descriptor >= 0)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
        #expect(flock(descriptor, LOCK_UN) == 0)
    }

    @Test func lockFileOpenFailurePreservesPOSIXError() throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        for url in [HistoryStorage.lockURL(in: directory.url), directory.url.appendingPathComponent("store.lock")] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        #expect(throws: POSIXError(.EISDIR)) {
            try HistoryStorage.withExclusiveLock(in: directory.url) {
                Issue.record("Lock acquisition should fail before running the operation")
            }
        }
        #expect(throws: POSIXError(.EISDIR)) {
            try JSONFileStorage.withLock(in: directory.url) {
                Issue.record("Lock acquisition should fail before running the operation")
            }
        }
    }

    @Test func maintenanceNormalizesQueuesAndRejectsUnknownVersion() throws {
        let state = try TestFixtures.decode(HistoryMaintenanceState.self, """
        {"version":1,"pending":["2026-09-15","invalid","2026-09-14","2026-09-15"],"dirty":["2026-02-30","2026-09-14"]}
        """)
        #expect(state.pending == ["2026-09-14", "2026-09-15"])
        #expect(state.dirty == ["2026-09-14"])
        #expect(throws: StorageCompatibilityError.self) {
            try TestFixtures.decode(HistoryMaintenanceState.self, "{\"version\":2}")
        }
    }

    @Test func sourceIdentitySurvivesMissingMaintenanceState() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let recorder = ActivityRecorder(directoryURL: directory.url)
        let event = ActivityRecord(
            timestamp: Date(),
            name: ActivityEventKind.turnStarted.rawValue,
            origin: .main,
            cwd: nil,
            toolName: nil,
            model: nil,
            effort: nil,
            threadID: "thread",
            turnID: "turn",
            agentID: nil,
            id: "source-recovery"
        )
        try await recorder.record(event: event)
        let service = HistoryService(directoryURL: directory.url, syncService: SyncService(isEnabled: { false }))
        _ = await service.loadSnapshotWithMaintenance(synchronize: false, trigger: .manual)
        let original = try HistoryStorage.loadMaintenanceState(in: directory.url)
        try FileManager.default.removeItem(at: HistoryStorage.maintenanceURL(in: directory.url))
        _ = await service.loadSnapshotWithMaintenance(synchronize: false, trigger: .manual)
        let recovered = try HistoryStorage.loadMaintenanceState(in: directory.url)
        #expect(recovered.days.mapValues(\.generationID) == original.days.mapValues(\.generationID))
    }

    @Test func maintenanceStoragePreservesReadBoundaryAndFileIdentity() throws {
        let date = "2026-09-15"
        let state = HistoryMaintenanceState(pending: [date], dirty: [date], days: [date: HistoryDayMaintenanceState(
            offset: 50, size: 60, corrupt: 2, generationID: "source",
            fileIdentifier: 7
        )])
        let data = try JSONLines.stableEncoder.encode(state)
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(root.keys) == ["version", "pending", "dirty", "days"])
        let days = try #require(root["days"] as? [String: [String: Any]])
        let day = try #require(days[date])
        #expect(Set(day.keys) == [
            "offset", "size", "corrupt", "generationID",
            "fileIdentifier"
        ])
        #expect(try JSONDecoder().decode(HistoryMaintenanceState.self, from: data) == state)
    }

    @Test func repeatedPendingAndDirtyUpdatesAreIdempotent() {
        var state = HistoryMaintenanceState()
        let result0 = state.markPending("2026-09-15")
        #expect(result0)
        let result1 = !state.markPending("2026-09-15")
        #expect(result1)
        let result2 = state.markDirty("2026-09-15")
        #expect(result2)
        let result3 = !state.markDirty("2026-09-15")
        #expect(result3)
        #expect(state.days["2026-09-15"]?.generationID == nil)
    }
}
