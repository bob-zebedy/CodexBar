import AppKit
import Combine
import Foundation

/// 从本机 Hook JSONL 维护进程内实时任务状态，是菜单栏、活动卡片和通知的唯一任务状态来源。
@MainActor
final class CodexActivityMonitor: ObservableObject {
    @Published private(set) var snapshot = CodexActivitySnapshot.empty

    var transitionPublisher: AnyPublisher<CodexActivityTransition, Never> {
        transitionSubject.eraseToAnyPublisher()
    }

    private let codexHookSettings: CodexHookSettings
    private let sessionLifecycleReader = CodexSessionLifecycleReader()
    private let transitionSubject = PassthroughSubject<CodexActivityTransition, Never>()
    private var tasks: [CodexActivityTaskKey: CodexActivityTask] = [:]
    private var completions: [CodexActivityCompletion] = []
    private var recentlyCompletedTaskAt: [CodexActivityTaskKey: Date] = [:]
    private var tailReader: HookEventTailReader?
    private var tailReaderControlTask: Task<Void, Never>?
    private var tailReaderGeneration: UInt64 = 0
    private var sessionLifecyclePollTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var cleanupDeadline: Date?
    private var cancellables = Set<AnyCancellable>()
    private var isStarted = false
    private var isBootstrapping = false
    private var sessionTransitionNotBefore: Date?

    init(codexHookSettings: CodexHookSettings) {
        self.codexHookSettings = codexHookSettings
    }

