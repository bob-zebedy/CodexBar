import AppKit
import Combine
import Foundation
import os

/// 从 Codex 后台服务维护实时任务状态, 是菜单栏, 活动卡片, 通知和触觉反馈的任务来源
@MainActor
final class ActivityMonitor: ObservableObject {
    @Published private(set) var snapshot = ActivitySnapshot.empty

    var transitionPublisher: AnyPublisher<ActivityTransition, Never> {
        transitionSubject.eraseToAnyPublisher()
    }

    var presentationPublisher: AnyPublisher<ActivityPresentationUpdate, Never> {
        presentationSubject.eraseToAnyPublisher()
    }

    var onProtectionTriggered: ((ProtectionNotice) async -> Bool)?
    var onProtectionInvalidated: ((UUID, UUID) -> Void)?

    let protectionSettings: ProtectionSettings
    let protectionStore: ProtectionStore
    private let activityDirectoryURL: URL
    private var lifecycleCache = SessionLifecycleCache()
    let transitionSubject = PassthroughSubject<ActivityTransition, Never>()
    private let presentationSubject = PassthroughSubject<ActivityPresentationUpdate, Never>()
    var pendingTerminalPresentationEvents: [ActivityTerminalEvent] = []
    var terminalPresentationNotBefore = Date()
    var tasks: [ActivityTaskKey: ActivityTask] = [:]
    var subagentTurnLinks: [ActivityTurnReference: ActivityTaskKey] = [:]
    var pendingSubagentEvents: [PendingSubagentEvent] = []
    var pendingTerminalTasks: [ActivityTaskKey: PendingTerminalTask] = [:]
    var completions: [ActivityCompletion] = []
    var terminations: [ActivityTermination] = []
    var recentlyEndedTaskAt: [ActivityTaskKey: Date] = [:]
    var terminalTaskKeyByID: [UUID: ActivityTaskKey] = [:]
    var terminalTokenUsageRequests: [UUID: TaskTokenRequest] = [:]
    var activityTaskOrigins: [ActivityTaskKey: (origin: ActivityOrigin, observedAt: Date)] = [:]
    var activityReader: AppServerActivityReader?
    private var activityReaderControlTask: Task<Void, Never>?
    private var activityReaderGeneration: UInt64 = 0
    private var recoveryTask: Task<Void, Never>?
    private var recoveryTaskID: UUID?
    private var isSystemSleeping = false
    private var isReconcilingLifecycles = false
    private var sessionLifecyclePollTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var cleanupDeadline: Date?
    var inactivityCheckTask: Task<Void, Never>?
    var inactivityCheckDeadline: Date?
    var protectionAttempts: [ActivityTaskKey: ProtectionAttempt] = [:]
    var protectionNoticeAttemptIDs: [UUID: UUID] = [:]
    var protectionRecords: [String: ProtectionRecord] = [:]
    private var protectionStateLoadTask: Task<Void, Never>?
    var protectionPersistenceTask: Task<Void, Never>?
    private var isProtectionStateLoaded = false
    var isProtectionEnabled = false
    @Published var isActivitySourceHealthy = false
    @Published private(set) var sourcePresentation: ActivityLiveLabel? = ActivityLiveLabel("unavailable")
    private var hasConnectedActivitySource = false
    private var unavailableTurns = Set<ActivityTaskKey>()
    var isProtectionRecoveryInProgress = false
    var protectionRecoveryGeneration: UInt64 = 0
    private var cancellables = Set<AnyCancellable>()
    var isStarted = false
    var isBootstrapping = false
    /// 初始快照跨多个批次到达, 事件数累加到 bootstrapEnd 才一次记完
    /// reader 每次重试都会重新发一遍 bootstrapStart, 所以事件数跟着重置, 但耗时要累计
    private var bootstrapEventCount = 0
    private var bootstrapDuration = LogDuration()
    private var bootstrapCompletionGeneration: UInt64 = 0
    var sessionTransitionNotBefore: Date?

    init(
        protectionSettings: ProtectionSettings,
        protectionStore: ProtectionStore = ProtectionStore(),
        activityDirectoryURL: URL = HistoryStorage.directoryURL()
    ) {
        self.protectionSettings = protectionSettings
        self.protectionStore = protectionStore
        self.activityDirectoryURL = activityDirectoryURL
    }

