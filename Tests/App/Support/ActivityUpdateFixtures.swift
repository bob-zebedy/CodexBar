import Combine
import Foundation

/// 协议测试通过正式发布接口观察值快照, 不共享 reader 内部状态
@MainActor final class ActivityReaderProbe {
    var graph = ActivityTaskGraph()
}

@MainActor
extension AppServerActivityReader {
    init(
        probe: ActivityReaderProbe,
        socketURL: URL = AppServerActivityReader.defaultSocketURL,
        logStorage: AppServerLogStore? = nil,
        tokenUsageHistory: TokenUsageHistoryStore = TokenUsageHistoryStore(),
        activityDataRecorder: ActivityDataRecorder = ActivityDataRecorder(),
        maximumPendingEvents: Int = 4096,
        maximumPendingBytes: Int = 8 * 1024 * 1024,
        maximumLoadedPages: Int = 100,
        reconciliationTimeout: TimeInterval = 30,
        onAccountChange: @escaping @MainActor @Sendable (AccountChange) -> Void = { _ in },
        onBatch: @escaping @MainActor @Sendable (ActivityUpdate) -> Void
    ) {
        self.init(
            socketURL: socketURL,
            logStorage: logStorage,
            tokenUsageHistory: tokenUsageHistory,
            activityDataRecorder: activityDataRecorder,
            maximumPendingEvents: maximumPendingEvents,
            maximumPendingBytes: maximumPendingBytes,
            maximumLoadedPages: maximumLoadedPages,
            reconciliationTimeout: reconciliationTimeout,
            onAccountChange: onAccountChange
        ) { update in
            probe.graph = update.graph
            onBatch(update)
        }
    }
}

enum ActivityFixtureBatch {
    case bootstrapStart
    case snapshotEvents([ActivityDataRecord])
    case bootstrapEnd
    case live([ActivityDataRecord])
    case sourceUnavailable
    case lifecycleChanged

    var phase: ActivityUpdate.Phase {
        switch self {
        case .bootstrapStart: .bootstrapStart
        case .snapshotEvents: .snapshotEvents
        case .bootstrapEnd: .bootstrapEnd
        case .live: .live
        case .sourceUnavailable: .sourceUnavailable
        case .lifecycleChanged: .lifecycleChanged
        }
    }
}

extension ActivityMonitor {
    private static var fixtureRevision: UInt64 = 0
    private static let fixtureReaderID = UUID()

    /// 展示和保护测试从任务图产生真实 update, 每次经过 monitor 的正式消费接口
    func acceptFixtureGraph(_ graph: ActivityTaskGraph, phase: ActivityUpdate.Phase = .lifecycleChanged, transitions: [ActivityTransition] = []) {
        Self.fixtureRevision &+= 1
        consume(ActivityUpdate(
            readerID: Self.fixtureReaderID,
            revision: Self.fixtureRevision,
            phase: phase,
            graph: graph,
            transitions: transitions,
            terminalEvents: graph.terminalEvents,
            backfilledTasks: graph.backfilledTasks
        ))
        self.graph.terminalEvents.removeAll()
        self.graph.backfilledTasks.removeAll()
    }

    func consume(_ batch: ActivityFixtureBatch) {
        var next = graph
        let transitions: [ActivityTransition]
        switch batch {
        case .bootstrapStart:
            next = ActivityTaskGraph()
            transitions = []
        case let .snapshotEvents(events): transitions = next.consume(events, source: .bootstrap)
        case let .live(events): transitions = next.consume(events, source: .live)
        default: transitions = []
        }
        acceptFixtureGraph(next, phase: batch.phase, transitions: transitions)
    }

    func apply(_ event: ActivityDataRecord, source: ActivityEventSource, into transitions: inout [ActivityTransition]) -> ActivityTaskKey? {
        var next = graph
        var changes: [ActivityTransition] = []
        let waiting = next.apply(event, source: source, into: &changes)
        acceptFixtureGraph(next)
        transitions += changes.filter { isCurrentTransition($0) }
        return waiting
    }

    func resolveTerminal(
        _ terminal: TurnTerminalState,
        task: ActivityTask,
        key: ActivityTaskKey,
        abortFallback: Date,
        publishesEvents: Bool = true,
        into transitions: inout [ActivityTransition]
    ) {
        var next = graph
        var changes: [ActivityTransition] = []
        next.resolveTerminal(terminal, task: task, key: key, abortFallback: abortFallback, publishesEvents: publishesEvents, into: &changes)
        acceptFixtureGraph(next)
        transitions += changes.filter { isCurrentTransition($0) }
    }

    func applySubagentLifecycle(_ state: TurnLifecycleState) {
        var next = graph
        next.applySubagentLifecycle(state)
        acceptFixtureGraph(next)
    }

    func publishWaitingApprovalTransitions(_ keys: [ActivityTaskKey]) {
        for transition in graph.waitingApprovalTransitions(keys) where isCurrentTransition(transition) {
            transitionSubject.send(transition)
        }
    }
}