    func start() {
        guard !isStarted else {
            return
        }
        isStarted = true

        codexHookSettings.$isEnabled
            .removeDuplicates()
            .sink { [weak self] isEnabled in
                self?.setMonitoringEnabled(isEnabled)
            }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else {
                    return
                }
                if let reader = tailReader {
                    Task {
                        await reader.drainNow()
                    }
                }
                refreshSessionLifecycleNow(resetsResolutionFallbacks: true)
            }
            .store(in: &cancellables)
    }

    func stop() {
        guard isStarted else {
            return
        }
        isStarted = false
        cancellables.removeAll()
        stopReaderAndClearState()
    }

    private func setMonitoringEnabled(_ enabled: Bool) {
        guard enabled else {
            stopReaderAndClearState()
            return
        }

        guard tailReader == nil else {
            return
        }

        tailReaderGeneration &+= 1
        let generation = tailReaderGeneration
        let reader = HookEventTailReader(
            onBatch: { [weak self] batch in
                guard let self, tailReaderGeneration == generation else {
                    return
                }
                consume(batch)
            }
        )
        tailReader = reader
        tailReaderControlTask = Task { @MainActor [weak self] in
            await reader.start()
            guard let self,
                  tailReaderGeneration == generation,
                  tailReader != nil else {
                return
            }
            startSessionLifecyclePolling(generation: generation)
        }
    }

    private func stopReaderAndClearState() {
        tailReaderGeneration &+= 1
        tailReaderControlTask?.cancel()
        tailReaderControlTask = nil
        let reader = tailReader
        tailReader = nil
        if let reader {
            Task {
                await reader.stop()
            }
        }
        sessionLifecyclePollTask?.cancel()
        sessionLifecyclePollTask = nil
        cleanupTask?.cancel()
        cleanupTask = nil
        cleanupDeadline = nil
        tasks.removeAll()
        completions.removeAll()
        recentlyCompletedTaskAt.removeAll()
        isBootstrapping = false
        sessionTransitionNotBefore = nil
        snapshot = .empty
    }

    private func startSessionLifecyclePolling(generation: UInt64) {
        guard sessionLifecyclePollTask == nil else {
            return
        }

        sessionLifecyclePollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else {
                    return
                }
                await reconcileSessionLifecycles(generation: generation)
                try? await Task.sleep(for: .seconds(Self.sessionLifecyclePollInterval))
            }
        }
    }

    private func refreshSessionLifecycleNow(resetsResolutionFallbacks: Bool = false) {
        guard tailReader != nil else {
            return
        }
        let generation = tailReaderGeneration

        Task { @MainActor [weak self] in
            guard let self,
                  tailReaderGeneration == generation else {
                return
            }
            if resetsResolutionFallbacks {
                await sessionLifecycleReader.resetResolutionFallbacks()
            }
            guard !Task.isCancelled,
                  tailReaderGeneration == generation else {
                return
            }
            await reconcileSessionLifecycles(generation: generation)
        }
    }

    private func reconcileSessionLifecycles(generation: UInt64) async {
        guard generation == tailReaderGeneration,
              tailReader != nil,
              !isBootstrapping else {
            return
        }
        let references = tasks.values.compactMap(\.turnReference)
        guard !references.isEmpty else {
            return
        }
        let states = await sessionLifecycleReader.lifecycleStates(for: references)
        guard !Task.isCancelled,
              generation == tailReaderGeneration,
              tailReader != nil,
              !isBootstrapping,
              !states.isEmpty else {
            return
        }

        var didChange = false
        var transitions: [CodexActivityTransition] = []
        for state in states {
            let key = CodexActivityTaskKey.turn(session: state.sessionId, turn: state.turnId)
            guard var task = tasks[key] else {
                continue
            }

            if task.startedAt == nil,
               let startedAt = state.startedAt,
               startedAt <= task.lastActivityAt.addingTimeInterval(1) {
                task.startedAt = startedAt
                tasks[key] = task
                didChange = true
            }

            guard let terminal = state.terminal else {
                continue
            }
            switch terminal {
            case .aborted:
                tasks.removeValue(forKey: key)
                // 中断不是完成，不发布 transition，也不产生绿色状态或通知。
                didChange = true
            case let .completed(completedAt, duration):
                if recentCompletionDate(for: key) != nil {
                    // 迟到事件恢复出的任务不能被 rollout 再次完成。
                    tasks.removeValue(forKey: key)
                    didChange = true
                    continue
                }
                guard let completion = completeTask(
                    key: key,
                    completedAt: completedAt,
                    reportedDuration: duration
                ) else {
                    continue
                }
                didChange = true
                if let sessionTransitionNotBefore,
                   completion.completedAt >= sessionTransitionNotBefore {
                    transitions.append(.completed(completion))
                }
            }
        }

        if didChange {
            refreshSnapshot(now: Date())
        }
        for transition in transitions {
            transitionSubject.send(transition)
        }
    }

    private func consume(_ batch: HookEventBatch) {
        switch batch {
        case .bootstrapStart:
            isBootstrapping = true
            sessionTransitionNotBefore = nil
            tasks.removeAll()
            completions.removeAll()
            recentlyCompletedTaskAt.removeAll()
        case let .bootstrapEvents(events):
            for event in events {
                _ = apply(event)
            }
        case .bootstrapEnd:
            isBootstrapping = false
            sessionTransitionNotBefore = Date()
            refreshSnapshot(now: Date())
            refreshSessionLifecycleNow()
            backfillPromptStartTimesFromHistory()
        case let .live(events):
            var transitions: [CodexActivityLiveTransition] = []
            for event in events {
                if let transition = apply(event) {
                    transitions.append(transition)
                }
            }

            refreshSnapshot(now: Date())
            publishLiveTransitions(transitions)
        }
    }

    /// bootstrap 只覆盖 24 小时窗口；窗口内恢复出的无起点任务向更早日期回查 Prompt 起点。
    private func backfillPromptStartTimesFromHistory() {
        let references = tasks.values.compactMap(\.promptReference)
        guard !references.isEmpty, let reader = tailReader else {
            return
        }
        let generation = tailReaderGeneration

        Task { @MainActor [weak self] in
            let startTimes = await reader.findPromptStartTimes(for: references)
            guard let self,
                  tailReaderGeneration == generation,
                  !isBootstrapping,
                  !startTimes.isEmpty else {
                return
            }
            backfillStartTimes(startTimes)
        }
    }

    private func backfillStartTimes(_ startTimes: [CodexActivityPromptReference: Date]) {
        var didChange = false
        for (reference, startedAt) in startTimes {
            let key = CodexActivityTaskKey.turn(session: reference.sessionId, turn: reference.turnId)
            guard var task = tasks[key],
                  task.startedAt == nil,
                  startedAt <= task.lastActivityAt else {
                continue
            }
            task.startedAt = startedAt
            tasks[key] = task
            didChange = true
        }
        if didChange {
            refreshSnapshot(now: Date())
        }
    }

    private func apply(_ event: WorkflowHookEvent) -> CodexActivityLiveTransition? {
        switch event.hookEvent {
        case .userPromptSubmit:
            startTask(from: event)
        case .preToolUse:
            resumeTask(from: event, latestEvent: .toolStarted, allowsRecovery: true)
        case .postToolUse:
            resumeTask(from: event, latestEvent: .toolFinished, allowsRecovery: true)
        case .preCompact:
            resumeTask(from: event, latestEvent: .compactionStarted, allowsRecovery: true)
        case .postCompact:
            resumeTask(from: event, latestEvent: .compactionFinished, allowsRecovery: true)
        case .subagentStart:
            // 子智能体只更新所属顶层任务，不自行创建一条并发任务。
            resumeTask(from: event, latestEvent: .subagentStarted, allowsRecovery: false)
        case .subagentStop:
            resumeTask(from: event, latestEvent: .subagentFinished, allowsRecovery: false)
        case .permissionRequest:
            return waitForApproval(from: event)
        case .stop:
            return completeTask(from: event)
        case .sessionStart, .none:
            break
        }
        return nil
    }

    private func startTask(from event: WorkflowHookEvent) {
        let key = CodexActivityTaskKey(event: event)
        if let completedAt = recentCompletionDate(for: key),
           event.timestamp <= completedAt {
            return
        }
        if let existing = tasks[key], event.timestamp < existing.lastActivityAt {
            return
        }

        if let sessionId = key.sessionId {
            // 同一 session 的 turn 按顺序执行。新 prompt 代表旧 turn 已被中断，
            // 即使旧 turn 没有 Stop，也不能继续显示为并发运行任务。
            guard !tasks.values.contains(where: {
                $0.key.sessionId == sessionId && $0.lastActivityAt > event.timestamp
            }) else {
                return
            }
            tasks = tasks.filter { taskKey, _ in
                taskKey == key || taskKey.sessionId != sessionId
            }
        }

        recentlyCompletedTaskAt.removeValue(forKey: key)
        if let sessionId = key.sessionId {
            // 缺少 turn 的 Stop 会使用 session 键；新 turn 开始后允许该键再次完成。
            recentlyCompletedTaskAt.removeValue(forKey: .session(sessionId))
        }

        tasks[key] = CodexActivityTask(
            key: key,
            event: event,
            state: .running,
            latestEvent: .promptSubmitted,
            startedAt: event.timestamp
        )
    }

    private func resumeTask(
        from event: WorkflowHookEvent,
        latestEvent: CodexActivityEvent,
        allowsRecovery: Bool
    ) {
        let eventKey = CodexActivityTaskKey(event: event)
        guard recentCompletionDate(for: eventKey) == nil else {
            return
        }

        if let key = matchingTaskKey(for: event), var task = tasks[key] {
            guard event.timestamp >= task.lastActivityAt else {
                return
            }

            if task.state != .running {
                task.state = .running
                task.stateChangedAt = event.timestamp
            }
            task.latestEvent = latestEvent
            task.mergeMetadata(from: event)
            task.lastActivityAt = event.timestamp
            tasks[key] = task
            return
        }

        guard allowsRecovery else {
            return
        }

        tasks[eventKey] = CodexActivityTask(
            key: eventKey,
            event: event,
            state: .running,
            latestEvent: latestEvent,
            startedAt: nil
        )
    }

    private func waitForApproval(from event: WorkflowHookEvent) -> CodexActivityLiveTransition? {
        let eventKey = CodexActivityTaskKey(event: event)
        guard recentCompletionDate(for: eventKey) == nil else {
            return nil
        }

        if let key = matchingTaskKey(for: event), var task = tasks[key] {
            guard event.timestamp >= task.lastActivityAt else {
                return nil
            }

            let wasWaiting = task.state == .waitingApproval
            if !wasWaiting {
                task.state = .waitingApproval
                task.stateChangedAt = event.timestamp
            }
            task.latestEvent = .approvalRequested
            task.mergeMetadata(from: event)
            // 权限事件描述当前请求；缺失工具名时不能沿用上一条工具事件。
            task.toolName = event.toolName
            task.lastActivityAt = event.timestamp
            tasks[key] = task
            return wasWaiting ? nil : .waitingApproval(key)
        }

        let task = CodexActivityTask(
            key: eventKey,
            event: event,
            state: .waitingApproval,
            latestEvent: .approvalRequested,
            startedAt: nil
        )
        tasks[eventKey] = task
        return .waitingApproval(eventKey)
    }

    private func completeTask(from event: WorkflowHookEvent) -> CodexActivityLiveTransition? {
        let eventKey = CodexActivityTaskKey(event: event)
        guard recentCompletionDate(for: eventKey) == nil else {
            // 清掉旧版本或异常顺序留下的同键恢复任务。
            tasks.removeValue(forKey: eventKey)
            return nil
        }

        let matchedKey = matchingTaskKey(for: event)
        let task = matchedKey.flatMap { tasks[$0] }
        if let task, event.timestamp < task.lastActivityAt {
            return nil
        }

        let key = matchedKey ?? eventKey
        guard recentCompletionDate(for: key) == nil else {
            if let matchedKey {
                tasks.removeValue(forKey: matchedKey)
            }
            return nil
        }

        if let matchedKey {
            tasks.removeValue(forKey: matchedKey)
        }

        let duration = task?.preciseDuration(until: event.timestamp)

        let completion = storeCompletion(
            key: key,
            projectName: event.projectDisplayName ?? task?.projectName,
            completedAt: event.timestamp,
            duration: duration
        )
        recordCompletedTask(eventKey, at: event.timestamp)
        recordCompletedTask(key, at: event.timestamp)
        return .completed(completion)
    }

    private func completeTask(
        key: CodexActivityTaskKey,
        completedAt: Date,
        reportedDuration: TimeInterval?
    ) -> CodexActivityCompletion? {
        guard let task = tasks.removeValue(forKey: key) else {
            return nil
        }

        // rollout 时间戳是整秒，避免因为同一秒内的 Hook 毫秒时间戳而把完成时间记在最后活动之前。
        let recordedCompletedAt = max(completedAt, task.lastActivityAt)
        let duration = reportedDuration ?? task.preciseDuration(until: recordedCompletedAt)

        let completion = storeCompletion(
            key: key,
            projectName: task.projectName,
            completedAt: recordedCompletedAt,
            duration: duration
        )
        recordCompletedTask(key, at: recordedCompletedAt)
        return completion
    }

    /// 精确 turn 失败后回退同 session 最近活动，再回退同项目匿名任务。
    private func matchingTaskKey(for event: WorkflowHookEvent) -> CodexActivityTaskKey? {
        let exactKey = CodexActivityTaskKey(event: event)
        if tasks[exactKey] != nil {
            return exactKey
        }

        if let sessionId = event.sessionId,
           let match = tasks.values
           .filter({ $0.key.sessionId == sessionId })
           .max(by: { $0.lastActivityAt < $1.lastActivityAt }) {
            return match.key
        }

        let anonymousKey = CodexActivityTaskKey.anonymous(
            project: CodexActivityTaskKey.projectIdentifier(event.projectDisplayName)
        )
        return tasks[anonymousKey] == nil ? nil : anonymousKey
    }

    private func refreshSnapshot(now: Date) {
        pruneExpiredState(now: now)

        let waitingTasks = tasks.values.filter { $0.state == .waitingApproval }
        let runningTasks = tasks.values.filter { $0.state == .running }
        let mostRecentCompletion = completions.max { $0.completedAt < $1.completedAt }

        let newSnapshot = CodexActivitySnapshot(
            primaryWaitingTask: waitingTasks.max(by: { $0.lastActivityAt < $1.lastActivityAt })?.snapshot,
            primaryRunningTask: runningTasks.max(by: { $0.lastActivityAt < $1.lastActivityAt })?.snapshot,
            mostRecentCompletion: mostRecentCompletion,
            waitingCount: waitingTasks.count,
            runningCount: runningTasks.count,
            isCompletionHighlighted: mostRecentCompletion.map {
                now < $0.completedAt.addingTimeInterval(Self.completionHighlightDuration)
            } ?? false
        )
        if newSnapshot != snapshot {
            snapshot = newSnapshot
        }

        scheduleNextCleanup(now: now, mostRecentCompletion: mostRecentCompletion)
    }

    private func pruneExpiredState(now: Date) {
        let activityCutoff = now.addingTimeInterval(-Self.activityRetention)
        tasks = tasks.filter { $0.value.lastActivityAt > activityCutoff }

        let completionCutoff = now.addingTimeInterval(-Self.completionRetention)
        completions.removeAll { $0.completedAt <= completionCutoff }

        let completedTaskCutoff = now.addingTimeInterval(-Self.completedTaskRetention)
        recentlyCompletedTaskAt = recentlyCompletedTaskAt.filter {
            $0.value > completedTaskCutoff
        }
    }

    private func scheduleNextCleanup(
        now: Date,
        mostRecentCompletion: CodexActivityCompletion?
    ) {
        var deadlines = tasks.values.map {
            $0.lastActivityAt.addingTimeInterval(Self.activityRetention)
        }
        deadlines.append(contentsOf: completions.map {
            $0.completedAt.addingTimeInterval(Self.completionRetention)
        })
        deadlines.append(contentsOf: recentlyCompletedTaskAt.values.map {
            $0.addingTimeInterval(Self.completedTaskRetention)
        })
        if let mostRecentCompletion {
            let highlightDeadline = mostRecentCompletion.completedAt
                .addingTimeInterval(Self.completionHighlightDuration)
            if highlightDeadline > now {
                deadlines.append(highlightDeadline)
            }
        }

        guard let nextDeadline = deadlines.filter({ $0 > now }).min() else {
            cleanupTask?.cancel()
            cleanupTask = nil
            cleanupDeadline = nil
            return
        }
        guard cleanupTask == nil || cleanupDeadline != nextDeadline else {
            return
        }

        cleanupTask?.cancel()
        cleanupDeadline = nextDeadline
        cleanupTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(max(0, nextDeadline.timeIntervalSinceNow)))
            guard let self, !Task.isCancelled else {
                return
            }
            cleanupTask = nil
            cleanupDeadline = nil
            refreshSnapshot(now: Date())
        }
    }

    private static let completionHighlightDuration: TimeInterval = 20
    private static let completionRetention: TimeInterval = 5 * 60
    private static let completedTaskRetention: TimeInterval = 24 * 60 * 60
    private static let activityRetention: TimeInterval = 24 * 60 * 60
    private static let sessionLifecyclePollInterval: TimeInterval = 2
}