    func start() {
        guard !isStarted else {
            return
        }
        isStarted = true

        loadProtectionState()
        startReaderIfReady()

        protectionSettings.$inactivityDuration
            .dropFirst()
            // @Published 在 willSet 发值, 切回主队列后再按已经提交的新阈值重算
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleProtectionTimingChange()
            }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.willSleepNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else {
                    return
                }
                isSystemSleeping = true
                recoveryTask?.cancel()
                beginProtectionRecovery()
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
                isSystemSleeping = false
                requestActivityRecovery()
            }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: .NSSystemClockDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleProtectionTimingChange()
            }
            .store(in: &cancellables)
    }

    func stop() {
        guard isStarted else {
            return
        }
        isStarted = false
        cancellables.removeAll()
        protectionStateLoadTask?.cancel()
        protectionStateLoadTask = nil
        stopReaderAndClearState()
    }

    private func loadProtectionState() {
        guard !isProtectionStateLoaded,
              protectionStateLoadTask == nil else {
            return
        }

        protectionStateLoadTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            let records = await protectionStore.load()
            guard isStarted, !Task.isCancelled else {
                return
            }
            protectionRecords = records
            isProtectionStateLoaded = true
            protectionStateLoadTask = nil
            startReaderIfReady()
        }
    }

    private func startReaderIfReady() {
        guard isStarted, isProtectionStateLoaded, activityReader == nil else { return }
        AppLog.activity.notice("任务监控已启动: reason=appLaunch")

        activityReaderGeneration &+= 1
        let generation = activityReaderGeneration
        lifecycleCache = SessionLifecycleCache()
        let reader = AppServerActivityReader(
            lifecycleCache: lifecycleCache,
            tokenHistory: TokenHistoryStore(directoryURL: activityDirectoryURL),
            recorder: ActivityRecorder(directoryURL: activityDirectoryURL),
            onBatch: { [weak self] batch in
                guard let self, activityReaderGeneration == generation else {
                    return
                }
                consume(batch)
            }
        )
        activityReader = reader
        activityReaderControlTask = Task { @MainActor [weak self] in
            await reader.start()
            guard let self,
                  activityReaderGeneration == generation,
                  activityReader != nil else {
                return
            }
            startSessionLifecyclePolling(generation: generation)
        }
    }

    private func stopReaderAndClearState() {
        activityReaderGeneration &+= 1
        recoveryTask?.cancel()
        recoveryTask = nil
        resetProtectionRecovery()
        activityReaderControlTask?.cancel()
        activityReaderControlTask = nil
        let reader = activityReader
        activityReader = nil
        if let reader {
            Task {
                await reader.stop()
            }
        }
        sessionLifecyclePollTask?.cancel()
        sessionLifecyclePollTask = nil
        cancelInactivityCheck()
        sourcePresentation = ActivityLiveLabel("unavailable")
        isActivitySourceHealthy = false
        cleanupTask?.cancel()
        cleanupTask = nil
        cleanupDeadline = nil
        clearCollectedActivityState()
        isBootstrapping = false
        sessionTransitionNotBefore = nil
        publishSnapshot(.empty)
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
                if isProtectionRecoveryInProgress {
                    if !isSystemSleeping, recoveryTask == nil {
                        requestActivityRecovery()
                    }
                } else {
                    _ = await reconcileSessionLifecycles(generation: generation, terminalOnly: !isActivitySourceHealthy)
                }
                try? await Task.sleep(for: .seconds(Self.sessionLifecyclePollInterval))
            }
        }
    }

    private func refreshSessionLifecycleNow() {
        guard activityReader != nil else {
            return
        }
        let generation = activityReaderGeneration

        Task { @MainActor [weak self] in
            guard let self,
                  activityReaderGeneration == generation else {
                return
            }
            guard !Task.isCancelled,
                  activityReaderGeneration == generation else {
                return
            }
            await reconcileSessionLifecycles(generation: generation)
        }
    }

    /// 把一条 app-server 生命周期状态合进当前任务, 返回是否改动过状态
    /// 待确认终态的任务与在跑的任务走两条分支, 前者已经从 tasks 里挪走
    private func applyLifecycleState(
        _ state: SessionLifecycleState,
        terminalOnly: Bool = false,
        into transitions: inout [ActivityTransition]
    ) -> Bool {
        guard !terminalOnly || (state.readStatus == .complete && state.terminal != nil) else { return false }
        let exact = ActivityTaskKey.turn(session: state.requestedThreadID, turn: state.turnID)
        let key = tasks.first(where: { $0.value.resolvedTurnKey == exact })?.key
            ?? pendingTerminalTasks.first(where: { $0.value.task.resolvedTurnKey == exact })?.key ?? exact
        if var pending = pendingTerminalTasks[key] {
            let pendingDidChange = Self.mergeLifecycleBackfill(
                from: state,
                into: &pending.task
            )

            guard state.readStatus == .complete, let terminal = state.terminal else {
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
                abortFallback: state.terminalObservedAt ?? state.contextObservedAt ?? pending.supersededAt,
                publishesEvents: !state.isHistoricalTerminal,
                into: &transitions
            )
            return true
        }

        guard var task = tasks[key] else {
            return false
        }

        let hadLifecycleCoverage = task.lifecycleCoverageCheckedAt != nil
        if !terminalOnly {
            let now = Date()
            task.recordLifecycleRead(state, at: now)
            if task.protectionDeadline(at: now, inactivityDuration: protectionSettings.inactivityDuration.timeInterval)
                .map({ $0 <= now }) != true {
                cancelProtectionAttempt(for: key)
            }
        }
        _ = Self.mergeLifecycleBackfill(from: state, into: &task)
        let progressDidChange = !terminalOnly && mergeLifecycleProgress(
            from: state,
            key: key,
            into: &task
        )

        if state.readStatus == .complete, let terminal = state.terminal {
            tasks.removeValue(forKey: key)
            resolveTerminal(
                terminal,
                task: task,
                key: key,
                abortFallback: state.terminalObservedAt ?? state.contextObservedAt ?? Date(),
                publishesEvents: !state.isHistoricalTerminal,
                into: &transitions
            )
            return true
        }

        task.mergeExecutionLifecycle(state, owner: ActivityExecutionKey(agentID: nil, turnID: state.turnID))

        let wasSuppressedBeforeApproval = task.state == .suppressed
        if resolvePendingApprovalIfPossible(
            for: &task,
            into: &transitions
        ) {
            if wasSuppressedBeforeApproval, task.state == .waitingApproval {
                clearProtection(
                    for: key,
                    taskID: task.displayID,
                    reason: .progress
                )
            }
        }

        tasks[key] = task
        if progressDidChange || (!hadLifecycleCoverage && task.lifecycleCoverageCheckedAt != nil) {
            suppressBackfilledActivityTaskIfOverdue(key, now: Date())
        }
        return true
    }

    func mergeLifecycleProgress(
        from state: SessionLifecycleState,
        key: ActivityTaskKey,
        into task: inout ActivityTask
    ) -> Bool {
        guard state.readStatus == .complete,
              let lastProgressAt = state.lastProgressAt,
              lastProgressAt > task.lastProgressAt else {
            return false
        }

        let wasSuppressed = task.state == .suppressed
        task.recordProgress(at: lastProgressAt)
        if shouldRestoreProtection(for: key, progressAt: lastProgressAt) {
            if wasSuppressed {
                task.state = .running
                task.stateChangedAt = lastProgressAt
            }
            clearProtection(
                for: key,
                taskID: task.displayID,
                reason: .progress
            )
        }
        return true
    }

    /// 恢复只由读取屏障后的调用推进, 普通 poll 不能绕过恢复代次
    private func requestActivityRecovery() {
        guard !isSystemSleeping, let reader = activityReader, !isBootstrapping else { return }
        recoveryTask?.cancel()
        let recoveryGeneration = beginProtectionRecovery()
        let generation = activityReaderGeneration
        let taskID = UUID()
        recoveryTaskID = taskID
        recoveryTask = Task { @MainActor [weak self] in
            let result = await reader.drainNow()
            guard let self else { return }
            defer {
                if recoveryTaskID == taskID {
                    recoveryTask = nil
                    recoveryTaskID = nil
                }
            }
            guard !Task.isCancelled, generation == activityReaderGeneration,
                  recoveryGeneration == protectionRecoveryGeneration else { return }
            if case .sourceUnavailable = result {
                // 连接缺口只阻止完整恢复, 独立读取成功的明确终态仍可静默收敛
                _ = await reconcileSessionLifecycles(generation: generation, terminalOnly: true)
                return
            }
            guard case .completed = result, isActivitySourceHealthy, !isBootstrapping else { return }
            guard !Task.isCancelled, !isSystemSleeping,
                  recoveryGeneration == protectionRecoveryGeneration else { return }
            let didReconcile = await reconcileSessionLifecycles(generation: generation, recovering: true)
            guard didReconcile, !Task.isCancelled, generation == activityReaderGeneration,
                  recoveryGeneration == protectionRecoveryGeneration else { return }
            finishProtectionRecovery(generation: recoveryGeneration)
        }
    }

    private func lifecycleReferences(now: Date, includeAll: Bool) -> [ActivityTurnReference] {
        var references = activeTokenUsageReferences()
        references.append(contentsOf: subagentLifecycleReferences())
        references.append(contentsOf: prepareTerminalTokenUsageReadBatch(now: now))
        let due = pendingTerminalTasks.filter { includeAll || $0.value.nextPollAt <= now }
            .sorted { $0.value.nextPollAt < $1.value.nextPollAt }
        for (key, var pending) in due.prefix(16) {
            if let reference = pending.task.turnReference {
                references.append(reference)
            }
            pending.nextPollAt = now.addingTimeInterval(now < pending.deadline ? 1 : 30)
            pendingTerminalTasks[key] = pending
        }
        return references
    }

    @discardableResult
    private func reconcileSessionLifecycles(
        generation: UInt64,
        recovering: Bool = false,
        terminalOnly: Bool = false
    ) async -> Bool {
        guard generation == activityReaderGeneration, activityReader != nil, !isBootstrapping,
              terminalOnly || isActivitySourceHealthy, !isSystemSleeping,
              recovering || terminalOnly || !isProtectionRecoveryInProgress,
              !isReconcilingLifecycles else { return false }
        isReconcilingLifecycles = true
        defer { isReconcilingLifecycles = false }
        let bootstrapGeneration = bootstrapCompletionGeneration
        let recoveryGeneration = protectionRecoveryGeneration
        let references = lifecycleReferences(now: Date(), includeAll: recovering)
        let states = await lifecycleCache.lifecycleStates(for: references)
        guard !Task.isCancelled, generation == activityReaderGeneration,
              bootstrapGeneration == bootstrapCompletionGeneration,
              recoveryGeneration == protectionRecoveryGeneration,
              activityReader != nil, !isBootstrapping, terminalOnly || isActivitySourceHealthy,
              !isSystemSleeping else { return false }
        let unavailable = Set(states.filter { $0.readStatus != .complete }.map { ActivityTaskKey.turn(session: $0.requestedThreadID, turn: $0.turnID) })
        let availabilityChanged = unavailableTurns != unavailable
        unavailableTurns = unavailable
        var didChange = availabilityChanged
        var transitions: [ActivityTransition] = []
        for state in states {
            didChange = applySubagentLifecycle(state, terminalOnly: terminalOnly, into: &transitions) || didChange
            didChange = applyLifecycleState(state, terminalOnly: terminalOnly, into: &transitions) || didChange
        }
        if !terminalOnly {
            didChange = replayAssociatedSubagentEvents(into: &transitions) || didChange
        }
        if !terminalOnly {
            didChange = applyActiveTokenUsage(states) || didChange
        }
        didChange = applyTerminalTokenUsage(states) || didChange
        if didChange {
            refreshSnapshot(now: Date())
        }
        if canPublishActivityTransitions {
            for transition in transitions {
                if case let .waitingApproval(snapshot) = transition,
                   !tasks.values.contains(where: { $0.displayID == snapshot.id && $0.state == .waitingApproval }) {
                    continue
                }
                transitionSubject.send(transition)
            }
        }
        return true
    }

    var canPublishActivityTransitions: Bool {
        !isBootstrapping && !isProtectionRecoveryInProgress && isActivitySourceHealthy
    }

    // MARK: - 活动事件消费

    func consume(_ batch: ActivityEventBatch) {
        switch batch {
        case .lifecycleChanged:
            refreshSessionLifecycleNow()
        case .bootstrapStart:
            sourcePresentation = ActivityLiveLabel(hasConnectedActivitySource ? "reconnecting" : "connecting")
            recoveryTask?.cancel()
            recoveryTask = nil
            // 重试会重新查询初始快照, 计时从第一次开始算才是用户等到的总时长
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
            publishSnapshot(.empty)
        case let .bootstrapEvents(events):
            sourcePresentation = ActivityLiveLabel("recovering-state")
            bootstrapEventCount += events.count
            for event in events {
                _ = apply(event, source: .bootstrap)
            }
        case .bootstrapEnd:
            sourcePresentation = ActivityLiveLabel("recovering-state")
            hasConnectedActivitySource = true
            isActivitySourceHealthy = true
            sessionTransitionNotBefore = Date()
            let completionGeneration = bootstrapCompletionGeneration
            Task { @MainActor [weak self] in
                await self?.finishBootstrap(
                    completionGeneration: completionGeneration
                )
            }
        case let .live(events):
            let activeCountBefore = snapshot.activeCount
            var waitingTaskKeys: [ActivityTaskKey] = []
            for event in events {
                if let key = apply(event, source: .live) {
                    waitingTaskKeys.append(key)
                }
            }

            refreshSnapshot(now: Date())
            // 活跃数变化覆盖任务起止, waitingTaskKeys 覆盖等待批准
            // 只看活跃数会漏掉 running 转 waitingApproval, 那一进一出恒抵消为零
            let activeCountAfter = snapshot.activeCount
            if activeCountAfter != activeCountBefore || !waitingTaskKeys.isEmpty {
                let details = LogFields.joined(
                    "from=\(activeCountBefore)",
                    "to=\(activeCountAfter)",
                    "transitions=\(waitingTaskKeys.count)"
                )
                AppLog.activity.notice("任务数变化: \(details, privacy: .public)")
            }
            publishWaitingApprovalTransitions(waitingTaskKeys)
            if !pendingTerminalTasks.isEmpty {
                // 新进入终态确认窗口的任务立即查询, 不等待下次周期核对
                refreshSessionLifecycleNow()
            } else if events.contains(where: { $0.eventKind == .turnCompleted }) {
                refreshSessionLifecycleNow()
            }
        case .sourceUnavailable:
            sourcePresentation = ActivityLiveLabel("unavailable")
            guard isActivitySourceHealthy else {
                return
            }
            isActivitySourceHealthy = false
            resetTerminalPresentationEvents()
            beginProtectionRecovery()
            publishSnapshot(.empty)
            cancelInactivityCheck()
            cancelAllProtectionAttempts()
            AppLog.activity.error(
                "异常任务判定已暂停: reason=activitySourceUnavailable"
            )
        }
    }

    private func finishBootstrap(
        completionGeneration: UInt64
    ) async {
        let recoveryGeneration = protectionRecoveryGeneration
        let references = tasks.values.compactMap(\.turnReference)
            + pendingTerminalTasks.values.compactMap(\.task.turnReference)
        if !references.isEmpty {
            let states = await lifecycleCache.lifecycleStates(for: references)
            guard !Task.isCancelled, completionGeneration == bootstrapCompletionGeneration,
                  activityReader != nil else {
                return
            }
            var ignoredTransitions: [ActivityTransition] = []
            if recoveryGeneration == protectionRecoveryGeneration, isActivitySourceHealthy, !isSystemSleeping {
                for state in states {
                    _ = applyLifecycleState(state, into: &ignoredTransitions)
                }
            }
        }

        guard completionGeneration == bootstrapCompletionGeneration,
              activityReader != nil else {
            return
        }
        resetTerminalPresentationEvents()
        isBootstrapping = false
        sourcePresentation = isActivitySourceHealthy ? nil : ActivityLiveLabel("unavailable")
        if isActivitySourceHealthy, !isSystemSleeping {
            if recoveryGeneration == protectionRecoveryGeneration {
                finishProtectionRecovery(generation: recoveryGeneration)
            } else {
                requestActivityRecovery()
            }
        }
        let now = Date()
        applyPersistedProtection(now: now)
        reconcileProtection(now: now, sendsNotification: false)

        let activeCount = snapshot.activeCount
        let eventCount = bootstrapEventCount
        let elapsed = bootstrapDuration.elapsed
        let details = LogFields.joined(
            "attempts=1",
            "events=\(eventCount)",
            "activeTasks=\(activeCount)",
            "elapsed=\(elapsed)"
        )
        AppLog.activity.notice("历史回放完成: \(details, privacy: .public)")
    }

    func apply(
        _ event: ActivityRecord,
        source: ActivityEventSource
    ) -> ActivityTaskKey? {
        guard let event = activityEvent(from: event, source: source) else {
            return nil
        }

        if deferUnassociatedSubagentEvent(event, source: source) {
            return nil
        }
        let isTopLevelEvent = event.agentID == nil
        switch event.eventKind {
        case .turnStarted:
            guard isTopLevelEvent else { return nil }
            startTask(from: event, source: source)
        case .toolStarted, .toolCompleted, .compactionStarted, .compactionCompleted:
            resumeTask(
                from: event,
                allowsRecovery: isTopLevelEvent,
                source: source
            )
        case .subagentStarted:
            // 子智能体只更新所属顶层任务, 不自行创建一条并发任务
            updateSubagentActivity(from: event, isStarting: true, source: source)
        case .subagentEnded:
            updateSubagentActivity(from: event, isStarting: false, source: source)
        case .approvalRequested:
            return waitForApproval(from: event, source: source)
        case .turnCompleted:
            guard isTopLevelEvent else {
                return nil
            }
            observeStop(from: event, source: source)
        case .turnAborted:
            guard isTopLevelEvent else {
                return nil
            }
            interruptTask(from: event, source: source)
        case .sessionEnded:
            guard isTopLevelEvent else { return nil }
            terminateSession(from: event)
        case .sessionStarted, .none:
            break
        }
        return nil
    }

    // MARK: - 任务状态转换

    private func startTask(
        from event: ActivityRecord,
        source: ActivityEventSource
    ) {
        let key = ActivityTaskKey(event: event)
        guard !updateAliasedPrompt(from: event, key: key) else { return }
        preserveSupersededSessionTask(from: event, key: key)
        if let pending = pendingTerminalTasks[key] {
            guard key.turnID == nil, event.timestamp > pending.supersededAt else { return }
            pendingTerminalTasks.removeValue(forKey: key)
            if let resolved = pending.task.resolvedTurnKey {
                pendingTerminalTasks[resolved] = pending
            }
        }
        if pendingTerminalTasks.values.contains(where: { $0.task.resolvedTurnKey == key }) {
            return
        }
        let existingTask = tasks[key]
        let displayID = existingTask?.displayID ?? UUID()
        if let endedAt = recentEndedDate(for: key) {
            if case .turn = key {
                return
            }
            if event.timestamp <= endedAt {
                return
            }
        }
        if let existing = tasks[key], event.timestamp < existing.lastMainEventAt {
            return
        }

        if let sessionID = key.sessionID {
            // 同一 session 的 turn 按顺序执行. 新 prompt 让旧 turn 立即退出活动列表
            // 但保留短暂终态确认窗口, 避免把迟到的正常完成误记为终止
            guard !tasks.values.contains(where: {
                $0.key.sessionID == sessionID && $0.lastMainEventAt > event.timestamp
            }) else {
                return
            }
            let supersededTasks = tasks.values.filter {
                $0.key != key && $0.key.sessionID == sessionID
            }
            for task in supersededTasks {
                clearProtection(for: task.key, taskID: task.displayID, reason: .terminal)
                pendingTerminalTasks[task.key] = PendingTerminalTask(
                    task: task,
                    supersededAt: event.timestamp,
                    deadline: Date().addingTimeInterval(Self.supersededTerminalGracePeriod)
                )
            }
            tasks = tasks.filter { taskKey, _ in
                taskKey == key || taskKey.sessionID != sessionID
            }
        }

        if source == .live {
            clearProtection(
                for: key,
                taskID: displayID,
                reason: .progress
            )
        }

        recentlyEndedTaskAt.removeValue(forKey: key)
        if let sessionID = key.sessionID {
            // 缺少 turn 的事件复用 session 键; 新 turn 开始后清除上一轮的终态记忆
            recentlyEndedTaskAt.removeValue(forKey: .session(sessionID))
        }

        if resumePromptInSameTurn(from: event, existing: existingTask) {
            return
        }

        var task = ActivityTask(
            displayID: displayID,
            key: key,
            event: event,
            state: .running,
            startedAt: event.timestamp,
            progressGeneration: (existingTask?.progressGeneration ?? 0) &+ 1
        )
        task.lastProgressAt = max(task.lastProgressAt, existingTask?.lastProgressAt ?? .distantPast)
        tasks[key] = task
    }

    private func resumeTask(
        from event: ActivityRecord,
        allowsRecovery: Bool,
        source: ActivityEventSource
    ) {
        let eventKey = ActivityTaskKey(event: event)
        let matchedKey = event.agentID == nil
            ? matchingActiveTaskKey(for: event)
            : matchingSubagentParentTaskKey(for: event)

        if let key = matchedKey, var task = tasks[key] {
            guard recentEndedDate(for: key) == nil,
                  pendingTerminalTasks[key] == nil else {
                return
            }
            guard task.acceptsExecutionEvent(event) else {
                return
            }

            let wasSuppressed = task.state == .suppressed
            task.resumeExecution(from: event)
            task.mergeMetadata(from: event)
            task.recordEvent(at: event.timestamp)
            tasks[key] = task
            if wasSuppressed || source == .live {
                clearProtection(
                    for: key,
                    taskID: task.displayID,
                    reason: .progress
                )
            }
            return
        }

        guard allowsRecovery,
              recentEndedDate(for: eventKey) == nil,
              pendingTerminalTasks[eventKey] == nil,
              !pendingTerminalTasks.values.contains(where: { $0.task.resolvedTurnKey == eventKey }) else {
            return
        }

        let recoveredTask = ActivityTask(
            displayID: UUID(),
            key: eventKey,
            event: event,
            state: .running,
            startedAt: nil,
            progressGeneration: 1
        )
        tasks[eventKey] = recoveredTask
        if source == .live {
            clearProtection(
                for: eventKey,
                taskID: recoveredTask.displayID,
                reason: .progress
            )
        }
    }

    private func updateSubagentActivity(
        from event: ActivityRecord,
        isStarting: Bool,
        source: ActivityEventSource
    ) {
        guard let key = matchingSubagentParentTaskKey(for: event),
              recentEndedDate(for: key) == nil,
              pendingTerminalTasks[key] == nil,
              var task = tasks[key] else {
            return
        }

        // 归属已精确关联, 仍拒绝早于根任务起点的事件
        if let startedAt = task.startedAt, event.timestamp < startedAt {
            return
        }

        task.recordSubagentActivity(
            agentID: event.agentID,
            isStarting: isStarting,
            hasEnded: task.executions[task.executionKey(for: event)]?.isTerminal == true,
            at: event.timestamp
        )

        if task.acceptsExecutionEvent(event) {
            let wasSuppressed = task.state == .suppressed
            task.resumeExecution(from: event)
            task.mergeMetadata(from: event)
            task.recordEvent(at: event.timestamp)
            if wasSuppressed || source == .live {
                clearProtection(for: key, taskID: task.displayID, reason: .progress)
            }
        }
        tasks[key] = task
    }

    private func waitForApproval(
        from event: ActivityRecord,
        source: ActivityEventSource
    ) -> ActivityTaskKey? {
        let eventKey = ActivityTaskKey(event: event)
        let matchedKey = event.agentID == nil
            ? matchingActiveTaskKey(for: event)
            : matchingSubagentParentTaskKey(for: event)

        if let key = matchedKey, var task = tasks[key] {
            guard recentEndedDate(for: key) == nil,
                  pendingTerminalTasks[key] == nil else {
                return nil
            }
            guard task.acceptsExecutionEvent(event) else {
                return nil
            }

            let wasSuppressed = task.state == .suppressed
            task.mergeMetadata(from: event)
            // 权限事件描述当前请求; 缺失工具名时不能沿用上一条工具事件
            task.toolName = event.tool
            task.itemType = event.source?.itemType
            task.recordEvent(at: event.timestamp)
            let enteredWaiting = task.recordApprovalRequest(from: event)
            tasks[key] = task
            if wasSuppressed || source == .live {
                clearProtection(
                    for: key,
                    taskID: task.displayID,
                    reason: .progress
                )
            }
            return enteredWaiting ? key : nil
        }

        guard event.agentID == nil,
              recentEndedDate(for: eventKey) == nil,
              pendingTerminalTasks[eventKey] == nil,
              !pendingTerminalTasks.values.contains(where: { $0.task.resolvedTurnKey == eventKey }) else {
            return nil
        }

        var task = ActivityTask(
            displayID: UUID(),
            key: eventKey,
            event: event,
            state: .running,
            startedAt: nil,
            progressGeneration: 1
        )
        let enteredWaiting = task.recordApprovalRequest(from: event)
        tasks[eventKey] = task
        if source == .live {
            clearProtection(
                for: eventKey,
                taskID: task.displayID,
                reason: .progress
            )
        }
        return enteredWaiting ? eventKey : nil
    }

    /// 结束提示与生命周期分开处理, 完成分类由服务端轮次终态确认
    private func observeStop(from event: ActivityRecord, source: ActivityEventSource) {
        let eventKey = ActivityTaskKey(event: event)
        guard recentEndedDate(for: eventKey) == nil else {
            discardStaleTerminalTask(for: eventKey)
            return
        }

        let match = matchingTerminalTask(for: event, allowsAnonymousFallback: event.sessionID == nil)
        switch match {
        case .ambiguous:
            AppLog.activity.error("任务终态已延后: reason=ambiguousStop")
        case let .pending(key):
            guard var pending = pendingTerminalTasks[key],
                  event.timestamp >= pending.task.lastMainEventAt else {
                return
            }
            // 新 turn 或 SessionEnd 已确定旧任务退出活动列表, Stop 不恢复它或重置 grace
            pending.task.mergeMetadata(from: event)
            pending.task.recordEvent(at: event.timestamp)
            pendingTerminalTasks[key] = pending
        case .active, .none:
            resumeTask(
                from: event,
                allowsRecovery: true,
                source: source
            )
        }
    }

    func discardStaleTerminalTask(for key: ActivityTaskKey) {
        if let task = tasks.removeValue(forKey: key) {
            clearProtection(
                for: key,
                taskID: task.displayID,
                reason: .terminal
            )
        }
        if let pending = pendingTerminalTasks.removeValue(forKey: key) {
            clearProtection(
                for: key,
                taskID: pending.task.displayID,
                reason: .terminal
            )
        }
    }

    /// SessionEnd 没有 turn_id, 以 session 为边界把活跃任务移入终态确认窗口
    /// 任务立即退出活跃列表, 后续继续从 app-server 确认完成或终止分类
    private func terminateSession(from event: ActivityRecord) {
        guard let sessionID = event.sessionID else {
            return
        }

        let deadline = Date().addingTimeInterval(Self.supersededTerminalGracePeriod)
        let matchingPendingTasks = pendingTerminalTasks.filter { key, pending in
            key.sessionID == sessionID && pending.task.lastMainEventAt <= event.timestamp
        }
        for (key, pending) in matchingPendingTasks {
            pendingTerminalTasks[key] = PendingTerminalTask(
                task: pending.task,
                supersededAt: max(pending.supersededAt, event.timestamp),
                deadline: min(pending.deadline, deadline)
            )
        }

        let matchingActiveTasks = tasks.filter { key, task in
            key.sessionID == sessionID && task.lastMainEventAt <= event.timestamp
        }
        for (key, task) in matchingActiveTasks {
            tasks.removeValue(forKey: key)
            clearProtection(for: key, taskID: task.displayID, reason: .terminal)
            pendingTerminalTasks[key] = PendingTerminalTask(
                task: task,
                supersededAt: event.timestamp,
                deadline: deadline
            )
        }
    }

    /// 精确 turn 失败后只接受同 session 唯一活动任务, 有待确认旧 turn 时不猜测
    private func matchingActiveTaskKey(for event: ActivityRecord) -> ActivityTaskKey? {
        let exactKey = ActivityTaskKey(event: event)
        if let key = tasks.first(where: { $0.value.resolvedTurnKey == exactKey })?.key {
            return key
        }
        if tasks[exactKey] != nil {
            return exactKey
        }

        if let sessionID = event.sessionID {
            guard !pendingTerminalTasks.values.contains(where: {
                $0.task.key.sessionID == sessionID
            }) else {
                return nil
            }
            let candidates = tasks.values.filter { task in
                task.key.sessionID == sessionID
                    && (event.turnID == nil || task.associatedTurnID == nil)
            }
            guard candidates.count == 1 else {
                return nil
            }
            return candidates[0].key
        }

        let anonymousKey = ActivityTaskKey.anonymous(
            project: ActivityTaskKey.projectIdentifier(event.projectDisplayName)
        )
        return tasks[anonymousKey] == nil ? nil : anonymousKey
    }

    func matchingTerminalTask(
        for event: ActivityRecord,
        allowsAnonymousFallback: Bool = true
    ) -> TerminalTaskMatch {
        let exactKey = ActivityTaskKey(event: event)
        if let key = pendingTerminalTasks.first(where: { $0.value.task.resolvedTurnKey == exactKey })?.key {
            return .pending(key)
        }
        if let key = tasks.first(where: { $0.value.resolvedTurnKey == exactKey })?.key {
            return .active(key)
        }
        if pendingTerminalTasks[exactKey] != nil {
            return .pending(exactKey)
        }
        if tasks[exactKey] != nil,
           event.turnID != nil || event.sessionID == nil {
            return .active(exactKey)
        }

        if let sessionID = event.sessionID {
            let pendingCandidates = pendingTerminalTasks.filter {
                $0.value.task.key.sessionID == sessionID
                    && $0.value.task.lastMainEventAt <= event.timestamp
                    && (event.turnID == nil || $0.value.task.associatedTurnID == nil)
            }
            if pendingCandidates.count == 1, let key = pendingCandidates.keys.first {
                return .pending(key)
            }
            if pendingCandidates.count > 1 {
                return .ambiguous
            }

            let activeCandidates = tasks.values.filter {
                $0.key.sessionID == sessionID
                    && $0.lastMainEventAt <= event.timestamp
                    && (event.turnID == nil || $0.associatedTurnID == nil)
            }
            if activeCandidates.count == 1 {
                return .active(activeCandidates[0].key)
            }
            if activeCandidates.count > 1 {
                return .ambiguous
            }
        }

        guard allowsAnonymousFallback else {
            return .none
        }
        let anonymousKey = ActivityTaskKey.anonymous(
            project: ActivityTaskKey.projectIdentifier(event.projectDisplayName)
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
        guard isActivitySourceHealthy || !isStarted else { return }

        let waitingTasks = sortedTasks(in: .waitingApproval)
        let runningTasks = sortedTasks(in: .running)
        let recentCompletions = completions.sorted(by: Self.recentFirst(\.completedAt, \.id))
        let recentTerminations = terminations.sorted(by: Self.recentFirst(\.terminatedAt, \.id))

        let newSnapshot = ActivitySnapshot(
            waitingTasks: waitingTasks.map(\.snapshot),
            runningTasks: runningTasks.map(\.snapshot),
            recentCompletions: recentCompletions,
            recentTerminations: recentTerminations
        )
        let events = pendingTerminalPresentationEvents.filter { terminalTaskKeyByID[$0.id] != nil }
        pendingTerminalPresentationEvents.removeAll()
        publishSnapshot(newSnapshot, terminalEvents: events)

        scheduleNextCleanup(now: now)
        scheduleNextInactivityCheck(now: now)
    }

    private func publishSnapshot(_ newSnapshot: ActivitySnapshot, terminalEvents: [ActivityTerminalEvent] = []) {
        let didChange = newSnapshot != snapshot
        if didChange {
            snapshot = newSnapshot
        }
        if didChange || !terminalEvents.isEmpty {
            presentationSubject.send(ActivityPresentationUpdate(snapshot: newSnapshot, terminalEvents: terminalEvents))
        }
    }

    private func sortedTasks(in state: ActivityTaskState) -> [ActivityTask] {
        tasks.values
            .filter { $0.state == state && !unavailableTurns.contains($0.resolvedTurnKey ?? $0.key) }
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
            clearProtection(
                for: key,
                taskID: task.displayID,
                reason: .retention
            )
        }
        tasks = tasks.filter { $0.value.lastActivityAt > activityCutoff }

        removeExpiredProtectionRecords(now: now)

        let historyCutoff = now.addingTimeInterval(-Self.recentHistoryRetention)
        completions.removeAll { $0.completedAt <= historyCutoff }
        terminations.removeAll { $0.terminatedAt <= historyCutoff }
        let retainedTerminalIDs = Set(completions.map(\.id)).union(terminations.map(\.id))
        terminalTaskKeyByID = terminalTaskKeyByID.filter {
            retainedTerminalIDs.contains($0.key)
        }
        terminalTokenUsageRequests = terminalTokenUsageRequests.filter { retainedTerminalIDs.contains($0.key) }

        let endedTaskCutoff = now.addingTimeInterval(-Self.endedTaskRetention)
        recentlyEndedTaskAt = recentlyEndedTaskAt.filter {
            $0.value > endedTaskCutoff
        }
        activityTaskOrigins = activityTaskOrigins.filter {
            $0.value.observedAt > activityCutoff
        }
    }

    private func scheduleNextCleanup(now: Date) {
        var deadlines = tasks.values.map {
            $0.lastActivityAt.addingTimeInterval(Self.activityRetention)
        }
        deadlines.append(contentsOf: completions.map {
            $0.completedAt.addingTimeInterval(Self.recentHistoryRetention)
        })
        deadlines.append(contentsOf: terminations.map {
            $0.terminatedAt.addingTimeInterval(Self.recentHistoryRetention)
        })
        deadlines.append(contentsOf: pendingTerminalTasks.values.map(\.expiresAt))
        deadlines.append(contentsOf: recentlyEndedTaskAt.values.map {
            $0.addingTimeInterval(Self.endedTaskRetention)
        })
        deadlines.append(contentsOf: activityTaskOrigins.values.map {
            $0.observedAt.addingTimeInterval(Self.activityRetention)
        })
        deadlines.append(contentsOf: protectionRecords.values.map(\.expiresAt))

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

    private static let recentHistoryRetention: TimeInterval = 10 * 60
    static let endedTaskRetention: TimeInterval = 24 * 60 * 60
    static let activityRetention = ActivityRetention.window
    static let protectionNotificationSubmissionGrace: Duration = .seconds(3)
    private static let supersededTerminalGracePeriod: TimeInterval = 5
    private static let sessionLifecyclePollInterval: TimeInterval = 1
}

