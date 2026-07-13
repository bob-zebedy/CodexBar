import AppKit
import Combine
import Foundation

/// 从本机 Hook JSONL 维护进程内实时任务状态，是菜单栏、活动卡片、通知和触觉反馈的唯一任务状态来源。
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
    private var pendingTerminalTasks: [CodexActivityTaskKey: PendingTerminalTask] = [:]
    private var completions: [CodexActivityCompletion] = []
    private var terminations: [CodexActivityTermination] = []
    private var recentlyCompletedTaskAt: [CodexActivityTaskKey: Date] = [:]
    private var recentlyTerminatedTaskAt: [CodexActivityTaskKey: Date] = [:]
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
        clearCollectedActivityState()
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
            + pendingTerminalTasks.values.compactMap(\.task.turnReference)
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
            if var pending = pendingTerminalTasks[key] {
                if let startedAt = Self.backfilledStartedAt(for: pending.task, state: state) {
                    pending.task.startedAt = startedAt
                    pendingTerminalTasks[key] = pending
                }

                guard let terminal = state.terminal else {
                    continue
                }
                pendingTerminalTasks.removeValue(forKey: key)
                resolveTerminal(
                    terminal,
                    task: pending.task,
                    key: key,
                    abortFallback: pending.supersededAt,
                    into: &transitions
                )
                didChange = true
                continue
            }

            guard var task = tasks[key] else {
                continue
            }

            var taskDidChange = false
            if let startedAt = Self.backfilledStartedAt(for: task, state: state) {
                task.startedAt = startedAt
                taskDidChange = true
            }

            if let terminal = state.terminal {
                tasks.removeValue(forKey: key)
                didChange = true
                if case .completed = terminal, recentCompletionDate(for: key) != nil {
                    // 迟到事件恢复出的任务不能被 rollout 再次完成。
                    continue
                }
                resolveTerminal(
                    terminal,
                    task: task,
                    key: key,
                    abortFallback: Date(),
                    into: &transitions
                )
                continue
            }

            if let approvalReviewer = state.approvalReviewer,
               task.approvalReviewer != approvalReviewer {
                task.approvalReviewer = approvalReviewer
                taskDidChange = true
            }

            if resolvePendingApprovalIfPossible(
                for: &task,
                into: &transitions
            ) {
                taskDidChange = true
            }

            if taskDidChange {
                tasks[key] = task
                didChange = true
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
            clearCollectedActivityState()
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
            let pendingKeysBefore = Set(pendingTerminalTasks.keys)
            var transitions: [CodexActivityLiveTransition] = []
            for event in events {
                if let transition = apply(event) {
                    transitions.append(transition)
                }
            }

            refreshSnapshot(now: Date())
            publishLiveTransitions(transitions)
            if !pendingTerminalTasks.isEmpty {
                // 只有刚进入终态确认窗口的任务需要重置解析缓存重试定位 rollout；
                // 窗口期内的后续批次只做即时查询，避免反复递归扫描 sessions。
                let hasNewPendingTasks = !Set(pendingTerminalTasks.keys)
                    .subtracting(pendingKeysBefore).isEmpty
                refreshSessionLifecycleNow(resetsResolutionFallbacks: hasNewPendingTasks)
            }
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
        let displayID = tasks[key]?.displayID ?? UUID()
        if let completedAt = recentCompletionDate(for: key),
           event.timestamp <= completedAt {
            return
        }
        if let terminatedAt = recentTerminationDate(for: key),
           event.timestamp <= terminatedAt {
            return
        }
        if let existing = tasks[key], event.timestamp < existing.lastActivityAt {
            return
        }

        if let sessionId = key.sessionId {
            // 同一 session 的 turn 按顺序执行。新 prompt 让旧 turn 立即退出活动列表，
            // 但保留短暂终态确认窗口，避免把迟到的正常完成误记为终止。
            guard !tasks.values.contains(where: {
                $0.key.sessionId == sessionId && $0.lastActivityAt > event.timestamp
            }) else {
                return
            }
            let supersededTasks = tasks.values.filter {
                $0.key != key && $0.key.sessionId == sessionId
            }
            for task in supersededTasks {
                pendingTerminalTasks[task.key] = PendingTerminalTask(
                    task: task,
                    supersededAt: event.timestamp,
                    deadline: Date().addingTimeInterval(Self.supersededTerminalGracePeriod)
                )
            }
            tasks = tasks.filter { taskKey, _ in
                taskKey == key || taskKey.sessionId != sessionId
            }
        }

        recentlyCompletedTaskAt.removeValue(forKey: key)
        recentlyTerminatedTaskAt.removeValue(forKey: key)
        if let sessionId = key.sessionId {
            // 缺少 turn 的 Stop 会使用 session 键；新 turn 开始后允许该键再次完成。
            recentlyCompletedTaskAt.removeValue(forKey: .session(sessionId))
            recentlyTerminatedTaskAt.removeValue(forKey: .session(sessionId))
        }

        tasks[key] = CodexActivityTask(
            displayID: displayID,
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
        guard recentCompletionDate(for: eventKey) == nil,
              recentTerminationDate(for: eventKey) == nil,
              pendingTerminalTasks[eventKey] == nil else {
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
            task.pendingApprovalRequestedAt = nil
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
            displayID: UUID(),
            key: eventKey,
            event: event,
            state: .running,
            latestEvent: latestEvent,
            startedAt: nil
        )
    }

    private func waitForApproval(from event: WorkflowHookEvent) -> CodexActivityLiveTransition? {
        let eventKey = CodexActivityTaskKey(event: event)
        guard recentCompletionDate(for: eventKey) == nil,
              recentTerminationDate(for: eventKey) == nil,
              pendingTerminalTasks[eventKey] == nil else {
            return nil
        }

        if let key = matchingTaskKey(for: event), var task = tasks[key] {
            guard event.timestamp >= task.lastActivityAt else {
                return nil
            }

            task.mergeMetadata(from: event)
            // 权限事件描述当前请求；缺失工具名时不能沿用上一条工具事件。
            task.toolName = event.toolName
            task.lastActivityAt = event.timestamp
            let enteredWaiting = task.recordApprovalRequest(at: event.timestamp)
            tasks[key] = task
            return enteredWaiting ? .waitingApproval(key) : nil
        }

        var task = CodexActivityTask(
            displayID: UUID(),
            key: eventKey,
            event: event,
            state: .running,
            latestEvent: .toolStarted,
            startedAt: nil
        )
        let enteredWaiting = task.recordApprovalRequest(at: event.timestamp)
        tasks[eventKey] = task
        return enteredWaiting ? .waitingApproval(eventKey) : nil
    }

    private func completeTask(from event: WorkflowHookEvent) -> CodexActivityLiveTransition? {
        let eventKey = CodexActivityTaskKey(event: event)
        guard recentCompletionDate(for: eventKey) == nil else {
            // 清掉旧版本或异常顺序留下的同键恢复任务。
            tasks.removeValue(forKey: eventKey)
            return nil
        }
        guard recentTerminationDate(for: eventKey) == nil else {
            return nil
        }

        if let pending = pendingTerminalTasks[eventKey] {
            guard event.timestamp >= pending.task.lastActivityAt else {
                return nil
            }
            pendingTerminalTasks.removeValue(forKey: eventKey)
            let completion = storeResolvedCompletion(
                pending.task,
                key: eventKey,
                completedAt: event.timestamp,
                reportedDuration: nil,
                projectName: event.projectDisplayName,
                modelName: event.modelName
            )
            return .completed(completion)
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
            projectName: event.projectDisplayName ?? task?.projectName,
            modelName: event.modelName ?? task?.modelName,
            completedAt: event.timestamp,
            duration: duration
        )
        recordCompletedTask(eventKey, at: event.timestamp)
        recordCompletedTask(key, at: event.timestamp)
        return .completed(completion)
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

        let waitingTasks = sortedTasks(in: .waitingApproval)
        let runningTasks = sortedTasks(in: .running)
        let recentCompletions = completions.sorted(by: Self.recentFirst(\.completedAt, \.id))
        let recentTerminations = terminations.sorted(by: Self.recentFirst(\.terminatedAt, \.id))
        let mostRecentCompletion = recentCompletions.first

        let newSnapshot = CodexActivitySnapshot(
            waitingTasks: waitingTasks.map(\.snapshot),
            runningTasks: runningTasks.map(\.snapshot),
            recentCompletions: recentCompletions,
            recentTerminations: recentTerminations,
            isCompletionHighlighted: mostRecentCompletion.map {
                now < $0.completedAt.addingTimeInterval(Self.completionHighlightDuration)
            } ?? false
        )
        if newSnapshot != snapshot {
            snapshot = newSnapshot
        }

        scheduleNextCleanup(now: now, mostRecentCompletion: mostRecentCompletion)
    }

    private func sortedTasks(in state: CodexActivityTaskState) -> [CodexActivityTask] {
        tasks.values
            .filter { $0.state == state }
            .sorted(by: Self.recentFirst(\.lastActivityAt, \.displayID))
    }

    /// 时间相同再按 UUID 字符串排序（Swift sort 不稳定），保证快照对 SwiftUI diff 稳定。
    private static func recentFirst<Element>(
        _ date: KeyPath<Element, Date>,
        _ id: KeyPath<Element, UUID>
    ) -> (Element, Element) -> Bool {
        { lhs, rhs in
            if lhs[keyPath: date] != rhs[keyPath: date] {
                return lhs[keyPath: date] > rhs[keyPath: date]
            }
            return lhs[keyPath: id].uuidString < rhs[keyPath: id].uuidString
        }
    }

    private func pruneExpiredState(now: Date) {
        finalizeExpiredPendingTerminalTasks(now: now)

        let activityCutoff = now.addingTimeInterval(-Self.activityRetention)
        tasks = tasks.filter { $0.value.lastActivityAt > activityCutoff }

        let historyCutoff = now.addingTimeInterval(-Self.recentHistoryRetention)
        completions.removeAll { $0.completedAt <= historyCutoff }
        terminations.removeAll { $0.terminatedAt <= historyCutoff }

        let completedTaskCutoff = now.addingTimeInterval(-Self.completedTaskRetention)
        recentlyCompletedTaskAt = recentlyCompletedTaskAt.filter {
            $0.value > completedTaskCutoff
        }
        recentlyTerminatedTaskAt = recentlyTerminatedTaskAt.filter {
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
            $0.completedAt.addingTimeInterval(Self.recentHistoryRetention)
        })
        deadlines.append(contentsOf: terminations.map {
            $0.terminatedAt.addingTimeInterval(Self.recentHistoryRetention)
        })
        deadlines.append(contentsOf: pendingTerminalTasks.values.map(\.deadline))
        deadlines.append(contentsOf: recentlyCompletedTaskAt.values.map {
            $0.addingTimeInterval(Self.completedTaskRetention)
        })
        deadlines.append(contentsOf: recentlyTerminatedTaskAt.values.map {
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

    private static let completionHighlightDuration: TimeInterval = 30
    private static let recentHistoryRetention: TimeInterval = 10 * 60
    private static let completedTaskRetention: TimeInterval = 24 * 60 * 60
    private static let activityRetention: TimeInterval = 24 * 60 * 60
    private static let supersededTerminalGracePeriod: TimeInterval = 5
    private static let sessionLifecyclePollInterval: TimeInterval = 1
}

private extension CodexActivityMonitor {
    /// PermissionRequest 表示进入审批流程；只有 rollout 明确把审批路由给 user 时才是 UI 等待。
    func resolvePendingApprovalIfPossible(
        for task: inout CodexActivityTask,
        into transitions: inout [CodexActivityTransition]
    ) -> Bool {
        guard let requestedAt = task.pendingApprovalRequestedAt,
              let approvalReviewer = task.approvalReviewer else {
            return false
        }

        switch approvalReviewer {
        case .user:
            let wasWaiting = task.state == .waitingApproval
            task.confirmPendingApproval()
            if !wasWaiting,
               let sessionTransitionNotBefore,
               requestedAt >= sessionTransitionNotBefore {
                transitions.append(.waitingApproval(task.snapshot))
            }
        case .autoReview, .guardianSubagent:
            task.pendingApprovalRequestedAt = nil
        }
        return true
    }

    /// rollout 终态归类的唯一入口；活动任务和等待终态确认任务只有 abort 兜底时间不同。
    /// 终止记录只供任务中心展示，不发布 transition，也不产生绿色状态或通知。
    func resolveTerminal(
        _ terminal: CodexSessionTaskTerminalState,
        task: CodexActivityTask,
        key: CodexActivityTaskKey,
        abortFallback: Date,
        into transitions: inout [CodexActivityTransition]
    ) {
        switch terminal {
        case let .aborted(reportedAt):
            let terminatedAt = max(reportedAt ?? abortFallback, task.lastActivityAt)
            storeTermination(task, at: terminatedAt, includesDuration: reportedAt != nil)
            recordTerminatedTask(key, at: terminatedAt)
        case let .completed(completedAt, duration):
            let completion = storeResolvedCompletion(
                task,
                key: key,
                completedAt: completedAt,
                reportedDuration: duration
            )
            if let sessionTransitionNotBefore,
               completion.completedAt >= sessionTransitionNotBefore {
                transitions.append(.completed(completion))
            }
        }
    }

    static func backfilledStartedAt(
        for task: CodexActivityTask,
        state: CodexSessionTaskLifecycleState
    ) -> Date? {
        guard task.startedAt == nil,
              let startedAt = state.startedAt,
              startedAt <= task.lastActivityAt.addingTimeInterval(1) else {
            return nil
        }
        return startedAt
    }

    func storeResolvedCompletion(
        _ task: CodexActivityTask,
        key: CodexActivityTaskKey,
        completedAt: Date,
        reportedDuration: TimeInterval?,
        projectName: String? = nil,
        modelName: String? = nil
    ) -> CodexActivityCompletion {
        // rollout 时间戳是整秒，避免因为同一秒内的 Hook 毫秒时间戳而把完成时间记在最后活动之前。
        let recordedCompletedAt = max(completedAt, task.lastActivityAt)
        let completion = storeCompletion(
            projectName: projectName ?? task.projectName,
            modelName: modelName ?? task.modelName,
            completedAt: recordedCompletedAt,
            duration: reportedDuration ?? task.preciseDuration(until: recordedCompletedAt)
        )
        recordCompletedTask(key, at: recordedCompletedAt)
        return completion
    }

    func storeCompletion(
        projectName: String?,
        modelName: String?,
        completedAt: Date,
        duration: TimeInterval?
    ) -> CodexActivityCompletion {
        let completion = CodexActivityCompletion(
            id: UUID(),
            projectName: projectName,
            modelName: modelName,
            completedAt: completedAt,
            duration: duration
        )
        completions.append(completion)
        return completion
    }

    func storeTermination(
        _ task: CodexActivityTask,
        at terminatedAt: Date,
        includesDuration: Bool
    ) {
        let termination = CodexActivityTermination(
            id: UUID(),
            projectName: task.projectName,
            modelName: task.modelName,
            terminatedAt: terminatedAt,
            duration: includesDuration ? task.preciseDuration(until: terminatedAt) : nil
        )
        terminations.append(termination)
    }

    func recentCompletionDate(
        for key: CodexActivityTaskKey,
        now: Date = Date()
    ) -> Date? {
        Self.recentTerminalDate(
            for: key,
            storedIn: &recentlyCompletedTaskAt,
            now: now
        )
    }

    func recentTerminationDate(
        for key: CodexActivityTaskKey,
        now: Date = Date()
    ) -> Date? {
        Self.recentTerminalDate(
            for: key,
            storedIn: &recentlyTerminatedTaskAt,
            now: now
        )
    }

    func recordCompletedTask(_ key: CodexActivityTaskKey, at completedAt: Date) {
        Self.recordTerminalTask(
            key,
            at: completedAt,
            storedIn: &recentlyCompletedTaskAt
        )
    }

    func recordTerminatedTask(_ key: CodexActivityTaskKey, at terminatedAt: Date) {
        Self.recordTerminalTask(
            key,
            at: terminatedAt,
            storedIn: &recentlyTerminatedTaskAt
        )
    }

    func clearCollectedActivityState() {
        tasks.removeAll()
        pendingTerminalTasks.removeAll()
        completions.removeAll()
        terminations.removeAll()
        recentlyCompletedTaskAt.removeAll()
        recentlyTerminatedTaskAt.removeAll()
    }

    static func recentTerminalDate(
        for key: CodexActivityTaskKey,
        storedIn dates: inout [CodexActivityTaskKey: Date],
        now: Date
    ) -> Date? {
        guard let date = dates[key] else {
            return nil
        }
        guard date > now.addingTimeInterval(-completedTaskRetention) else {
            dates.removeValue(forKey: key)
            return nil
        }
        return date
    }

    static func recordTerminalTask(
        _ key: CodexActivityTaskKey,
        at date: Date,
        storedIn dates: inout [CodexActivityTaskKey: Date]
    ) {
        dates[key] = max(dates[key] ?? .distantPast, date)
        if let sessionId = key.sessionId {
            let sessionKey = CodexActivityTaskKey.session(sessionId)
            dates[sessionKey] = max(dates[sessionKey] ?? .distantPast, date)
        }
    }

    func finalizeExpiredPendingTerminalTasks(now: Date) {
        let expiredKeys = pendingTerminalTasks.compactMap { key, pending in
            pending.deadline <= now ? key : nil
        }
        for key in expiredKeys {
            guard let pending = pendingTerminalTasks.removeValue(forKey: key) else {
                continue
            }
            let terminatedAt = max(pending.supersededAt, pending.task.lastActivityAt)
            storeTermination(pending.task, at: terminatedAt, includesDuration: true)
            recordTerminatedTask(key, at: terminatedAt)
        }
    }

    func publishLiveTransitions(_ transitions: [CodexActivityLiveTransition]) {
        var lastWaitingIndexByKey: [CodexActivityTaskKey: Int] = [:]
        for (index, transition) in transitions.enumerated() {
            if case let .waitingApproval(key) = transition {
                lastWaitingIndexByKey[key] = index
            }
        }

        var publishedCompletionIDs = Set<UUID>()
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

private struct PendingTerminalTask {
    var task: CodexActivityTask
    let supersededAt: Date
    let deadline: Date
}

private struct CodexActivityTask {
    let displayID: UUID
    let key: CodexActivityTaskKey
    var state: CodexActivityTaskState
    var latestEvent: CodexActivityEvent
    var projectName: String?
    var modelName: String?
    var toolName: String?
    var startedAt: Date?
    var stateChangedAt: Date
    var lastActivityAt: Date
    var approvalReviewer: CodexApprovalReviewer?
    var pendingApprovalRequestedAt: Date?

    init(
        displayID: UUID,
        key: CodexActivityTaskKey,
        event: WorkflowHookEvent,
        state: CodexActivityTaskState,
        latestEvent: CodexActivityEvent,
        startedAt: Date?
    ) {
        self.displayID = displayID
        self.key = key
        self.state = state
        self.latestEvent = latestEvent
        projectName = event.projectDisplayName
        modelName = event.modelName
        toolName = event.toolName
        self.startedAt = startedAt
        stateChangedAt = event.timestamp
        lastActivityAt = event.timestamp
        approvalReviewer = event.approvalReviewer
        pendingApprovalRequestedAt = nil
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
            id: displayID,
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
        approvalReviewer = event.approvalReviewer ?? approvalReviewer
    }

    /// 记录审批候选；返回值只表示任务是否刚刚进入用户等待状态。
    mutating func recordApprovalRequest(at requestedAt: Date) -> Bool {
        pendingApprovalRequestedAt = requestedAt
        guard approvalReviewer == .user else {
            return false
        }

        let enteredWaiting = state != .waitingApproval
        confirmPendingApproval()
        return enteredWaiting
    }

    mutating func confirmPendingApproval() {
        guard let requestedAt = pendingApprovalRequestedAt else {
            return
        }
        pendingApprovalRequestedAt = nil
        if state != .waitingApproval {
            state = .waitingApproval
            stateChangedAt = requestedAt
        }
        latestEvent = .approvalRequested
    }
}
