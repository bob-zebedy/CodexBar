import AppKit
import Combine
import Foundation
import UserNotifications

/// 集中式通知服务: 订阅额度快照, 负责阈值判定、去重、重置调度与本地通知发送
/// 任务完成和等待批准通知的 Hook 事件接入见 handleHookEvents
@MainActor
final class CodexNotificationService: NSObject {
    private let settings: NotificationSettings
    private let statusViewModel: CodexStatusViewModel
    private let codexHookSettings: CodexHookSettings
    private let defaults: UserDefaults
    private nonisolated let openMenuSurface: @MainActor @Sendable () -> Void

    private var cancellables = Set<AnyCancellable>()
    private let resetReminderScheduler = ReminderCheckScheduler()
    private let creditExpiryReminderScheduler = ReminderCheckScheduler()
    private var latestQuotaSnapshot: CodexQuotaSnapshot?

    /// 待发送的重置完成提醒与已发送去重键的内存镜像, 变更时才写回 UserDefaults
    private var pendingResetReminders: [PendingQuotaResetReminder]
    private var sentDedupKeys: [String]

    /// 阈值穿越判定的会话内上一帧剩余比例, key 为 account|limitId|windowId
    private var lastRemainingPercents: [String: Int] = [:]

    private var tailReader: HookEventTailReader?

    /// 起点事件配对表: 优先 session|turn 精确配对, 回退 session 最近一条
    private var promptTimesByTurn: [String: Date] = [:]
    private var promptTimesBySession: [String: Date] = [:]
    private var taskWaitingNotificationTimesByKey: [String: Date] = [:]

    init(
        settings: NotificationSettings,
        statusViewModel: CodexStatusViewModel,
        codexHookSettings: CodexHookSettings,
        defaults: UserDefaults = .standard,
        openMenuSurface: @escaping @MainActor @Sendable () -> Void
    ) {
        self.settings = settings
        self.statusViewModel = statusViewModel
        self.codexHookSettings = codexHookSettings
        self.defaults = defaults
        self.openMenuSurface = openMenuSurface
        pendingResetReminders = Self.loadPendingResetReminders(from: defaults)
        sentDedupKeys = defaults.stringArray(forKey: Self.sentKeysKey) ?? []
        super.init()
    }

    func start() {
        UNUserNotificationCenter.current().delegate = self
        settings.refreshAuthorizationStatus()

        statusViewModel.$snapshot
            .sink { [weak self] snapshot in
                self?.handleSnapshot(snapshot)
            }
            .store(in: &cancellables)

        Publishers.CombineLatest(
            settings.$isLowQuotaEnabled,
            settings.$lowQuotaThresholdPercent
        )
        .dropFirst()
        .sink { [weak self] _, _ in
            self?.reevaluateLowQuotaSettings()
        }
        .store(in: &cancellables)

        // 休眠可能错过 resetsAt, 唤醒时补检
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.deliverDueResetReminders()
                self?.deliverDueCreditExpiryReminders()
            }
            .store(in: &cancellables)

        // 两类 Hook 通知任一开启, 且总开关、授权和 Hook 状态满足时运行 tail
        Publishers.CombineLatest(
            Publishers.CombineLatest4(
                settings.$isEnabled,
                settings.$isLongTaskEnabled,
                settings.$isTaskWaitingEnabled,
                settings.$authorizationStatus
            ),
            codexHookSettings.$isEnabled
        )
        .map { notificationState, hook in
            let (enabled, longTask, taskWaiting, authorizationStatus) = notificationState
            return enabled
                && (longTask || taskWaiting)
                && authorizationStatus != .denied
                && hook
        }
        .removeDuplicates()
        .sink { [weak self] shouldRun in
            self?.setTailReaderActive(shouldRun)
        }
        .store(in: &cancellables)

