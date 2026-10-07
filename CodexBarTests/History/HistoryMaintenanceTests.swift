import Darwin
import Foundation
import Testing

struct HistoryMaintenanceTests {
    @Test func historyMaintenanceUsesOnlyInjectedRoot() async throws {
        let first = try TestDirectory()
        let second = try TestDirectory()
        defer { try? first.remove()
            try? second.remove()
        }
        let recorder = ActivityRecorder(directoryURL: first.url)
        let event = ActivityRecord(
            timestamp: Date(), name: ActivityEventKind.turnStarted.rawValue, origin: .main,
            cwd: nil, tool: nil, model: nil, effort: nil, approvalReviewer: .user,
            sessionID: "session", turnID: "turn", agentID: nil, id: "isolated"
        )
        try await recorder.record(event: event)
        let sync = SyncService(directoryURL: HistoryStorage.syncDirectoryURL(in: first.url), isEnabled: { false })
        let service = HistoryService(directoryURL: first.url, syncService: sync)
        let result = await service.loadSnapshotWithMaintenance(synchronize: false, trigger: .manual)
        #expect(result.counts?.events == 1)
        #expect(FileManager.default.fileExists(atPath: HistoryStorage.dailyURL(in: first.url).path))
        #expect(!FileManager.default.fileExists(atPath: HistoryStorage.dailyURL(in: second.url).path))
        #expect(!HistoryStorage.loadMaintenanceState(in: first.url).days.isEmpty)
        #expect(HistoryStorage.loadMaintenanceState(in: second.url).days.isEmpty)
    }
}

extension HistoryMaintenanceTests {
    @Test func boundaryVerificationDetectsSameMillisecondRewriteAndSurvivesRestart() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let now = Date()
        let date = HistoryStorage.dateKey(for: now)
        let original = try AppServerEventRecord(activity: TestFixtures.event(.turnStarted, at: now), recordedAt: now).jsonLineData()
        let replacement = try AppServerEventRecord(activity: TestFixtures.event(.toolStarted, at: now), recordedAt: now).jsonLineData()
        #expect(original.count == replacement.count)
        let url = try directory.write(original, to: "Events/\(date).jsonl")
        let seconds = Int(now.timeIntervalSince1970)
        let firstTimes = [timespec(tv_sec: seconds, tv_nsec: 1000100), timespec(tv_sec: seconds, tv_nsec: 1000100)]
        #expect(utimensat(AT_FDCWD, url.path, firstTimes, 0) == 0)
        let sync = SyncService(directoryURL: HistoryStorage.syncDirectoryURL(in: directory.url), isEnabled: { false })
        let service = HistoryService(directoryURL: directory.url, syncService: sync)
        _ = await service.loadSnapshotWithMaintenance(synchronize: false, trigger: .manual)
        let stateBefore = HistoryStorage.loadMaintenanceState(in: directory.url)
        let maintenanceBefore = try #require(HistoryStorage.fileStat(at: HistoryStorage.maintenanceURL(in: directory.url)))
        _ = await service.loadSnapshotWithMaintenance(synchronize: false, trigger: .manual)
        #expect(HistoryStorage.fileStat(at: HistoryStorage.maintenanceURL(in: directory.url)) == maintenanceBefore)
        let before = try #require(HistoryStorage.fileStat(at: url))
        let handle = try FileHandle(forWritingTo: url)
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
        #expect(rebuilt.generationID != stateBefore.days[date]?.generationID)
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

    @Test func legacyMaintenanceStateRequiresRebuildAndNormalizesDateQueues() throws {
        let state = try TestFixtures.decode(HistoryMaintenanceState.self, """
        {"pending":["2026-09-15","invalid","2026-09-14","2026-09-15"],"dirty":["2026-02-30","2026-09-14"]}
        """)
        #expect(state.version == 0)
        #expect(state.pending == ["2026-09-14", "2026-09-15"])
        #expect(state.dirty == ["2026-09-14"])
    }

    @Test func fileReplacementResetsOffsetsHashesAndMarksDayDirty() throws {
        let date = "2026-09-15"
        var state = HistoryMaintenanceState(days: [date: HistoryDayMaintenanceState(
            offset: 50, size: 60, corrupt: 2, generationID: "old", generationStartedEmpty: false,
            fileIdentifier: 1, boundaryHash: "old-hash"
        )])
        state.startNewGeneration(for: date, startedEmpty: true, fileIdentifier: 2)
        let day = try #require(state.days[date])
        #expect(day.offset == 0)
        #expect(day.corrupt == 0)
        #expect(day.generationID != "old")
        #expect(day.generationStartedEmpty)
        #expect(day.fileIdentifier == 2)
        #expect(day.boundaryHash == nil)
        #expect(state.dirty == [date])
    }

    @Test func maintenanceStoragePreservesReadBoundaryAndFileIdentity() throws {
        let date = "2026-09-15"
        let state = HistoryMaintenanceState(pending: [date], dirty: [date], days: [date: HistoryDayMaintenanceState(
            offset: 50, size: 60, corrupt: 2, generationID: "source", generationStartedEmpty: true,
            fileIdentifier: 7, boundaryHash: "digest"
        )])
        let data = try JSONLines.stableEncoder.encode(state)
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(root.keys) == ["version", "pending", "dirty", "days"])
        let days = try #require(root["days"] as? [String: [String: Any]])
        let day = try #require(days[date])
        #expect(Set(day.keys) == [
            "requiresCloudReplacement", "offset", "size", "corrupt", "generationID", "generationStartedEmpty",
            "fileIdentifier", "boundaryHash"
        ])
        #expect(try JSONDecoder().decode(HistoryMaintenanceState.self, from: data) == state)
    }

    @Test func repeatedPendingAndSourceUpdatesAreIdempotent() throws {
        var state = HistoryMaintenanceState()
        let firstPending = state.markPending("2026-09-15")
        let secondPending = state.markPending("2026-09-15")
        #expect(firstPending)
        #expect(!secondPending)
        let firstSource = state.ensureGenerationID(for: "2026-09-15", fileIdentifier: 1)
        let generation = try #require(state.days["2026-09-15"]?.generationID)
        let secondSource = state.ensureGenerationID(for: "2026-09-15", fileIdentifier: 1)
        #expect(firstSource)
        #expect(!secondSource)
        #expect(state.days["2026-09-15"]?.generationID == generation)
        #expect(state.days["2026-09-15"]?.generationStartedEmpty == false)
    }
}