private extension ActivityMonitor {
    func resumePromptInSameTurn(from event: ActivityRecord, existing: ActivityTask?) -> Bool {
        guard var task = existing, let turnID = event.turnID, task.associatedTurnID == turnID else { return false }
        task.resumeExecution(from: event)
        task.mergeMetadata(from: event)
        task.recordEvent(at: event.timestamp)
        task.startedAt = task.startedAt ?? event.timestamp
        tasks[task.key] = task
        return true
    }

    func preserveSupersededSessionTask(from event: ActivityRecord, key: ActivityTaskKey) {
        if let existing = tasks[key], key.isSessionOnly,
           let resolved = existing.resolvedTurnKey,
           event.timestamp > (existing.startedAt ?? existing.lastEventAt) {
            pendingTerminalTasks[resolved] = PendingTerminalTask(
                task: existing,
                supersededAt: event.timestamp,
                deadline: Date().addingTimeInterval(Self.supersededTerminalGracePeriod)
            )
        }
    }

    func updateAliasedPrompt(from event: ActivityRecord, key: ActivityTaskKey) -> Bool {
        guard let existing = tasks.values.first(where: { $0.resolvedTurnKey == key && $0.key != key }) else {
            return false
        }
        guard event.timestamp >= existing.lastMainEventAt else { return true }
        var task = existing
        task.mergeMetadata(from: event)
        task.recordExecutionEvent(event)
        task.recordEvent(at: event.timestamp)
        tasks[existing.key] = task
        return true
    }
}
