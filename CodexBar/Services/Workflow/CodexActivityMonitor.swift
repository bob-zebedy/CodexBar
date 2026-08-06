import AppKit
import Combine
import Foundation
import os

/// 从本机 Hook JSONL 维护进程内实时任务状态, 是菜单栏; 活动卡片; 通知和触觉反馈的唯一任务状态来源
@MainActor
final class CodexActivityMonitor: ObservableObject {
    @Published private(set) var snapshot = CodexActivitySnapshot.empty

    var transitionPublisher: AnyPublisher<CodexActivityTransition, Never> {
        transitionSubject.eraseToAnyPublisher()
    }

    var onInactivityProtectionTriggered: ((CodexActivityProtectionNotice) async -> Bool)?
    var onInactivityProtectionInvalidated: ((UUID, UUID) -> Void)?

    private let codexHookSettings: CodexHookSettings
    let activityProtectionSettings: ActivityProtectionSettings
    let activityProtectionStateStore: ActivityProtectionStateStore
    private let sessionLifecycleReader = CodexSessionLifecycleReader()
    let transitionSubject = PassthroughSubject<CodexActivityTransition, Never>()
    var tasks: [CodexActivityTaskKey: CodexActivityTask] = [:]
    var pendingTerminalTasks: [CodexActivityTaskKey: PendingTerminalTask] = [:]
    var completions: [CodexActivityCompletion] = []
    var terminations: [CodexActivityTermination] = []
    var recentlyCompletedTaskAt: [CodexActivityTaskKey: Date] = [:]
    var recentlyTerminatedTaskAt: [CodexActivityTaskKey: Date] = [:]
    var tailReader: HookEventTailReader?
    private var tailReaderControlTask: Task<Void, Never>?
    private var tailReaderGeneration: UInt64 = 0
    private var sessionLifecyclePollTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var cleanupDeadline: Date?
    var inactivityCheckTask: Task<Void, Never>?
    var inactivityCheckDeadline: Date?
    var activityProtectionAttempts: [CodexActivityTaskKey: ActivityProtectionAttempt] = [:]
    var activityProtectionNoticeAttemptIDs: [UUID: UUID] = [:]
    var activityProtectionRecords: [String: ActivityProtectionRecord] = [:]
    private var activityProtectionStateLoadTask: Task<Void, Never>?
    var activityProtectionPersistenceTask: Task<Void, Never>?
    private var isActivityProtectionStateLoaded = false
    var isActivityProtectionEnabled = false
    var isActivitySourceHealthy = false
    var isActivityProtectionRecoveryInProgress = false
    var activityProtectionRecoveryGeneration: UInt64 = 0
    private var requestedMonitoringEnabled = false
    private var cancellables = Set<AnyCancellable>()
    var isStarted = false
    var isBootstrapping = false
    /// 历史回放跨多个批次到达, 事件数累加到 bootstrapEnd 才一次记完
    /// reader 每次重试都会重新发一遍 bootstrapStart, 所以事件数跟着重置, 但耗时要累计
    private var bootstrapEventCount = 0
    private var bootstrapDuration = LogDuration()
    private var bootstrapCompletionGeneration: UInt64 = 0
    var sessionTransitionNotBefore: Date?

    init(
        codexHookSettings: CodexHookSettings,
        activityProtectionSettings: ActivityProtectionSettings,
        activityProtectionStateStore: ActivityProtectionStateStore = ActivityProtectionStateStore()
    ) {
        self.codexHookSettings = codexHookSettings
        self.activityProtectionSettings = activityProtectionSettings
        self.activityProtectionStateStore = activityProtectionStateStore
    }