        // 等待批准通知仍在运行 tail 时, 关闭任务完成通知也要立即丢弃未完成的计时配对
        settings.$isLongTaskEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard !enabled else {
                    return
                }
                self?.promptTimesByTurn.removeAll()
                self?.promptTimesBySession.removeAll()
            }
            .store(in: &cancellables)
    }

    // MARK: - Hook 任务通知

    private func setTailReaderActive(_ active: Bool) {
        if active {
            guard tailReader == nil else {
                return
            }

            let reader = HookEventTailReader { [weak self] events in
                self?.handleHookEvents(events)
            }
            reader.start()
            tailReader = reader
            return
        }

        tailReader?.stop()
        tailReader = nil
        promptTimesByTurn.removeAll()
        promptTimesBySession.removeAll()
        taskWaitingNotificationTimesByKey.removeAll()
    }

    private func handleHookEvents(_ events: [WorkflowHookEvent]) {
        for event in events {
            switch event.hookEvent {
            case .userPromptSubmit:
                guard settings.isLongTaskEnabled,
                      let sessionId = event.sessionId else {
                    continue
                }
                promptTimesBySession[sessionId] = event.timestamp
                if let turnId = event.turnId {
                    promptTimesByTurn[Self.hookTurnKey(sessionId: sessionId, turnId: turnId)] = event.timestamp
                }
            case .stop:
                guard settings.isLongTaskEnabled,
                      let sessionId = event.sessionId else {
                    continue
                }
                notifyLongTaskIfNeeded(stopEvent: event, sessionId: sessionId)
            case .permissionRequest:
                notifyTaskWaitingIfNeeded(event)
            default:
                continue
            }
        }

        pruneHookNotificationState()
    }

    private func notifyTaskWaitingIfNeeded(_ event: WorkflowHookEvent) {
        guard settings.isTaskWaitingEnabled else {
            return
        }

        let key = Self.taskWaitingNotificationKey(for: event)
        guard taskWaitingNotificationTimesByKey[key] == nil else {
            return
        }
        taskWaitingNotificationTimesByKey[key] = event.timestamp

        send(.taskWaiting(project: event.projectDisplayName, toolName: event.toolName))
    }

    private func notifyLongTaskIfNeeded(stopEvent event: WorkflowHookEvent, sessionId: String) {
        let turnStart = event.turnId.flatMap {
            promptTimesByTurn.removeValue(
                forKey: Self.hookTurnKey(sessionId: sessionId, turnId: $0)
            )
        }
        let start = turnStart ?? promptTimesBySession[sessionId]

        // 一条 Stop 只配对一次, 防止后续无提交的 Stop 重复计时
        promptTimesBySession.removeValue(forKey: sessionId)

        guard let start else {
            return
        }

        let duration = event.timestamp.timeIntervalSince(start)
        guard duration >= TimeInterval(settings.longTaskThresholdSeconds) else {
            return
        }

        send(.taskCompleted(project: event.projectDisplayName, duration: duration))
    }

    private func pruneHookNotificationState() {
        let cutoff = Date().addingTimeInterval(-Self.promptRetention)
        promptTimesBySession = promptTimesBySession.filter { $0.value > cutoff }
        promptTimesByTurn = promptTimesByTurn.filter { $0.value > cutoff }
        taskWaitingNotificationTimesByKey = taskWaitingNotificationTimesByKey.filter {
            $0.value > cutoff
        }
    }

    // MARK: - 快照处理

    private func handleSnapshot(_ snapshot: CodexQuotaSnapshot?) {
        guard let snapshot else {
            latestQuotaSnapshot = nil
            scheduleNextCreditExpiryCheck(dates: [])
            return
        }

        latestQuotaSnapshot = snapshot

        guard settings.canDeliver else {
            scheduleNextCreditExpiryCheck(dates: [])
            return
        }

        // stale 快照是旧缓存, 不参与额度判定, 避免误报
        if !snapshot.isRateLimitsStale {
            processQuotaWindows(snapshot)
        }

        processCreditExpirations(snapshot)
        deliverDueResetReminders()
    }

    private func processQuotaWindows(_ snapshot: CodexQuotaSnapshot) {
        let accountKey = Self.accountKey(for: snapshot)
        for limit in snapshot.limits {
            for window in limit.windows where window.hasData {
                processQuotaWindow(
                    window,
                    limit: limit,
                    accountKey: accountKey
                )
            }
        }
    }

    private func reevaluateLowQuotaSettings() {
        guard settings.canDeliver,
              settings.isLowQuotaEnabled,
              let snapshot = latestQuotaSnapshot,
              !snapshot.isRateLimitsStale else {
            return
        }

        resetQuotaObservation(for: snapshot)
        processQuotaWindows(snapshot)
    }

    private func resetQuotaObservation(for snapshot: CodexQuotaSnapshot) {
        let accountKey = Self.accountKey(for: snapshot)
        for limit in snapshot.limits {
            for window in limit.windows where window.hasData {
                let stateKey = Self.quotaWindowStateKey(
                    accountKey: accountKey,
                    limitId: limit.limitId,
                    windowId: window.id
                )
                lastRemainingPercents.removeValue(forKey: stateKey)
            }
        }
    }

    private func processQuotaWindow(
        _ window: QuotaWindow,
        limit: CodexQuotaLimitSnapshot,
        accountKey: String
    ) {
        let stateKey = Self.quotaWindowStateKey(
            accountKey: accountKey,
            limitId: limit.limitId,
            windowId: window.id
        )
        let previous = lastRemainingPercents[stateKey]
        lastRemainingPercents[stateKey] = window.remainingPercent

        guard let resetsAt = window.resetsAt,
              window.remainingPercent <= settings.lowQuotaThresholdPercent else {
            return
        }

        // 记录本周期曾跌破阈值, 供重置完成提醒做门槛; 与低阈值子开关无关
        rememberPendingResetReminder(
            accountKey: accountKey,
            limitId: limit.limitId,
            window: window,
            resetsAt: resetsAt
        )

        guard settings.isLowQuotaEnabled else {
            return
        }

        // 穿越判定: 上一帧高于阈值才提醒; 会话内首次观察即低于也视为穿越
        // (App 可能在跌破后才启动), 持久化去重键保证每周期只发一次
        if let previous, previous <= settings.lowQuotaThresholdPercent {
            return
        }

        let dedupKey = "low|\(accountKey)|\(limit.limitId)|\(window.id)|\(Self.epoch(resetsAt))"
        guard consumeDedupKey(dedupKey) else {
            return
        }

        send(
            .lowQuota(
                limitTitle: limit.title,
                windowLabel: window.label,
                thresholdPercent: settings.lowQuotaThresholdPercent
            )
        )
    }

    // MARK: - 重置完成提醒

    private func rememberPendingResetReminder(
        accountKey: String,
        limitId: String,
        window: QuotaWindow,
        resetsAt: Date
    ) {
        let reminder = PendingQuotaResetReminder(
            accountKey: accountKey,
            limitId: limitId,
            windowId: window.id,
            windowLabel: window.label,
            resetsAt: resetsAt,
            windowDurationMins: window.windowDurationMins
        )

        guard !pendingResetReminders.contains(reminder), !hasSent(reminder.dedupKey) else {
            return
        }

        pendingResetReminders.append(reminder)
        persistPendingResetReminders()
    }

    private func deliverDueResetReminders() {
        let now = Date()
        var remaining: [PendingQuotaResetReminder] = []

        for reminder in pendingResetReminders {
            if reminder.resetsAt > now {
                remaining.append(reminder)
                continue
            }

            // 已到重置时刻: 超时效或已发过的直接丢弃
            guard now < reminder.validUntil, !hasSent(reminder.dedupKey) else {
                continue
            }

            // 开关或授权此刻关闭时保留, 时效内等下一次快照/唤醒重试
            guard settings.canDeliver,
                  settings.isQuotaResetEnabled,
                  consumeDedupKey(reminder.dedupKey) else {
                remaining.append(reminder)
                continue
            }

            send(.quotaReset(windowLabel: reminder.windowLabel))
        }

        if remaining != pendingResetReminders {
            pendingResetReminders = remaining
            persistPendingResetReminders()
        }
        scheduleNextResetCheck()
    }

    private func scheduleNextResetCheck() {
        let now = Date()
        let nextDate = pendingResetReminders.map(\.resetsAt).filter { $0 > now }.min()
        resetReminderScheduler.schedule(at: nextDate) { [weak self] in
            self?.deliverDueResetReminders()
        }
    }

    // MARK: - 重置次数临期提醒

    private func processCreditExpirations(_ snapshot: CodexQuotaSnapshot) {
        guard settings.isCreditExpiryEnabled,
              let dates = snapshot.resetCreditExpirationDates else {
            scheduleNextCreditExpiryCheck(dates: [])
            return
        }

        let accountKey = Self.accountKey(for: snapshot)
        let now = Date()
        let dueDates = dates.filter {
            Self.creditExpiryReminderDay(expirationDate: $0, now: now) != nil
        }

        // 相同过期时间的机会合并成一条通知; 按秒分组与去重键口径保持一致
        for (epochSecond, groupedDates) in Dictionary(grouping: dueDates, by: { Self.epoch($0) }) {
            guard let date = groupedDates.first,
                  let reminderDay = Self.creditExpiryReminderDay(expirationDate: date, now: now) else {
                continue
            }

            let dedupKey = "credit|\(accountKey)|\(epochSecond)|\(reminderDay)d"
            guard consumeDedupKey(dedupKey) else {
                continue
            }

            send(.creditExpiry(count: groupedDates.count, expirationDate: date))
        }

        scheduleNextCreditExpiryCheck(dates: dates)
    }

    private func deliverDueCreditExpiryReminders() {
        guard let latestQuotaSnapshot, settings.canDeliver else {
            scheduleNextCreditExpiryCheck(dates: [])
            return
        }

        processCreditExpirations(latestQuotaSnapshot)
    }

    private func scheduleNextCreditExpiryCheck(dates: [Date]) {
        let now = Date()
        let nextDate = dates
            .flatMap(Self.creditExpiryReminderDates)
            .filter { $0 > now }
            .min()
        creditExpiryReminderScheduler.schedule(at: nextDate) { [weak self] in
            self?.deliverDueCreditExpiryReminders()
        }
    }

    // MARK: - 去重与持久化

    /// 未发过则记录并返回 true; 已发过返回 false
    private func consumeDedupKey(_ key: String) -> Bool {
        guard !sentDedupKeys.contains(key) else {
            return false
        }

        sentDedupKeys.append(key)
        if sentDedupKeys.count > Self.sentKeysLimit {
            sentDedupKeys.removeFirst(sentDedupKeys.count - Self.sentKeysLimit)
        }

        defaults.set(sentDedupKeys, forKey: Self.sentKeysKey)
        return true
    }

    private func hasSent(_ key: String) -> Bool {
        sentDedupKeys.contains(key)
    }

    private static func loadPendingResetReminders(from defaults: UserDefaults) -> [PendingQuotaResetReminder] {
        guard let data = defaults.data(forKey: pendingResetRemindersKey),
              let reminders = try? JSONDecoder().decode(
                  [PendingQuotaResetReminder].self,
                  from: data
              ) else {
            return []
        }

        return reminders
    }

    private func persistPendingResetReminders() {
        guard let data = try? JSONEncoder().encode(pendingResetReminders) else {
            return
        }

        defaults.set(data, forKey: Self.pendingResetRemindersKey)
    }

    // MARK: - 发送与文案

    private func send(_ notification: CodexNotificationContent) {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private nonisolated static func accountKey(for snapshot: CodexQuotaSnapshot) -> String {
        snapshot.account.email ?? snapshot.account.type
    }

    private nonisolated static func epoch(_ date: Date) -> Int {
        Int(date.timeIntervalSince1970)
    }

    private nonisolated static func hookTurnKey(sessionId: String, turnId: String) -> String {
        "\(sessionId)|\(turnId)"
    }

    private nonisolated static func quotaWindowStateKey(
        accountKey: String,
        limitId: String,
        windowId: String
    ) -> String {
        "\(accountKey)|\(limitId)|\(windowId)"
    }

    private nonisolated static func taskWaitingNotificationKey(for event: WorkflowHookEvent) -> String {
        let milliseconds = Int64((event.timestamp.timeIntervalSince1970 * 1000).rounded())
        return [
            String(milliseconds),
            event.sessionId ?? "",
            event.turnId ?? "",
            event.toolName ?? ""
        ].joined(separator: "|")
    }

    private nonisolated static func creditExpiryReminderDates(for expirationDate: Date) -> [Date] {
        creditExpiryReminderDays.map {
            expirationDate.addingTimeInterval(-TimeInterval($0) * day)
        }
    }

    private nonisolated static func creditExpiryReminderDay(
        expirationDate: Date,
        now: Date
    ) -> Int? {
        let remaining = expirationDate.timeIntervalSince(now)
        guard remaining > 0, remaining <= creditExpiryLeadTime else {
            return nil
        }

        for reminderDay in creditExpiryReminderDays where remaining > TimeInterval(reminderDay - 1) * day {
            return reminderDay
        }

        return 1
    }

    private nonisolated static let day: TimeInterval = 24 * 3600
    private nonisolated static let creditExpiryReminderDays = [7, 6, 5, 4, 3, 2, 1]
    private nonisolated static let creditExpiryLeadTime: TimeInterval = 7 * day
    private static let promptRetention: TimeInterval = 24 * 3600
    private static let sentKeysLimit = 300
    private static let sentKeysKey = "Notification.sentKeys"
    private static let pendingResetRemindersKey = "Notification.pendingResetReminders"
}

