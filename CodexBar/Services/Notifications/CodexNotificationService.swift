import AppKit
import Combine
import Foundation
import UserNotifications

/// 集中式提醒服务: 订阅额度与实时活动，负责触觉反馈、阈值判定、去重、重置调度与本地通知发送。
@MainActor
final class CodexNotificationService: NSObject {
    private let settings: NotificationSettings
    private let statusViewModel: CodexStatusViewModel
    private let activityMonitor: CodexActivityMonitor
    private let defaults: UserDefaults
    private nonisolated let openMenuSurface: @MainActor @Sendable () -> Void

    private var cancellables = Set<AnyCancellable>()
    private var taskHapticFeedbackTask: Task<Void, Never>?
    private let resetReminderScheduler = ReminderCheckScheduler()
    private let creditExpiryReminderScheduler = ReminderCheckScheduler()
    private var latestQuotaSnapshot: CodexQuotaSnapshot?

    /// 待发送的重置完成提醒与已发送去重键的内存镜像, 变更时才写回 UserDefaults
    private var pendingResetReminders: [PendingQuotaResetReminder]
    private var sentDedupKeys: [String]

    /// 阈值穿越判定的会话内上一帧剩余比例, key 为 account|limitId|windowId
    private var lastRemainingPercents: [String: Int] = [:]

    init(
        settings: NotificationSettings,
        statusViewModel: CodexStatusViewModel,
        activityMonitor: CodexActivityMonitor,
        defaults: UserDefaults = .standard,
        openMenuSurface: @escaping @MainActor @Sendable () -> Void
    ) {
        self.settings = settings
        self.statusViewModel = statusViewModel
        self.activityMonitor = activityMonitor
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

        activityMonitor.transitionPublisher
            .sink { [weak self] transition in
                self?.handleActivityTransition(transition)
            }
            .store(in: &cancellables)
    }

    // MARK: - Hook 任务提醒

    private func handleActivityTransition(_ transition: CodexActivityTransition) {
        performTaskHapticFeedbackIfEnabled()

        guard settings.canDeliver else {
            return
        }

        switch transition {
        case let .waitingApproval(task):
            guard settings.isTaskWaitingEnabled else {
                return
            }
            send(.taskWaiting(project: task.projectName, toolName: task.toolName))
        case let .completed(completion):
            guard settings.isLongTaskEnabled,
                  let duration = completion.duration,
                  duration >= TimeInterval(settings.longTaskThresholdSeconds) else {
                return
            }
            send(.taskCompleted(project: completion.projectName, duration: duration))
        }
    }

    private func performTaskHapticFeedbackIfEnabled() {
        guard settings.canPerformTaskHapticFeedback else {
            return
        }

        taskHapticFeedbackTask?.cancel()
        taskHapticFeedbackTask = Task { @MainActor [weak self] in
            for pulse in 0 ..< Self.taskHapticPulseCount {
                guard let self,
                      !Task.isCancelled,
                      settings.canPerformTaskHapticFeedback else {
                    return
                }

                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
                if pulse < Self.taskHapticPulseCount - 1 {
                    try? await Task.sleep(for: Self.taskHapticPulseInterval)
                }
            }

            self?.taskHapticFeedbackTask = nil
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

        guard let resetsAt = window.resetsAt else {
            return
        }

        // 每个可信额度窗口都登记本周期重置提醒, 不依赖低额度阈值或子开关
        rememberPendingResetReminder(
            accountKey: accountKey,
            limitId: limit.limitId,
            window: window,
            resetsAt: resetsAt
        )

        guard window.remainingPercent <= settings.lowQuotaThresholdPercent,
              settings.isLowQuotaEnabled else {
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

    private nonisolated static func quotaWindowStateKey(
        accountKey: String,
        limitId: String,
        windowId: String
    ) -> String {
        "\(accountKey)|\(limitId)|\(windowId)"
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
    private static let taskHapticPulseCount = 10
    private static let taskHapticPulseInterval = Duration.milliseconds(150)
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
            body: "\(windowLabel) 窗口额度即将重置"
        )
    }

    static func taskCompleted(project: String?, duration: TimeInterval) -> CodexNotificationContent {
        let projectText = project.map { "「\($0)」" } ?? "Codex"
        return CodexNotificationContent(
            title: "Codex 任务完成",
            body: "\(projectText) 任务完成, 耗时 \(CodexActivityDurationFormat.text(for: duration))"
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

/// 已知下次重置时间的额度窗口, 在 resetsAt 到达时发送提醒
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