    func start() {
        guard !isStarted else {
            return
        }
        isStarted = true

        loadActivityProtectionState()

        Publishers.CombineLatest(codexHookSettings.$isEnabled, codexHookSettings.$isVerified)
            .map { $0 && $1 }
            .removeDuplicates()
            .sink { [weak self] isOperable in
                self?.requestMonitoringEnabled(isOperable)
            }
            .store(in: &cancellables)

        activityProtectionSettings.$inactivityDuration
            .dropFirst()
            // @Published 在 willSet 发值, 切回主队列后再按已经提交的新阈值重算
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleActivityProtectionTimingChange()
            }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.willSleepNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else {
                    return
                }
                beginActivityProtectionRecovery()
                AppLog.activity.notice("异常任务判定已暂停: reason=systemSleep")
            }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else {
                    return
                }
                AppLog.activity.notice(
                    "事件重读已触发: trigger=\(LogTrigger.wake.rawValue, privacy: .public)"
                )
                let recoveryGeneration = beginActivityProtectionRecovery()
                guard let reader = tailReader else {
                    finishActivityProtectionRecovery(generation: recoveryGeneration)
                    return
                }
                let readerGeneration = tailReaderGeneration
                Task { @MainActor [weak self] in
                    let drainResult = await reader.drainNow()
                    guard let self,
                          readerGeneration == tailReaderGeneration else {
                        return
                    }
                    guard case .completed = drainResult else {
                        finishActivityProtectionRecovery(generation: recoveryGeneration)
                        return
                    }
                    await sessionLifecycleReader.resetResolutionFallbacks()
                    await reconcileSessionLifecycles(generation: readerGeneration)
                    guard readerGeneration == tailReaderGeneration else {
                        return
                    }
                    finishActivityProtectionRecovery(generation: recoveryGeneration)
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: .NSSystemClockDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleActivityProtectionTimingChange()
            }
            .store(in: &cancellables)
    }

    func stop() {
        guard isStarted else {
            return
        }
        isStarted = false
        cancellables.removeAll()
        activityProtectionStateLoadTask?.cancel()
        activityProtectionStateLoadTask = nil
        stopReaderAndClearState()
    }

    private func loadActivityProtectionState() {
        guard !isActivityProtectionStateLoaded,
              activityProtectionStateLoadTask == nil else {
            return
        }

        activityProtectionStateLoadTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            let records = await activityProtectionStateStore.load()
            guard isStarted, !Task.isCancelled else {
                return
            }
            activityProtectionRecords = records
            isActivityProtectionStateLoaded = true
            activityProtectionStateLoadTask = nil
            setMonitoringEnabled(requestedMonitoringEnabled)
        }
    }

    private func requestMonitoringEnabled(_ isEnabled: Bool) {
        requestedMonitoringEnabled = isEnabled
        guard isActivityProtectionStateLoaded else {
            return
        }
        setMonitoringEnabled(isEnabled)
    }

    private func setMonitoringEnabled(_ isOperable: Bool) {
        guard isOperable else {
            AppLog.activity.notice("任务监控已停止: reason=hookInoperable")
            stopReaderAndClearState()
            return
        }

        guard tailReader == nil else {
            return
        }

        AppLog.activity.notice("任务监控已启动: reason=hookOperable")

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
        resetActivityProtectionRecovery()
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
        cancelInactivityCheck()
        isActivitySourceHealthy = false
        cleanupTask?.cancel()
        cleanupTask = nil
        cleanupDeadline = nil
        clearCollectedActivityState()
        isBootstrapping = false
        sessionTransitionNotBefore = nil
        snapshot = .empty
    }

    // MARK: - 会话生命周期

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

    /// 把一条 rollout 生命周期状态合进当前任务, 返回是否改动过状态
    /// 待确认终态的任务与在跑的任务走两条分支, 前者已经从 tasks 里挪走
    private func applyLifecycleState(
        _ state: CodexSessionTaskLifecycleState,
        into transitions: inout [CodexActivityTransition]
    ) -> Bool {
        let key = CodexActivityTaskKey.turn(session: state.sessionId, turn: state.turnId)
        if var pending = pendingTerminalTasks[key] {
            let pendingDidChange = Self.mergeLifecycleBackfill(
                from: state,
                into: &pending.task
            )

            guard let terminal = state.terminal else {
                guard pendingDidChange else {
                    return false
                }
                pendingTerminalTasks[key] = pending
                return true
            }
            pendingTerminalTasks.removeValue(forKey: key)
            resolveTerminal(
                terminal,
                task: pending.task,
                key: key,
                abortFallback: pending.supersededAt,
                into: &transitions
            )
            return true
        }

        guard var task = tasks[key] else {
            return false
        }

        var taskDidChange = Self.mergeLifecycleBackfill(from: state, into: &task)
        let progressDidChange = mergeLifecycleProgress(
            from: state,
            key: key,
            into: &task
        )
        taskDidChange = progressDidChange || taskDidChange

        if let terminal = state.terminal {
            tasks.removeValue(forKey: key)
            if case .completed = terminal, recentCompletionDate(for: key) != nil {
                // 迟到事件恢复出的任务不能被 rollout 再次完成
                clearActivityProtection(
                    for: key,
                    taskID: task.displayID,
                    reason: .terminal
                )
                return true
            }
            resolveTerminal(
                terminal,
                task: task,
                key: key,
                abortFallback: Date(),
                into: &transitions
            )
            return true
        }

        if let approvalReviewer = state.approvalReviewer,
           task.approvalReviewer != approvalReviewer {
            task.approvalReviewer = approvalReviewer
            taskDidChange = true
        }

        let wasSuppressedBeforeApproval = task.state == .suppressed
        if resolvePendingApprovalIfPossible(
            for: &task,
            into: &transitions
        ) {
            if wasSuppressedBeforeApproval, task.state == .waitingApproval {
                clearActivityProtection(
                    for: key,
                    taskID: task.displayID,
                    reason: .progress
                )
            }
            taskDidChange = true
        }

        guard taskDidChange else {
            return false
        }
        tasks[key] = task
        if progressDidChange {
            suppressBackfilledActivityTaskIfOverdue(key, now: Date())
        }
        return true
    }

    private func mergeLifecycleProgress(
        from state: CodexSessionTaskLifecycleState,
        key: CodexActivityTaskKey,
        into task: inout CodexActivityTask
    ) -> Bool {
        guard let lastProgressAt = state.lastProgressAt,
              lastProgressAt > task.lastProgressAt else {
            return false
        }

        let wasSuppressed = task.state == .suppressed
        task.recordProgress(at: lastProgressAt)
        if shouldRestoreActivityProtection(for: key, progressAt: lastProgressAt) {
            if wasSuppressed {
                task.state = .running
                task.stateChangedAt = lastProgressAt
            }
            clearActivityProtection(
                for: key,
                taskID: task.displayID,
                reason: .progress
            )
        }
        return true
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
            didChange = applyLifecycleState(state, into: &transitions) || didChange
        }

        if didChange {
            refreshSnapshot(now: Date())
        }
        for transition in transitions {
            transitionSubject.send(transition)
        }
    }

    // MARK: - Hook 事件消费

    private func consume(_ batch: HookEventBatch) {
        switch batch {
        case .bootstrapStart:
            // 重试会重放整段历史, 计时从第一次开始算才是用户等到的总时长
            if !isBootstrapping {
                bootstrapDuration = LogDuration()
            }
            isBootstrapping = true
            bootstrapCompletionGeneration &+= 1
            sessionTransitionNotBefore = nil
            bootstrapEventCount = 0
            isActivitySourceHealthy = false
            cancelInactivityCheck()
            clearCollectedActivityState()
        case let .bootstrapEvents(events):
            bootstrapEventCount += events.count
            for event in events {
                _ = apply(event, source: .bootstrap)
            }
        case let .bootstrapEnd(degraded, attempts):
            isActivitySourceHealthy = !degraded
            sessionTransitionNotBefore = Date()
            let completionGeneration = bootstrapCompletionGeneration
            Task { @MainActor [weak self] in
                await self?.finishBootstrap(
                    degraded: degraded,
                    attempts: attempts,
                    completionGeneration: completionGeneration
                )
            }
        case let .live(events):
            let pendingKeysBefore = Set(pendingTerminalTasks.keys)
            let activeCountBefore = snapshot.activeCount
            var transitions: [CodexActivityLiveTransition] = []
            for event in events {
                if let transition = apply(event, source: .live) {
                    transitions.append(transition)
                }
            }

            refreshSnapshot(now: Date())
            // 活跃数变化覆盖任务起止, transitions 覆盖等待批准
            // 只看活跃数会漏掉 running 转 waitingApproval, 那一进一出恒抵消为零
            let activeCountAfter = snapshot.activeCount
            if activeCountAfter != activeCountBefore || !transitions.isEmpty {
                let details = LogFields.joined(
                    "from=\(activeCountBefore)",
                    "to=\(activeCountAfter)",
                    "transitions=\(transitions.count)"
                )
                AppLog.activity.notice("任务数变化: \(details, privacy: .public)")
            }
            publishLiveTransitions(transitions)
            if !pendingTerminalTasks.isEmpty {
                // 只有刚进入终态确认窗口的任务需要重置解析缓存重试定位 rollout
                // 窗口期内的后续批次只做即时查询, 避免反复递归扫描 sessions
                let hasNewPendingTasks = !Set(pendingTerminalTasks.keys)
                    .subtracting(pendingKeysBefore).isEmpty
                refreshSessionLifecycleNow(resetsResolutionFallbacks: hasNewPendingTasks)
            }
        case let .sourceHealthChanged(isHealthy):
            guard isHealthy != isActivitySourceHealthy else {
                return
            }
            isActivitySourceHealthy = isHealthy
            if isHealthy {
                reconcileActivityProtection(now: Date(), sendsNotification: false)
            } else {
                cancelInactivityCheck()
                cancelAllActivityProtectionAttempts()
                AppLog.activity.error(
                    "异常任务判定已暂停: reason=hookSourceUnavailable"
                )
            }
        }
    }

    private func finishBootstrap(
        degraded: Bool,
        attempts: Int,
        completionGeneration: UInt64
    ) async {
        if !degraded {
            let references = tasks.values.compactMap(\.turnReference)
                + pendingTerminalTasks.values.compactMap(\.task.turnReference)
            if !references.isEmpty {
                let states = await sessionLifecycleReader.lifecycleStates(for: references)
                guard completionGeneration == bootstrapCompletionGeneration,
                      tailReader != nil else {
                    return
                }
                var ignoredTransitions: [CodexActivityTransition] = []
                for state in states {
                    _ = applyLifecycleState(state, into: &ignoredTransitions)
                }
            }
        }

        guard completionGeneration == bootstrapCompletionGeneration,
              tailReader != nil else {
            return
        }
        isBootstrapping = false
        let now = Date()
        applyPersistedActivityProtection(now: now)
        reconcileActivityProtection(now: now, sendsNotification: false)
        backfillPromptStartTimesFromHistory()

        let activeCount = snapshot.activeCount
        let eventCount = bootstrapEventCount
        let elapsed = bootstrapDuration.elapsed
        guard !degraded else {
            let details = LogFields.joined(
                "attempts=\(attempts)",
                "events=\(eventCount)",
                "activeTasks=\(activeCount)",
                "elapsed=\(elapsed)",
                "reason=unstableBoundary",
                "action=skipHistory"
            )
            AppLog.activity.notice("历史回放已降级: \(details, privacy: .public)")
            return
        }

        let details = LogFields.joined(
            "attempts=\(attempts)",
            "events=\(eventCount)",
            "activeTasks=\(activeCount)",
            "elapsed=\(elapsed)"
        )
        AppLog.activity.notice("历史回放完成: \(details, privacy: .public)")
    }

    /// bootstrap 只覆盖 24 小时窗口; 窗口内恢复出的无起点任务向更早日期回查 Prompt 起点
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

    private func apply(
        _ event: WorkflowHookEvent,
        source: CodexActivityEventSource
    ) -> CodexActivityLiveTransition? {
        let isTopLevelEvent = event.agentId == nil
        switch event.hookEvent {
        case .userPromptSubmit:
            startTask(from: event, source: source)
        case .preToolUse:
            resumeTask(
                from: event,
                latestEvent: .toolStarted,
                allowsRecovery: isTopLevelEvent,
                source: source
            )
        case .postToolUse:
            resumeTask(
                from: event,
                latestEvent: .toolFinished,
                allowsRecovery: isTopLevelEvent,
                source: source
            )
        case .preCompact:
            resumeTask(
                from: event,
                latestEvent: .compactionStarted,
                allowsRecovery: isTopLevelEvent,
                source: source
            )
        case .postCompact:
            resumeTask(
                from: event,
                latestEvent: .compactionFinished,
                allowsRecovery: isTopLevelEvent,
                source: source
            )
        case .subagentStart:
            // 子智能体只更新所属顶层任务, 不自行创建一条并发任务
            updateSubagentActivity(from: event, isStarting: true, source: source)
        case .subagentStop:
            updateSubagentActivity(from: event, isStarting: false, source: source)
        case .permissionRequest:
            return waitForApproval(from: event, source: source)
        case .stop:
            guard isTopLevelEvent else {
                return nil
            }
            return completeTask(from: event)
        case .sessionEnd:
            terminateSession(from: event)
        case .sessionStart, .none:
            break
        }
        return nil
    }

    // MARK: - 任务状态转换

    private func startTask(
        from event: WorkflowHookEvent,
        source: CodexActivityEventSource
    ) {
        let key = CodexActivityTaskKey(event: event)
        let existingTask = tasks[key]
        let displayID = existingTask?.displayID ?? UUID()
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
            // 同一 session 的 turn 按顺序执行. 新 prompt 让旧 turn 立即退出活动列表
            // 但保留短暂终态确认窗口, 避免把迟到的正常完成误记为终止
            guard !tasks.values.contains(where: {
                $0.key.sessionId == sessionId && $0.lastActivityAt > event.timestamp
            }) else {
                return
            }
            let supersededTasks = tasks.values.filter {
                $0.key != key && $0.key.sessionId == sessionId
            }
            for task in supersededTasks {
                cancelActivityProtectionAttempt(for: task.key)
                invalidateActivityProtectionNotification(for: task.displayID)
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

        if source == .live {
            clearActivityProtection(
                for: key,
                taskID: displayID,
                reason: .progress
            )
        }

        recentlyCompletedTaskAt.removeValue(forKey: key)
        recentlyTerminatedTaskAt.removeValue(forKey: key)
        if let sessionId = key.sessionId {
            // 缺少 turn 的 Stop 会使用 session 键; 新 turn 开始后允许该键再次完成
            recentlyCompletedTaskAt.removeValue(forKey: .session(sessionId))
            recentlyTerminatedTaskAt.removeValue(forKey: .session(sessionId))
        }

        tasks[key] = CodexActivityTask(
            displayID: displayID,
            key: key,
            event: event,
            state: .running,
            latestEvent: .promptSubmitted,
            startedAt: event.timestamp,
            progressGeneration: (existingTask?.progressGeneration ?? 0) &+ 1
        )
    }

    private func resumeTask(
        from event: WorkflowHookEvent,
        latestEvent: CodexActivityEvent,
        allowsRecovery: Bool,
        source: CodexActivityEventSource
    ) {
        let eventKey = CodexActivityTaskKey(event: event)
        let matchedKey = event.agentId == nil
            ? matchingActiveTaskKey(for: event)
            : matchingSubagentParentTaskKey(for: event)

        if let key = matchedKey, var task = tasks[key] {
            guard recentCompletionDate(for: key) == nil,
                  recentTerminationDate(for: key) == nil,
                  pendingTerminalTasks[key] == nil else {
                return
            }
            guard event.timestamp >= task.lastActivityAt else {
                return
            }

            let wasSuppressed = task.state == .suppressed
            if task.state != .running {
                task.state = .running
                task.stateChangedAt = event.timestamp
            }
            task.pendingApprovalRequestedAt = nil
            task.latestEvent = latestEvent
            task.mergeMetadata(from: event)
            task.recordProgress(at: event.timestamp)
            tasks[key] = task
            if wasSuppressed || source == .live {
                clearActivityProtection(
                    for: key,
                    taskID: task.displayID,
                    reason: .progress
                )
            }
            return
        }

        guard allowsRecovery,
              recentCompletionDate(for: eventKey) == nil,
              recentTerminationDate(for: eventKey) == nil,
              pendingTerminalTasks[eventKey] == nil else {
            return
        }

        let recoveredTask = CodexActivityTask(
            displayID: UUID(),
            key: eventKey,
            event: event,
            state: .running,
            latestEvent: latestEvent,
            startedAt: nil,
            progressGeneration: 1
        )
        tasks[eventKey] = recoveredTask
        if source == .live {
            clearActivityProtection(
                for: eventKey,
                taskID: recoveredTask.displayID,
                reason: .progress
            )
        }
    }

    private func updateSubagentActivity(
        from event: WorkflowHookEvent,
        isStarting: Bool,
        source: CodexActivityEventSource
    ) {
        guard let key = matchingSubagentParentTaskKey(for: event),
              recentCompletionDate(for: key) == nil,
              recentTerminationDate(for: key) == nil,
              pendingTerminalTasks[key] == nil,
              var task = tasks[key] else {
            return
        }

        // 子 Agent 只能按 session 关联父任务, 忽略上一 turn 延迟到达的事件
        if let startedAt = task.startedAt, event.timestamp < startedAt {
            return
        }

        task.recordSubagentActivity(
            agentId: event.agentId,
            isStarting: isStarting,
            at: event.timestamp,
            hasReliableTaskAssociation: hasReliableSubagentAssociation(
                eventSessionId: event.sessionId,
                matchedKey: key
            )
        )

        if event.timestamp >= task.lastActivityAt {
            let wasSuppressed = task.state == .suppressed
            if task.state != .running {
                task.state = .running
                task.stateChangedAt = event.timestamp
            }
            task.pendingApprovalRequestedAt = nil
            task.latestEvent = isStarting ? .subagentStarted : .subagentFinished
            task.mergeMetadata(from: event)
            task.recordProgress(at: event.timestamp)
            if wasSuppressed || source == .live {
                clearActivityProtection(
                    for: key,
                    taskID: task.displayID,
                    reason: .progress
                )
            }
        }
        tasks[key] = task
    }

    /// Subagent Hook 的 turn 属于子 Agent 自己; 父任务只能通过共享 session 关联
    private func hasReliableSubagentAssociation(
        eventSessionId: String?,
        matchedKey: CodexActivityTaskKey
    ) -> Bool {
        guard let eventSessionId,
              matchedKey.sessionId == eventSessionId else {
            return false
        }

        let activeTaskCount = tasks.values.reduce(into: 0) { count, task in
            if task.key.sessionId == eventSessionId {
                count += 1
            }
        }
        let hasPendingTask = pendingTerminalTasks.values.contains {
            $0.task.key.sessionId == eventSessionId
        }
        return activeTaskCount == 1 && !hasPendingTask
    }

    private func waitForApproval(
        from event: WorkflowHookEvent,
        source: CodexActivityEventSource
    ) -> CodexActivityLiveTransition? {
        let eventKey = CodexActivityTaskKey(event: event)
        let matchedKey = event.agentId == nil
            ? matchingActiveTaskKey(for: event)
            : matchingSubagentParentTaskKey(for: event)

        if let key = matchedKey, var task = tasks[key] {
            guard recentCompletionDate(for: key) == nil,
                  recentTerminationDate(for: key) == nil,
                  pendingTerminalTasks[key] == nil else {
                return nil
            }
            guard event.timestamp >= task.lastActivityAt else {
                return nil
            }

            let wasSuppressed = task.state == .suppressed
            task.mergeMetadata(from: event)
            // 权限事件描述当前请求; 缺失工具名时不能沿用上一条工具事件
            task.toolName = event.toolName
            task.recordProgress(at: event.timestamp)
            let enteredWaiting = task.recordApprovalRequest(at: event.timestamp)
            tasks[key] = task
            if wasSuppressed || source == .live {
                clearActivityProtection(
                    for: key,
                    taskID: task.displayID,
                    reason: .progress
                )
            }
            return enteredWaiting ? .waitingApproval(key) : nil
        }

        guard event.agentId == nil,
              recentCompletionDate(for: eventKey) == nil,
              recentTerminationDate(for: eventKey) == nil,
              pendingTerminalTasks[eventKey] == nil else {
            return nil
        }

        var task = CodexActivityTask(
            displayID: UUID(),
            key: eventKey,
            event: event,
            state: .running,
            latestEvent: .toolStarted,
            startedAt: nil,
            progressGeneration: 1
        )
        let enteredWaiting = task.recordApprovalRequest(at: event.timestamp)
        tasks[eventKey] = task
        if source == .live {
            clearActivityProtection(
                for: eventKey,
                taskID: task.displayID,
                reason: .progress
            )
        }
        return enteredWaiting ? .waitingApproval(eventKey) : nil
    }

    private func completeTask(from event: WorkflowHookEvent) -> CodexActivityLiveTransition? {
        let eventKey = CodexActivityTaskKey(event: event)
        guard recentCompletionDate(for: eventKey) == nil else {
            // 清掉旧版本或异常顺序留下的同键恢复任务
            discardStaleTerminalTask(for: eventKey)
            return nil
        }
        guard recentTerminationDate(for: eventKey) == nil else {
            discardStaleTerminalTask(for: eventKey)
            return nil
        }

        let match = matchingTerminalTask(for: event)
        if case .ambiguous = match {
            AppLog.activity.error(
                "任务终态已延后: reason=ambiguousStop"
            )
            return nil
        }

        if case let .pending(key) = match,
           let pending = pendingTerminalTasks[key] {
            guard event.timestamp >= pending.task.lastActivityAt else {
                return nil
            }
            pendingTerminalTasks.removeValue(forKey: key)
            clearActivityProtection(
                for: key,
                taskID: pending.task.displayID,
                reason: .terminal
            )
            let completion = storeResolvedCompletion(
                pending.task,
                key: key,
                completedAt: event.timestamp,
                reportedDuration: nil,
                projectName: event.projectDisplayName,
                modelName: event.modelName,
                effort: event.effort
            )
            recordCompletedTask(eventKey, at: event.timestamp)
            return .completed(completion)
        }

        let matchedKey: CodexActivityTaskKey? = switch match {
        case let .active(key): key
        default: nil
        }
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
            clearActivityProtection(
                for: matchedKey,
                taskID: task?.displayID,
                reason: .terminal
            )
        }

        let duration = task?.preciseDuration(until: event.timestamp)

        let completion = storeCompletion(
            for: key,
            projectName: event.projectDisplayName ?? task?.projectName,
            modelName: event.modelName ?? task?.modelName,
            effort: event.effort ?? task?.effort,
            completedAt: event.timestamp,
            duration: duration
        )
        recordCompletedTask(eventKey, at: event.timestamp)
        recordCompletedTask(key, at: event.timestamp)
        return .completed(completion)
    }

    private func discardStaleTerminalTask(for key: CodexActivityTaskKey) {
        if let task = tasks.removeValue(forKey: key) {
            clearActivityProtection(
                for: key,
                taskID: task.displayID,
                reason: .terminal
            )
        }
        if let pending = pendingTerminalTasks.removeValue(forKey: key) {
            clearActivityProtection(
                for: key,
                taskID: pending.task.displayID,
                reason: .terminal
            )
        }
    }

    /// SessionEnd 没有 turn_id, 以 session 为边界把活跃任务移入终态确认窗口
    /// 任务会立即退出活跃列表, rollout 仍有 5 秒补回准确的完成或终止分类
    private func terminateSession(from event: WorkflowHookEvent) {
        guard let sessionId = event.sessionId else {
            return
        }

        let deadline = Date().addingTimeInterval(Self.supersededTerminalGracePeriod)
        let matchingPendingTasks = pendingTerminalTasks.filter { key, pending in
            key.sessionId == sessionId && pending.task.lastActivityAt <= event.timestamp
        }
        for (key, pending) in matchingPendingTasks {
            pendingTerminalTasks[key] = PendingTerminalTask(
                task: pending.task,
                supersededAt: max(pending.supersededAt, event.timestamp),
                deadline: min(pending.deadline, deadline)
            )
        }

        let matchingActiveTasks = tasks.filter { key, task in
            key.sessionId == sessionId && task.lastActivityAt <= event.timestamp
        }
        for (key, task) in matchingActiveTasks {
            tasks.removeValue(forKey: key)
            cancelActivityProtectionAttempt(for: key)
            invalidateActivityProtectionNotification(for: task.displayID)
            pendingTerminalTasks[key] = PendingTerminalTask(
                task: task,
                supersededAt: event.timestamp,
                deadline: deadline
            )
        }
    }

    /// 精确 turn 失败后只接受同 session 唯一活动任务, 有待确认旧 turn 时不猜测
    private func matchingActiveTaskKey(for event: WorkflowHookEvent) -> CodexActivityTaskKey? {
        let exactKey = CodexActivityTaskKey(event: event)
        if tasks[exactKey] != nil {
            return exactKey
        }

        if let sessionId = event.sessionId {
            guard !pendingTerminalTasks.values.contains(where: {
                $0.task.key.sessionId == sessionId
            }) else {
                return nil
            }
            let candidates = tasks.values.filter { task in
                task.key.sessionId == sessionId
                    && (event.turnId == nil || task.key.isSessionOnly)
            }
            guard candidates.count == 1 else {
                return nil
            }
            return candidates[0].key
        }

        let anonymousKey = CodexActivityTaskKey.anonymous(
            project: CodexActivityTaskKey.projectIdentifier(event.projectDisplayName)
        )
        return tasks[anonymousKey] == nil ? nil : anonymousKey
    }

    /// 子 Agent 的 turn_id 属于它自己, 只能在没有待确认旧 turn 时关联同 session 唯一父任务
    private func matchingSubagentParentTaskKey(
        for event: WorkflowHookEvent
    ) -> CodexActivityTaskKey? {
        guard let sessionId = event.sessionId,
              !pendingTerminalTasks.values.contains(where: {
                  $0.task.key.sessionId == sessionId
              }) else {
            return nil
        }
        let candidates = tasks.values.filter { $0.key.sessionId == sessionId }
        guard candidates.count == 1 else {
            return nil
        }
        return candidates[0].key
    }

    private func matchingTerminalTask(
        for event: WorkflowHookEvent
    ) -> CodexTerminalTaskMatch {
        let exactKey = CodexActivityTaskKey(event: event)
        if pendingTerminalTasks[exactKey] != nil {
            return .pending(exactKey)
        }
        if tasks[exactKey] != nil,
           event.turnId != nil || event.sessionId == nil {
            return .active(exactKey)
        }

        if let sessionId = event.sessionId {
            let pendingCandidates = pendingTerminalTasks.values.filter {
                $0.task.key.sessionId == sessionId
                    && $0.task.lastActivityAt <= event.timestamp
                    && (event.turnId == nil || $0.task.key.isSessionOnly)
            }
            if pendingCandidates.count == 1 {
                return .pending(pendingCandidates[0].task.key)
            }
            if pendingCandidates.count > 1 {
                return .ambiguous
            }

            let activeCandidates = tasks.values.filter {
                $0.key.sessionId == sessionId
                    && $0.lastActivityAt <= event.timestamp
                    && (event.turnId == nil || $0.key.isSessionOnly)
            }
            if activeCandidates.count == 1 {
                return .active(activeCandidates[0].key)
            }
            if activeCandidates.count > 1 {
                return .ambiguous
            }
        }

        let anonymousKey = CodexActivityTaskKey.anonymous(
            project: CodexActivityTaskKey.projectIdentifier(event.projectDisplayName)
        )
        if tasks[anonymousKey] != nil {
            return .active(anonymousKey)
        }
        if pendingTerminalTasks[anonymousKey] != nil {
            return .pending(anonymousKey)
        }
        return .none
    }

    // MARK: - 快照与过期清理

    func refreshSnapshot(now: Date) {
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
        scheduleNextInactivityCheck(now: now)
    }

    private func sortedTasks(in state: CodexActivityTaskState) -> [CodexActivityTask] {
        tasks.values
            .filter { $0.state == state }
            .sorted(by: Self.recentFirst(\.lastActivityAt, \.displayID))
    }

    /// 时间相同再按 UUID 字符串排序(Swift sort 不稳定), 保证快照对 SwiftUI diff 稳定
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
        let expiredTasks = tasks.filter { $0.value.lastActivityAt <= activityCutoff }
        for (key, task) in expiredTasks {
            clearActivityProtection(
                for: key,
                taskID: task.displayID,
                reason: .retention
            )
        }
        tasks = tasks.filter { $0.value.lastActivityAt > activityCutoff }

        removeExpiredActivityProtectionRecords(now: now)

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
        deadlines.append(contentsOf: activityProtectionRecords.values.map(\.expiresAt))
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
    static let completedTaskRetention: TimeInterval = 24 * 60 * 60
    static let activityRetention = CodexActivityRetention.window
    static let activityProtectionNotificationSubmissionGrace: Duration = .seconds(3)
    private static let supersededTerminalGracePeriod: TimeInterval = 5
    private static let sessionLifecyclePollInterval: TimeInterval = 1
}