nonisolated struct CodexNotificationContent: Equatable {
    let title: String
    let body: String

    static func lowQuota(
        limitTitle: String,
        windowLabel: String,
        thresholdPercent: Int
    ) -> CodexNotificationContent {
        CodexNotificationContent(
            title: "Codex 额度不足",
            body: "\(limitTitle) \(windowLabel) 剩余额度已低于 \(thresholdPercent)%"
        )
    }

    static func quotaReset(windowLabel: String) -> CodexNotificationContent {
        CodexNotificationContent(
            title: "Codex 额度重置",
            body: "\(windowLabel) 窗口额度已重置"
        )
    }

    static func taskCompleted(project: String?, duration: TimeInterval) -> CodexNotificationContent {
        let projectText = project.map { "「\($0)」" } ?? "Codex"
        return CodexNotificationContent(
            title: "Codex 任务完成",
            body: "\(projectText) 任务完成, 耗时 \(durationText(duration))"
        )
    }

    static func taskWaiting(project: String?, toolName: String?) -> CodexNotificationContent {
        let subject = project.map { "「\($0)」" } ?? "Codex"
        let action = toolName.map { "\($0) 操作" } ?? "下一步操作"
        return CodexNotificationContent(
            title: "Codex 等待批准",
            body: "\(subject) 正在等待批准 \(action)"
        )
    }

    static func creditExpiry(count: Int, expirationDate: Date) -> CodexNotificationContent {
        CodexNotificationContent(
            title: "重置次数即将过期",
            body: "有 \(count) 个重置次数将于 \(CodexDateFormat.localDisplayString(from: expirationDate)) 过期"
        )
    }

    private static func durationText(_ interval: TimeInterval) -> String {
        let totalSeconds = Int(interval.rounded())
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        if minutes >= 60 {
            return "\(minutes / 60) 小时 \(minutes % 60) 分"
        }

        if minutes > 0 {
            return "\(minutes) 分 \(seconds) 秒"
        }

        return "\(seconds) 秒"
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension CodexNotificationService: UNUserNotificationCenterDelegate {
    /// 菜单栏常驻应用处于前台时也要展示横幅
    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent _: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive _: UNNotificationResponse
    ) async {
        await openMenuSurface()
    }
}

/// 单一待办时刻的重检调度: 目标时刻未变化时不重建 Task, 避免每个快照 tick 都 cancel/respawn
@MainActor
private final class ReminderCheckScheduler {
    private var task: Task<Void, Never>?
    private var armedDate: Date?

    /// date 为 nil 时取消当前调度
    func schedule(at date: Date?, action: @escaping @MainActor () -> Void) {
        if let date, date == armedDate, task != nil {
            return
        }

        task?.cancel()
        task = nil
        armedDate = date
        guard let date else {
            return
        }

        task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(date.timeIntervalSinceNow + 1))
            guard !Task.isCancelled else {
                return
            }

            self?.task = nil
            self?.armedDate = nil
            action()
        }
    }
}

/// 本周期曾跌破阈值的窗口, 等待 resetsAt 到达后发送恢复提醒
private nonisolated struct PendingQuotaResetReminder: Codable, Equatable {
    let accountKey: String
    let limitId: String
    let windowId: String
    let windowLabel: String
    let resetsAt: Date
    let windowDurationMins: Int?

    var dedupKey: String {
        "reset|\(accountKey)|\(limitId)|\(windowId)|\(Int(resetsAt.timeIntervalSince1970))"
    }

    /// 补发时效: 超过一个窗口周期不再提醒, 周期未知按 24h
    var validUntil: Date {
        resetsAt.addingTimeInterval(TimeInterval((windowDurationMins ?? 1440) * 60))
    }
}
