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
    private let activityDataDirectoryURL: URL
    let transitionSubject = PassthroughSubject<ActivityTransition, Never>()
    private let presentationSubject = PassthroughSubject<ActivityPresentationUpdate, Never>()
    var terminalPresentationNotBefore = Date()
    var graph = ActivityTaskGraph()
    var tasks: [ActivityTaskKey: ActivityTask] {
        graph.tasks
    }

    var completions: [ActivityCompletion] {
        graph.completions
    }

    var terminations: [ActivityTermination] {
        graph.terminations
    }

    var pendingTerminalTasks: [ActivityTaskKey: PendingTerminalTask] {
        graph.pendingTerminalTasks
    }

    var recentlyEndedTaskAt: [ActivityTaskKey: Date] {
        graph.recentlyEndedTaskAt
    }

    private var publishedReaderID: UUID?
    private var publishedRevision: UInt64 = 0
    var activityReader: AppServerActivityReader?
    private var activityReaderControlTask: Task<Void, Never>?
    private var activityReaderGeneration: UInt64 = 0
    private var recoveryTask: Task<Void, Never>?
    private var recoveryTaskID: UUID?
    private var isSystemSleeping = false
    private var recoveryRetryTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var cleanupDeadline: Date?
    var inactivityCheckTask: Task<Void, Never>?
    var inactivityCheckDeadline: Date?
    var suppressedTasks: [ActivityTaskKey: Date] = [:]
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
    var turnTransitionNotBefore: Date?

    init(
        protectionSettings: ProtectionSettings,
        protectionStore: ProtectionStore = ProtectionStore(),
        activityDataDirectoryURL: URL = HistoryStorage.directoryURL()
    ) {
        self.protectionSettings = protectionSettings
        self.protectionStore = protectionStore
        self.activityDataDirectoryURL = activityDataDirectoryURL
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
        recoveryRetryTask?.cancel()
        recoveryRetryTask = nil
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
            startRecoveryRetrying(generation: activityReaderGeneration)
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
        let reader = AppServerActivityReader(
            tokenUsageHistory: TokenUsageHistoryStore(directoryURL: activityDataDirectoryURL),
            activityDataRecorder: ActivityDataRecorder(directoryURL: activityDataDirectoryURL),
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
        publishedReaderID = nil
        publishedRevision = 0
        activityReaderControlTask = Task { @MainActor [weak self] in
            await reader.start()
            guard let self,
                  activityReaderGeneration == generation,
                  activityReader != nil else {
                return
            }
            startRecoveryRetrying(generation: generation)
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
        recoveryRetryTask?.cancel()
        recoveryRetryTask = nil
        cancelInactivityCheck()
        sourcePresentation = ActivityLiveLabel("unavailable")
        isActivitySourceHealthy = false
        cleanupTask?.cancel()
        cleanupTask = nil
        cleanupDeadline = nil
        clearCollectedActivityState()
        isBootstrapping = false
        turnTransitionNotBefore = nil
        publishSnapshot(.empty)
    }

    // MARK: - 轮次生命周期

    private func startRecoveryRetrying(generation: UInt64) {
        guard recoveryRetryTask == nil else {
            return
        }

        recoveryRetryTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, generation == activityReaderGeneration else {
                    return
                }
                if isProtectionRecoveryInProgress {
                    if !isSystemSleeping, recoveryTask == nil {
                        requestActivityRecovery()
                    }
                }
                try? await Task.sleep(for: .seconds(Self.recoveryRetryInterval))
            }
        }
    }

    /// 恢复结果携带屏障之后发布的同一份快照, 不再跨 actor 查询第二份状态
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
                  recoveryGeneration == protectionRecoveryGeneration, !isSystemSleeping else { return }
            switch result {
            case let .completed(update):
                consume(update)
                guard isActivitySourceHealthy, !isBootstrapping else { return }
                finishProtectionRecovery(generation: recoveryGeneration)
            case let .partial(update):
                consume(update)
            case .sourceUnavailable, .cancelled: break
            }
        }
    }

    var canPublishActivityTransitions: Bool {
        !isBootstrapping && !isProtectionRecoveryInProgress && isActivitySourceHealthy
    }

    func consume(_ update: ActivityUpdate) {
        guard !isPreparingForTermination else { return }
        if let publishedReaderID {
            guard publishedReaderID == update.readerID, update.revision > publishedRevision else { return }
        } else {
            publishedReaderID = update.readerID
        }
        publishedRevision = update.revision
        let previous = graph.tasks
        graph = update.graph
        unavailableTurns = graph.unavailableTurns
        for (key, old) in previous {
            guard let task = tasks[key] else {
                clearProtection(for: key, taskID: old.displayID, reason: .terminal)
                continue
            }
            if task.state == .waitingApproval || task.progressGeneration != old.progressGeneration,
               shouldRestoreProtection(for: key, progressAt: task.lastProgressAt) {
                clearProtection(for: key, taskID: task.displayID, reason: .progress)
            }
            if task.protectionDeadline(at: Date(), inactivityDuration: protectionSettings.inactivityDuration.timeInterval)
                .map({ $0 <= Date() }) != true {
                cancelProtectionAttempt(for: key)
            }
        }
        switch update.phase {
        case .bootstrapStart:
            sourcePresentation = ActivityLiveLabel(hasConnectedActivitySource ? "reconnecting" : "connecting")
            recoveryTask?.cancel()
            recoveryTask = nil
            isBootstrapping = true
            turnTransitionNotBefore = nil
            isActivitySourceHealthy = false
            resetTerminalPresentationCutoff()
            beginProtectionRecovery()
            publishSnapshot(.empty)
        case .snapshotEvents:
            if isBootstrapping {
                sourcePresentation = ActivityLiveLabel("recovering-state")
            }
        case .bootstrapEnd:
            hasConnectedActivitySource = true
            isActivitySourceHealthy = true
            isBootstrapping = false
            sourcePresentation = nil
            turnTransitionNotBefore = Date()
            resetTerminalPresentationCutoff()
            if !isSystemSleeping, update.isComplete, graph.unavailableTurns.isEmpty {
                finishProtectionRecovery(generation: protectionRecoveryGeneration)
            }
            applyPersistedProtection(now: Date())
            reconcileProtection(now: Date(), sendsNotification: false)
        case .sourceUnavailable:
            isActivitySourceHealthy = false
            sourcePresentation = ActivityLiveLabel("unavailable")
            resetTerminalPresentationCutoff()
            beginProtectionRecovery()
            cancelInactivityCheck()
            publishSnapshot(.empty)
            return
        case .live, .lifecycleChanged: break
        }
        if !isSystemSleeping {
            for key in update.backfilledTasks {
                suppressBackfilledActivityTaskIfOverdue(key, now: Date())
            }
        }
        let now = Date()
        let terminalEvents = canPublishActivityTransitions ? update.terminalEvents.filter {
            now.timeIntervalSince($0.endedAt) <= 10 && $0.endedAt >= terminalPresentationNotBefore
        } : []
        refreshSnapshot(now: now, terminalEvents: terminalEvents)
        for transition in update.transitions where isCurrentTransition(transition) {
            transitionSubject.send(transition)
        }
    }

    func isCurrentTransition(_ transition: ActivityTransition, now: Date = Date()) -> Bool {
        guard canPublishActivityTransitions, let turnTransitionNotBefore else { return false }
        let date: Date
        switch transition {
        case let .completed(completion): date = completion.completedAt
        case let .waitingApproval(snapshot):
            guard tasks.values.contains(where: { $0.displayID == snapshot.id && $0.state == .waitingApproval }) else { return false }
            date = snapshot.stateChangedAt
        }
        return date >= turnTransitionNotBefore && now.timeIntervalSince(date) <= 10
    }

    // MARK: - 快照与过期清理

    func refreshSnapshot(now: Date, terminalEvents: [ActivityTerminalEvent] = []) {
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
        let events = terminalEvents.filter { retainedTerminalIDs.contains($0.id) }
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
            .filter { $0.state == state && suppressedTasks[$0.key] == nil && !unavailableTurns.contains($0.key) }
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
        removeExpiredProtectionRecords(now: now)
        graph.prune(now: now)
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
    private static let recoveryRetryInterval: TimeInterval = 1
}