private extension CodexActivityMonitor {
    func storeCompletion(
        key: CodexActivityTaskKey,
        projectName: String?,
        completedAt: Date,
        duration: TimeInterval?
    ) -> CodexActivityCompletion {
        let completion = CodexActivityCompletion(
            id: "\(key.identifier)|\(Int64((completedAt.timeIntervalSince1970 * 1000).rounded()))",
            projectName: projectName,
            completedAt: completedAt,
            duration: duration
        )
        completions.removeAll { $0.id == completion.id }
        completions.append(completion)
        return completion
    }

    func recentCompletionDate(
        for key: CodexActivityTaskKey,
        now: Date = Date()
    ) -> Date? {
        guard let completedAt = recentlyCompletedTaskAt[key] else {
            return nil
        }
        guard completedAt > now.addingTimeInterval(-Self.completedTaskRetention) else {
            recentlyCompletedTaskAt.removeValue(forKey: key)
            return nil
        }
        return completedAt
    }

    func recordCompletedTask(_ key: CodexActivityTaskKey, at completedAt: Date) {
        recentlyCompletedTaskAt[key] = max(
            recentlyCompletedTaskAt[key] ?? .distantPast,
            completedAt
        )
        if let sessionId = key.sessionId {
            let sessionKey = CodexActivityTaskKey.session(sessionId)
            recentlyCompletedTaskAt[sessionKey] = max(
                recentlyCompletedTaskAt[sessionKey] ?? .distantPast,
                completedAt
            )
        }
    }

