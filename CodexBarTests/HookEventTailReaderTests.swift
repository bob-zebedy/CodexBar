import Foundation
import Testing

struct HookEventTailReaderTests {
    @Test func bootstrapFiltersRetentionAndLiveDrainDoesNotReplayOldEvents() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let recorder = HookBatchRecorder()
        let now = TestFixtures.now
        let old = TestFixtures.event(at: now.addingTimeInterval(-86401), turn: "old")
        let current = TestFixtures.event(at: now, turn: "current")
        let path = "\(WorkflowStorage.dateKey(for: now)).jsonl"
        let url = try directory.write(old.jsonLineData() + current.jsonLineData(), to: path)
        let reader = HookEventTailReader(eventsDirectoryURL: directory.url, now: { now }, onBatch: recorder.receive)
        await reader.start()
        #expect(recorder.bootstrapEvents.map(\.turnId) == ["current"])
        #expect(recorder.liveEvents.isEmpty)
        let live = TestFixtures.event(.preToolUse, at: now.addingTimeInterval(1), turn: "live")
        try append(live.jsonLineData(), to: url)
        let first = await reader.drainNow()
        let second = await reader.drainNow()
        await reader.stop()
        #expect(first == .completed)
        #expect(second == .completed)
        #expect(recorder.liveEvents.map(\.turnId) == ["live"])
    }

    @Test func partialLiveLineWaitsForNewlineAndIsDeliveredOnce() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let recorder = HookBatchRecorder()
        let now = TestFixtures.now
        let reader = HookEventTailReader(eventsDirectoryURL: directory.url, now: { now }, onBatch: recorder.receive)
        await reader.start()
        let line = try TestFixtures.event().jsonLineData()
        let url = try directory.write(Data(line.dropLast()), to: "\(WorkflowStorage.dateKey(for: now)).jsonl")
        let partial = await reader.drainNow()
        #expect(recorder.liveEvents.isEmpty)
        try append(Data([JSONLines.newlineByte]), to: url)
        let completed = await reader.drainNow()
        await reader.stop()
        #expect(partial == .sourceUnavailable)
        #expect(completed == .completed)
        #expect(recorder.liveEvents.count == 1)
    }

    @Test func replacingEventFileRebootstrapsInsteadOfPublishingHistoricalTransitions() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let recorder = HookBatchRecorder()
        let now = TestFixtures.now
        let url = try directory.write(TestFixtures.event().jsonLineData(), to: "\(WorkflowStorage.dateKey(for: now)).jsonl")
        let reader = HookEventTailReader(eventsDirectoryURL: directory.url, now: { now }, onBatch: recorder.receive)
        await reader.start()
        try TestFixtures.event(turn: "replacement").jsonLineData().write(to: url, options: .atomic)
        let result = await reader.drainNow()
        await reader.stop()
        #expect(result == .completed)
        #expect(recorder.bootstrapCount == 2)
        #expect(recorder.bootstrapEvents.map(\.turnId) == ["replacement"])
        #expect(recorder.liveEvents.isEmpty)
    }

    @Test func corruptedLineReportsUnhealthyWhilePreservingValidEvents() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let recorder = HookBatchRecorder()
        let now = TestFixtures.now
        _ = try directory.write(Data("broken\n".utf8) + TestFixtures.event().jsonLineData(), to: "\(WorkflowStorage.dateKey(for: now)).jsonl")
        let reader = HookEventTailReader(eventsDirectoryURL: directory.url, now: { now }, onBatch: recorder.receive)
        await reader.start()
        let result = await reader.drainNow()
        await reader.stop()
        #expect(recorder.bootstrapEvents.count == 1)
        #expect(recorder.degraded == true)
        #expect(recorder.health.last == false)
        #expect(result == .sourceUnavailable)
    }

    @Test func stoppedReaderRejectsDrainRequests() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let reader = HookEventTailReader(eventsDirectoryURL: directory.url, onBatch: { _ in })
        #expect(await reader.drainNow() == .cancelled)
        await reader.start()
        await reader.stop()
        #expect(await reader.drainNow() == .cancelled)
    }

    @Test func missingDirectoryReportsUnavailableDuringRetryBackoff() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let missing = directory.url.appendingPathComponent("missing")
        let recorder = HookBatchRecorder()
        let reader = HookEventTailReader(eventsDirectoryURL: missing, now: { TestFixtures.now }, onBatch: recorder.receive)
        await reader.start()
        let result = await reader.drainNow()
        await reader.stop()
        #expect(result == .sourceUnavailable)
        #expect(recorder.degraded == true)
        #expect(recorder.bootstrapEvents.isEmpty)
    }

    private func append(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}

@MainActor
private final class HookBatchRecorder {
    var bootstrapEvents: [WorkflowHookEvent] = []
    var liveEvents: [WorkflowHookEvent] = []
    var bootstrapCount = 0
    var degraded: Bool?
    var health: [Bool] = []

    func receive(_ batch: HookEventBatch) {
        switch batch {
        case .bootstrapStart:
            bootstrapCount += 1
            bootstrapEvents.removeAll()
        case let .bootstrapEvents(events): bootstrapEvents.append(contentsOf: events)
        case let .bootstrapEnd(degraded, _): self.degraded = degraded
        case let .live(events): liveEvents.append(contentsOf: events)
        case let .sourceHealthChanged(healthy): health.append(healthy)
        }
    }
}
