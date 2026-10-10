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

    var onAccountChange: ((AccountChange) -> Void)?
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
    var subagentTurnLinks: [ActivityTurnReference: (root: ActivityTaskKey, retainedAt: Date)] = [:]
    var pendingSubagentEvents: [PendingSubagentEvent] = []
    var pendingTerminalTasks: [ActivityTaskKey: PendingTerminalTask] = [:]
    var completions: [ActivityCompletion] = []
    var terminations: [ActivityTermination] = []
    var recentlyEndedTaskAt: [ActivityTaskKey: Date] = [:]
    var terminalTokenUsageRequests: [UUID: TaskTokenRequest] = [:]
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
    enum ProtectionLoadState { case idle, loading, available, retryableFailure, blocked }
    var protectionLoadState = ProtectionLoadState.idle
    private var protectionLoadGeneration: UInt64 = 0
    var isProtectionEnabled = false
    var isProtectionStoreAvailable: Bool {
        protectionLoadState == .available
    }

    @Published var isActivitySourceHealthy = false
    @Published private(set) var sourcePresentation: ActivityLiveLabel? = ActivityLiveLabel("unavailable")
    private var hasConnectedActivitySource = false
    private var unavailableTurns = Set<ActivityTaskKey>()
    var isProtectionRecoveryInProgress = false
    var protectionRecoveryGeneration: UInt64 = 0
    private var cancellables = Set<AnyCancellable>()
    private var isPreparingForTermination = false
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
        cancelProtectionStateLoad()
        stopReaderAndClearState()
    }

    func prepareForTermination() async -> Bool {
        isPreparingForTermination = true
        cancelProtectionStateLoad()
        recoveryTask?.cancel()
        recoveryTask = nil
        resetProtectionRecovery()
        cancelInactivityCheck()
        sessionLifecyclePollTask?.cancel()
        sessionLifecyclePollTask = nil
        activityReaderControlTask?.cancel()
        activityReaderControlTask = nil
        isActivitySourceHealthy = false
        guard let reader = activityReader else { return true }
        return await reader.stop()
    }

    func resumeAfterTerminationCancellation() async {
        isPreparingForTermination = false
        loadProtectionState()
        if let reader = activityReader {
            await reader.start()
            startSessionLifecyclePolling(generation: activityReaderGeneration)
        } else {
            startReaderIfReady()
        }
    }

    func loadProtectionState() {
        guard isStarted, !isPreparingForTermination,
              protectionLoadState != .available, protectionStateLoadTask == nil else { return }
        protectionLoadGeneration &+= 1
        let generation = protectionLoadGeneration
        protectionLoadState = .loading
        protectionStateLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if generation == protectionLoadGeneration {
                    protectionStateLoadTask = nil
                }
            }
            for attempt in 0 ..< 3 {
                do {
                    let records = try await protectionStore.load()
                    guard isStarted, !Task.isCancelled, generation == protectionLoadGeneration else { return }
                    protectionRecords = records
                    protectionLoadState = .available
                    // 成功重读后必须经过活动读取屏障, 才能重新判定任务
                    beginProtectionRecovery()
                    startReaderIfReady()
                    requestActivityRecovery()
                    return
                } catch {
                    guard isStarted, !Task.isCancelled, generation == protectionLoadGeneration else { return }
                    let isBlocked = error is StorageCompatibilityError || error is DecodingError
                    protectionLoadState = isBlocked ? .blocked : .retryableFailure
                    AppLog.activity.error("异常任务存储不可用, 暂停保护判定: \(error.localizedDescription, privacy: .public)")
                    startReaderIfReady()
                    guard !isBlocked, attempt < 2 else { return }
                    do { try await Task.sleep(for: .seconds(attempt == 0 ? 1 : 3)) } catch { return }
                }
            }
        }
    }

    private func cancelProtectionStateLoad() {
        protectionLoadGeneration &+= 1
        protectionStateLoadTask?.cancel()
        protectionStateLoadTask = nil
        if protectionLoadState == .loading {
            protectionLoadState = .idle
        }
    }

    private func startReaderIfReady() {
        guard isStarted, !isPreparingForTermination, protectionLoadState != .idle, protectionLoadState != .loading, activityReader == nil else { return }
        AppLog.activity.notice("任务监控已启动: reason=appLaunch")

        activityReaderGeneration &+= 1
        let generation = activityReaderGeneration
        lifecycleCache = SessionLifecycleCache()
        let reader = AppServerActivityReader(
            lifecycleCache: lifecycleCache,
            tokenHistory: TokenHistoryStore(directoryURL: activityDirectoryURL),
            recorder: ActivityRecorder(directoryURL: activityDirectoryURL),
            onAccountChange: { [weak self] change in
                guard let self, activityReaderGeneration == generation else { return }
                onAccountChange?(change)
            },
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
        let key = ActivityTaskKey(thread: state.requestedThreadID, turn: state.turnID)
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

        let wasSuppressed = task.state == .suppressed
        task.mergeExecutionLifecycle(state, owner: ActivityExecutionKey(agentID: nil, turnID: state.turnID))
        if wasSuppressed, task.state == .waitingApproval {
            clearProtection(for: key, taskID: task.displayID, reason: .progress)
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

    func lifecycleReferences() -> [ActivityTurnReference] {
        var references = activeTokenUsageReferences()
        references.append(contentsOf: subagentLifecycleReferences())
        references.append(contentsOf: terminalTokenUsageReferences())
        references.append(contentsOf: pendingTerminalTasks.values.map(\.task.turnReference))
        return Array(Set(references))
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
        let references = lifecycleReferences()
        let states = await lifecycleCache.lifecycleStates(for: references)
        guard !Task.isCancelled, generation == activityReaderGeneration,
              bootstrapGeneration == bootstrapCompletionGeneration,
              recoveryGeneration == protectionRecoveryGeneration,
              activityReader != nil, !isBootstrapping, terminalOnly || isActivitySourceHealthy,
              !isSystemSleeping else { return false }
        let unavailable = Set(states.filter { $0.readStatus != .complete }.map { ActivityTaskKey(thread: $0.requestedThreadID, turn: $0.turnID) })
        let availabilityChanged = unavailableTurns != unavailable
        unavailableTurns = unavailable
        var didChange = availabilityChanged
        var transitions: [ActivityTransition] = []
        for state in states {
            didChange = applySubagentLifecycle(state, terminalOnly: terminalOnly) || didChange
            didChange = applyLifecycleState(state, terminalOnly: terminalOnly, into: &transitions) || didChange
        }
        if !terminalOnly {
            didChange = replayAssociatedSubagentEvents(into: &transitions) || didChange
            didChange = reconcileSubagentCounts(states) || didChange
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
        guard !isPreparingForTermination else { return }
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
        case let .snapshotEvents(events):
            if isBootstrapping {
                sourcePresentation = ActivityLiveLabel("recovering-state")
                bootstrapEventCount += events.count
            }
            var transitions: [ActivityTransition] = []
            for event in events {
                _ = apply(event, source: .bootstrap, into: &transitions)
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
            var transitions: [ActivityTransition] = []
            for event in events {
                if let key = apply(event, source: .live, into: &transitions) {
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
            for transition in transitions {
                transitionSubject.send(transition)
            }
            publishWaitingApprovalTransitions(waitingTaskKeys)
            if !pendingTerminalTasks.isEmpty {
                // 新进入终态确认窗口的任务立即查询, 不等待下次周期核对
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
        let references = lifecycleReferences()
        if !references.isEmpty {
            let states = await lifecycleCache.lifecycleStates(for: references)
            guard !Task.isCancelled, completionGeneration == bootstrapCompletionGeneration,
                  activityReader != nil else {
                return
            }
            var ignoredTransitions: [ActivityTransition] = []
            if recoveryGeneration == protectionRecoveryGeneration, isActivitySourceHealthy, !isSystemSleeping {
                for state in states {
                    _ = applySubagentLifecycle(state, terminalOnly: false)
                    _ = applyLifecycleState(state, into: &ignoredTransitions)
                }
                _ = replayAssociatedSubagentEvents(into: &ignoredTransitions)
                _ = reconcileSubagentCounts(states)
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
        source: ActivityEventSource,
        into transitions: inout [ActivityTransition]
    ) -> ActivityTaskKey? {
        guard event.origin == .main || event.origin == .auxiliary else {
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
        case .turnCompleted, .turnAborted:
            guard isTopLevelEvent else { return nil }
            finishTask(from: event, source: source, into: &transitions)
        case .none:
            break
        }
        return nil
    }

    // MARK: - 任务状态转换

    private func startTask(
        from event: ActivityRecord,
        source: ActivityEventSource
    ) {
        guard let key = ActivityTaskKey(event: event) else { return }
        guard pendingTerminalTasks[key] == nil else { return }
        let existingTask = tasks[key]
        let displayID = existingTask?.displayID ?? UUID()
        guard recentEndedDate(for: key) == nil else { return }
        if let existing = existingTask, event.timestamp < existing.lastMainEventAt {
            return
        }

        let threadID = key.threadID
        // 当前轮次由 app-server 确认, 旧轮次的毫秒级活动时间不能否定秒级起点
        // 旧任务退出活动列表后继续等待明确终态
        let supersededTasks = tasks.values.filter {
            $0.key != key && $0.key.threadID == threadID
        }
        for task in supersededTasks {
            clearProtection(for: task.key, taskID: task.displayID, reason: .terminal)
            pendingTerminalTasks[task.key] = PendingTerminalTask(
                task: task,
                supersededAt: event.timestamp
            )
        }
        tasks = tasks.filter { taskKey, _ in
            taskKey == key || taskKey.threadID != threadID
        }
        if source == .live {
            clearProtection(
                for: key,
                taskID: displayID,
                reason: .progress
            )
        }

        if var task = existingTask {
            task.resumeExecution(from: event)
            task.mergeMetadata(from: event)
            task.recordProgress(at: event.timestamp)
            task.startedAt = task.startedAt ?? event.context?.turnStartedAt
            tasks[key] = task
            return
        }

        tasks[key] = ActivityTask(
            displayID: displayID,
            key: key,
            event: event,
            state: .running,
            startedAt: event.context?.turnStartedAt,
            progressGeneration: 1
        )
    }

    private func resumeTask(
        from event: ActivityRecord,
        allowsRecovery: Bool,
        source: ActivityEventSource
    ) {
        guard let eventKey = ActivityTaskKey(event: event) else { return }
        let matchedKey = event.agentID == nil
            ? eventKey
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
            task.recordProgress(at: event.timestamp)
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
              pendingTerminalTasks[eventKey] == nil else {
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
        guard let agentID = event.agentID, let rootThread = event.context?.rootThreadID, let rootTurn = event.context?.rootTurnID else { return }
        let key = ActivityTaskKey(thread: rootThread, turn: rootTurn)
        guard recentEndedDate(for: key) == nil, pendingTerminalTasks[key] == nil, var task = tasks[key] else { return }
        if let startedAt = task.startedAt, event.timestamp < startedAt {
            return
        }
        // 创建活动标识子线程, 不能拿发出通知的父轮次伪造子执行
        let executions = task.executions.filter { $0.key.agentID == agentID }
        task.recordSubagentActivity(
            agentID: event.agentID, isStarting: isStarting,
            hasEnded: !executions.isEmpty && executions.values.allSatisfy(\.isTerminal), at: event.timestamp
        )
        task.mergeMetadata(from: event)
        task.recordProgress(at: event.timestamp)
        let wasSuppressed = task.state == .suppressed
        if wasSuppressed {
            task.state = .running
            task.stateChangedAt = event.timestamp
        }
        if wasSuppressed || source == .live {
            clearProtection(for: key, taskID: task.displayID, reason: .progress)
        }
        tasks[key] = task
    }

    private func waitForApproval(
        from event: ActivityRecord,
        source: ActivityEventSource
    ) -> ActivityTaskKey? {
        guard let eventKey = ActivityTaskKey(event: event) else { return nil }
        let matchedKey = event.agentID == nil
            ? eventKey
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
            task.recordProgress(at: event.timestamp)
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
              pendingTerminalTasks[eventKey] == nil else {
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
        let retainedTerminalIDs = Set(completions.map(\.id)).union(terminations.map(\.id))
        let events = pendingTerminalPresentationEvents.filter { retainedTerminalIDs.contains($0.id) }
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
            .filter { $0.state == state && !unavailableTurns.contains($0.key) }
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

        removeExpiredProtectionRecords(now: now)

        let historyCutoff = now.addingTimeInterval(-Self.recentHistoryRetention)
        completions.removeAll { $0.completedAt <= historyCutoff }
        terminations.removeAll { $0.terminatedAt <= historyCutoff }
        let retainedTerminalIDs = Set(completions.map(\.id)).union(terminations.map(\.id))
        terminalTokenUsageRequests = terminalTokenUsageRequests.filter { retainedTerminalIDs.contains($0.key) }

        let endedTaskCutoff = now.addingTimeInterval(-Self.endedTaskRetention)
        recentlyEndedTaskAt = recentlyEndedTaskAt.filter {
            $0.value > endedTaskCutoff
        }
    }

    private func scheduleNextCleanup(now: Date) {
        var deadlines = completions.map {
            $0.completedAt.addingTimeInterval(Self.recentHistoryRetention)
        }
        deadlines.append(contentsOf: terminations.map {
            $0.terminatedAt.addingTimeInterval(Self.recentHistoryRetention)
        })
        deadlines.append(contentsOf: pendingTerminalTasks.values.map(\.expiresAt))
        deadlines.append(contentsOf: recentlyEndedTaskAt.values.map {
            $0.addingTimeInterval(Self.endedTaskRetention)
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
    static let protectionNotificationSubmissionGrace: Duration = .seconds(3)
    private static let sessionLifecyclePollInterval: TimeInterval = 1
}