    func publishLiveTransitions(_ transitions: [CodexActivityLiveTransition]) {
        var lastWaitingIndexByKey: [CodexActivityTaskKey: Int] = [:]
        for (index, transition) in transitions.enumerated() {
            if case let .waitingApproval(key) = transition {
                lastWaitingIndexByKey[key] = index
            }
        }

        var publishedCompletionIDs = Set<String>()
        for (index, transition) in transitions.enumerated() {
            switch transition {
            case let .waitingApproval(key):
                guard lastWaitingIndexByKey[key] == index,
                      let task = tasks[key],
                      task.state == .waitingApproval else {
                    continue
                }
                transitionSubject.send(.waitingApproval(task.snapshot))
            case let .completed(completion):
                guard publishedCompletionIDs.insert(completion.id).inserted else {
                    continue
                }
                transitionSubject.send(.completed(completion))
            }
        }
    }
}

private enum CodexActivityTaskKey: Hashable {
    case turn(session: String, turn: String)
    case session(String)
    case anonymous(project: String)

    init(event: WorkflowHookEvent) {
        if let sessionId = event.sessionId, let turnId = event.turnId {
            self = .turn(session: sessionId, turn: turnId)
        } else if let sessionId = event.sessionId {
            self = .session(sessionId)
        } else {
            self = .anonymous(project: Self.projectIdentifier(event.projectDisplayName))
        }
    }

    var sessionId: String? {
        switch self {
        case let .turn(session, _), let .session(session): session
        case .anonymous: nil
        }
    }

    var isAnonymous: Bool {
        if case .anonymous = self {
            return true
        }
        return false
    }

    var identifier: String {
        switch self {
        case let .turn(session, turn): "turn|\(session)|\(turn)"
        case let .session(session): "session|\(session)"
        case let .anonymous(project): "project|\(project)"
        }
    }

    static func projectIdentifier(_ project: String?) -> String {
        project ?? "__codex__"
    }
}

private enum CodexActivityLiveTransition {
    case waitingApproval(CodexActivityTaskKey)
    case completed(CodexActivityCompletion)
}

private enum CodexActivityTaskState {
    case running
    case waitingApproval
}

private struct CodexActivityTask {
    let key: CodexActivityTaskKey
    var state: CodexActivityTaskState
    var latestEvent: CodexActivityEvent
    var projectName: String?
    var modelName: String?
    var toolName: String?
    var startedAt: Date?
    var stateChangedAt: Date
    var lastActivityAt: Date

    init(
        key: CodexActivityTaskKey,
        event: WorkflowHookEvent,
        state: CodexActivityTaskState,
        latestEvent: CodexActivityEvent,
        startedAt: Date?
    ) {
        self.key = key
        self.state = state
        self.latestEvent = latestEvent
        projectName = event.projectDisplayName
        modelName = event.modelName
        toolName = event.toolName
        self.startedAt = startedAt
        stateChangedAt = event.timestamp
        lastActivityAt = event.timestamp
    }

    var showsPreciseDuration: Bool {
        startedAt != nil && !key.isAnonymous
    }

    /// 起点可信时返回到 end 的精确耗时，起点缺失或晚于 end 时为 nil。
    func preciseDuration(until end: Date) -> TimeInterval? {
        guard showsPreciseDuration, let startedAt, end >= startedAt else {
            return nil
        }
        return end.timeIntervalSince(startedAt)
    }

    var snapshot: CodexActivityTaskSnapshot {
        CodexActivityTaskSnapshot(
            latestEvent: latestEvent,
            projectName: projectName,
            modelName: modelName,
            toolName: toolName,
            startedAt: startedAt,
            stateChangedAt: stateChangedAt,
            showsPreciseDuration: showsPreciseDuration
        )
    }

    var turnReference: CodexActivityTurnReference? {
        guard case let .turn(sessionId, turnId) = key else {
            return nil
        }
        return CodexActivityTurnReference(
            sessionId: sessionId,
            turnId: turnId,
            startedAt: startedAt ?? lastActivityAt
        )
    }

    var promptReference: CodexActivityPromptReference? {
        guard startedAt == nil,
              case let .turn(sessionId, turnId) = key else {
            return nil
        }
        return CodexActivityPromptReference(sessionId: sessionId, turnId: turnId)
    }

    mutating func mergeMetadata(from event: WorkflowHookEvent) {
        projectName = event.projectDisplayName ?? projectName
        modelName = event.modelName ?? modelName
        toolName = event.toolName ?? toolName
    }
}
