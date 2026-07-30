import AppKit
import Combine
import Foundation
import os
import UserNotifications

/// 集中式提醒服务: 订阅额度与实时活动, 负责触觉反馈; 阈值判定; 去重; 重置识别与本地通知发送
@MainActor
final class CodexNotificationService: NSObject {
    private let settings: NotificationSettings
    private let statusViewModel: CodexStatusViewModel
    private let activityMonitor: CodexActivityMonitor
    private let defaults: UserDefaults
    private nonisolated let openMenuSurface: @MainActor @Sendable () -> Void

    private var cancellables = Set<AnyCancellable>()
    private var taskHapticFeedbackTask: Task<Void, Never>?
    private var taskWaitingNotificationIdentifiers = Set<String>()
    private let creditExpiryReminderScheduler = ReminderCheckScheduler()
    private var latestQuotaSnapshot: CodexQuotaSnapshot?

    /// 已发送去重键的内存镜像, 变更时才写回 UserDefaults
    private var sentDedupKeys: [String]
    private var submittingDedupKeys = Set<String>()

    /// 阈值穿越判定的会话内上一帧剩余比例, key 为 account|limitId|windowId
    private var lastRemainingPercents: [String: Int] = [:]

    /// 低额度判定依据的两个设置项
    /// 订阅回调跑在 @Published 的 willSet, 那时属性还是旧值, 只有回调参数是新的
    /// 所以由调用方给出而不是在判定处回读 settings
    private struct LowQuotaConditions {
        let isEnabled: Bool
        let thresholdPercent: Int
    }

    /// 额度刷新那条路径上设置没有在变, 现场取值就是最新的
    private var currentLowQuotaConditions: LowQuotaConditions {
        LowQuotaConditions(
            isEnabled: settings.isLowQuotaEnabled,
            thresholdPercent: settings.lowQuotaThresholdPercent
        )
    }

    /// 可信快照中每个额度窗口的重置观察状态; 窗口消失后重现会获得新的生命周期标记
    private var quotaWindowResetObservations: [String: QuotaWindowResetObservation] = [:]

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
        let storedDedupKeys = defaults.stringArray(forKey: Self.sentKeysKey) ?? []
        sentDedupKeys = storedDedupKeys.filter { !$0.hasPrefix(Self.legacyResetDedupKeyPrefix) }
        if sentDedupKeys.count != storedDedupKeys.count {
            defaults.set(sentDedupKeys, forKey: Self.sentKeysKey)
        }
        defaults.removeObject(forKey: Self.legacyPendingResetReminderKey)
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
        .sink { [weak self] isEnabled, thresholdPercent in
            self?.reevaluateLowQuota(
                LowQuotaConditions(isEnabled: isEnabled, thresholdPercent: thresholdPercent)
            )
        }
        .store(in: &cancellables)

        // 休眠可能错过重置次数的临期检查, 唤醒时补检
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.deliverDueCreditExpiryReminders()
            }
            .store(in: &cancellables)

        activityMonitor.transitionPublisher
            .sink { [weak self] transition in
                self?.handleActivityTransition(transition)
            }
            .store(in: &cancellables)

        activityMonitor.$snapshot
            .sink { [weak self] snapshot in
                self?.reconcileTaskWaitingNotifications(with: snapshot)
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
            let taskID = task.id
            let identifier = Self.taskWaitingNotificationIdentifier(for: taskID)
            taskWaitingNotificationIdentifiers.insert(identifier)
            send(
                .taskWaiting(project: task.projectName, toolName: task.toolName),
                sound: settings.taskWaitingSound,
                identifier: identifier,
                isStillRelevant: { [weak self] in
                    self?.isTaskStillWaiting(
                        taskID,
                        notificationIdentifier: identifier
                    ) ?? false
                },
                onSubmissionFailure: { [weak self] in
                    self?.taskWaitingNotificationIdentifiers.remove(identifier)
                }
            )
        case let .completed(completion):
            guard settings.isLongTaskEnabled,
                  let duration = completion.duration,
                  duration >= TimeInterval(settings.longTaskThresholdSeconds) else {
                return
            }
            send(
                .taskCompleted(project: completion.projectName, duration: duration),
                sound: settings.longTaskSound
            )
        }
    }

    private func isTaskStillWaiting(
        _ taskID: UUID,
        notificationIdentifier: String
    ) -> Bool {
        let isStillWaiting = activityMonitor.snapshot.waitingTasks.contains {
            $0.id == taskID
        }
        if !isStillWaiting {
            taskWaitingNotificationIdentifiers.remove(notificationIdentifier)
        }
        return isStillWaiting
    }

    private func reconcileTaskWaitingNotifications(with snapshot: CodexActivitySnapshot) {
        let activeIdentifiers = Set(snapshot.waitingTasks.map {
            Self.taskWaitingNotificationIdentifier(for: $0.id)
        })
        let obsoleteIdentifiers = taskWaitingNotificationIdentifiers.subtracting(activeIdentifiers)
        guard !obsoleteIdentifiers.isEmpty else {
            return
        }

        let identifiers = Array(obsoleteIdentifiers)
        removeNotifications(withIdentifiers: identifiers)
        taskWaitingNotificationIdentifiers.subtract(obsoleteIdentifiers)
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
            quotaWindowResetObservations.removeAll()
            scheduleNextCreditExpiryCheck(dates: [])
            return
        }

        latestQuotaSnapshot = snapshot

        // stale 快照是旧缓存, 不参与额度判定, 避免误报
        if !snapshot.isRateLimitsStale {
            processQuotaWindows(snapshot, lowQuota: currentLowQuotaConditions)
        }

        guard settings.canDeliver else {
            scheduleNextCreditExpiryCheck(dates: [])
            return
        }

        processCreditExpirations(snapshot)
    }

    private func processQuotaWindows(
        _ snapshot: CodexQuotaSnapshot,
        lowQuota: LowQuotaConditions
    ) {
        var observedWindowKeys = Set<String>()
        forEachQuotaWindowWithData(in: snapshot) { window, limit, stateKey in
            observedWindowKeys.insert(stateKey)
            if quotaWindowResetObservations[stateKey] == nil {
                quotaWindowResetObservations[stateKey] = QuotaWindowResetObservation()
            }
            processQuotaWindow(window, limit: limit, stateKey: stateKey, lowQuota: lowQuota)
        }
        quotaWindowResetObservations = quotaWindowResetObservations.filter {
            observedWindowKeys.contains($0.key)
        }
    }

    /// 枚举可信快照中有数据的额度窗口, 窗口过滤与 stateKey 口径的唯一定义处
    private func forEachQuotaWindowWithData(
        in snapshot: CodexQuotaSnapshot,
        _ body: (QuotaWindow, CodexQuotaLimitSnapshot, String) -> Void
    ) {
        let accountKey = Self.accountKey(for: snapshot)
        for limit in snapshot.limits {
            for window in limit.windows where window.hasData {
                let stateKey = Self.quotaWindowStateKey(
                    accountKey: accountKey,
                    limitId: limit.limitId,
                    windowId: window.id
                )
                body(window, limit, stateKey)
            }
        }
    }

    /// 设置刚变就按新值重判一次, 不必等下一个刷新周期
    /// 清掉上一帧观察是为了让新阈值能立刻穿越, 所以这里必须用新值判断, 否则清了也白清
    private func reevaluateLowQuota(_ conditions: LowQuotaConditions) {
        guard settings.canDeliver,
              conditions.isEnabled,
              let snapshot = latestQuotaSnapshot,
              !snapshot.isRateLimitsStale else {
            return
        }

        resetLowQuotaObservation(for: snapshot)
        processQuotaWindows(snapshot, lowQuota: conditions)
    }

    private func resetLowQuotaObservation(for snapshot: CodexQuotaSnapshot) {
        forEachQuotaWindowWithData(in: snapshot) { _, _, stateKey in
            lastRemainingPercents.removeValue(forKey: stateKey)
        }
    }

    private func processQuotaWindow(
        _ window: QuotaWindow,
        limit: CodexQuotaLimitSnapshot,
        stateKey: String,
        lowQuota: LowQuotaConditions
    ) {
        guard let usedPercent = window.usedPercent else {
            return
        }

        trackQuotaResetTransition(
            stateKey: stateKey,
            usedPercent: usedPercent,
            limit: limit,
            window: window
        )

        guard settings.canDeliver else {
            return
        }

        let previousRemainingPercent = lastRemainingPercents[stateKey]
        lastRemainingPercents[stateKey] = window.remainingPercent

        guard let resetsAt = window.resetsAt,
              window.remainingPercent <= lowQuota.thresholdPercent,
              lowQuota.isEnabled else {
            return
        }

        // 穿越判定: 上一帧高于阈值才提醒; 会话内首次观察即低于也视为穿越
        // (App 可能在跌破后才启动), 持久化去重键保证每周期只发一次
        if let previousRemainingPercent,
           previousRemainingPercent <= lowQuota.thresholdPercent {
            return
        }

        // 阈值是用户设置值不是用量数据, 记它才能解释这条通知为什么会发出来
        let threshold = lowQuota.thresholdPercent
        AppLog.notification.notice(
            "阈值已穿越: kind=lowQuota; threshold=\(threshold); direction=down"
        )

        let dedupKey = "low|\(stateKey)|\(Self.epoch(resetsAt))"
        send(
            .lowQuota(
                limitTitle: limit.title,
                windowLabel: window.label,
                thresholdPercent: lowQuota.thresholdPercent
            ),
            sound: settings.lowQuotaSound,
            dedupKey: dedupKey,
            onSubmissionFailure: { [weak self] in
                self?.lastRemainingPercents.removeValue(forKey: stateKey)
            }
        )
    }

    // MARK: - 额度重置提醒

    private func trackQuotaResetTransition(
        stateKey: String,
        usedPercent: Int,
        limit: CodexQuotaLimitSnapshot,
        window: QuotaWindow
    ) {
        if usedPercent > 0 {
            quotaWindowResetObservations[stateKey]?.hasObservedConsumption = true
        } else if usedPercent == 0,
                  quotaWindowResetObservations[stateKey]?.hasObservedConsumption == true {
            // 归零即消费待重置状态; 开关或授权此刻不可用时不保留补发
            quotaWindowResetObservations[stateKey]?.hasObservedConsumption = false
            guard settings.canDeliver,
                  settings.isQuotaResetEnabled,
                  let lifecycleToken = quotaWindowResetObservations[stateKey]?.lifecycleToken else {
                return
            }

            AppLog.notification.notice("额度已重置: kind=quotaReset")

            let dedupKey = window.resetsAt.map { resetsAt in
                "quotaReset|\(stateKey)|\(Self.epoch(resetsAt))"
            }
            send(
                .quotaReset(
                    limitTitle: limit.title,
                    windowLabel: window.label
                ),
                sound: settings.quotaResetSound,
                dedupKey: dedupKey,
                onSubmissionFailure: { [weak self] in
                    guard let self,
                          quotaWindowResetObservations[stateKey]?.lifecycleToken == lifecycleToken else {
                        return
                    }

                    quotaWindowResetObservations[stateKey]?.hasObservedConsumption = true
                }
            )
        }
    }

    // MARK: - 低电量保护

    /// 由 KeepAliveController 在低电量导致休眠恢复成功之后调用, 恢复失败不会走到这里
    /// 不做去重: 调用方自己保证同一轮低电量只发一次, 电量回到解除门槛以上才算下一轮
    /// async 是为了让调用方能等提交完再补发休眠, 否则合着盖的机器会先睡下去
    /// 返回是否真的发出去了: 调用方据此决定这一轮算不算已通知, 提交失败就不该占掉这一轮
    func notifyLowBatteryProtection(percent: Int) async -> Bool {
        guard settings.canDeliver, settings.isLowBatteryEnabled else {
            return false
        }

        return await send(
            .lowBattery(percent: percent),
            sound: settings.lowBatterySound
        )?.value ?? false
    }

    // MARK: - 防休眠时长上限

    /// 由 KeepAliveController 在达到时长上限且休眠恢复成功之后调用
    /// 调用时机与低电量通知相同, 必须赶在可能补发合盖休眠之前完成提交
    func notifyKeepAliveLimitReached(durationText: String) async -> Bool {
        guard settings.canDeliver, settings.isKeepAliveLimitEnabled else {
            return false
        }

        return await send(
            .keepAliveLimit(durationText: durationText),
            sound: settings.keepAliveLimitSound
        )?.value ?? false
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
            send(
                .creditExpiry(count: groupedDates.count, expirationDate: date),
                sound: settings.creditExpirySound,
                dedupKey: dedupKey
            )
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

    private func rememberSentDedupKey(_ key: String) {
        sentDedupKeys.append(key)
        if sentDedupKeys.count > Self.sentKeysLimit {
            sentDedupKeys.removeFirst(sentDedupKeys.count - Self.sentKeysLimit)
        }

        defaults.set(sentDedupKeys, forKey: Self.sentKeysKey)
    }

    // MARK: - 发送与文案

    /// 通知的 title 与 body 含项目名和任务信息, 一律不进日志, 只记 kind
    /// 返回提交任务, 需要等通知真的发出去再做下一步的调用方 await 它的 value
    /// 只有这一个入口: 另开一条 async 通道会让它悄悄少掉去重 时效判定和失败回调三项能力
    /// 去重判定留在同步段, 这样连续两次 send 的第二次一定被挡下, 不依赖 Task 的调度顺序
    @discardableResult
    private func send(
        _ notification: CodexNotificationContent,
        sound: NotificationSoundOption,
        identifier: String = UUID().uuidString,
        dedupKey: String? = nil,
        isStillRelevant: (() -> Bool)? = nil,
        onSubmissionFailure: (() -> Void)? = nil
    ) -> Task<Bool, Never>? {
        let kind = notification.kind
        if let dedupKey {
            guard !sentDedupKeys.contains(dedupKey),
                  submittingDedupKeys.insert(dedupKey).inserted else {
                AppLog.notification.notice("通知已跳过: kind=\(kind, privacy: .public); reason=duplicate")
                return nil
            }
        }

        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = sound.notificationSound

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )
        return Task { @MainActor [weak self] in
            await self?.deliver(
                request,
                kind: kind,
                dedupKey: dedupKey,
                isStillRelevant: isStillRelevant,
                onSubmissionFailure: onSubmissionFailure
            ) ?? false
        }
    }

    /// 返回值是"这条通知真的提交出去了", 调用方据此决定要不要记下已通知
    private func deliver(
        _ request: UNNotificationRequest,
        kind: String,
        dedupKey: String?,
        isStillRelevant: (() -> Bool)?,
        onSubmissionFailure: (() -> Void)?
    ) async -> Bool {
        defer {
            if let dedupKey {
                submittingDedupKeys.remove(dedupKey)
            }
        }

        for _ in 0 ... Self.notificationSubmissionRetryCount {
            guard isStillRelevant?() != false else {
                AppLog.notification.notice(
                    "通知已跳过: kind=\(kind, privacy: .public); reason=obsolete"
                )
                return false
            }
            do {
                try await UNUserNotificationCenter.current().add(request)
                guard isStillRelevant?() != false else {
                    // 投递后任务状态又变了, 撤回避免用户看到过期提醒
                    AppLog.notification.notice(
                        "通知已撤回: kind=\(kind, privacy: .public); reason=obsolete"
                    )
                    removeNotifications(withIdentifiers: [request.identifier])
                    return false
                }
                if let dedupKey {
                    rememberSentDedupKey(dedupKey)
                }
                AppLog.notification.notice("通知已发送: kind=\(kind, privacy: .public)")
                return true
            } catch {
                continue
            }
        }

        // 重试全部用尽才记, 循环内的单次失败会重试
        AppLog.notification.error(
            "通知发送失败: kind=\(kind, privacy: .public); reason=retryExhausted"
        )
        onSubmissionFailure?()
        return false
    }

    private func removeNotifications(withIdentifiers identifiers: [String]) {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    private nonisolated static func accountKey(for snapshot: CodexQuotaSnapshot) -> String {
        snapshot.account.email ?? snapshot.account.type
    }

    private nonisolated static func epoch(_ date: Date) -> Int {
        Int(date.timeIntervalSince1970)
    }

    private nonisolated static func taskWaitingNotificationIdentifier(for taskID: UUID) -> String {
        "taskWaiting|\(taskID.uuidString)"
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
    private static let taskHapticPulseInterval = Duration.milliseconds(100)
    private static let notificationSubmissionRetryCount = 1
    private static let sentKeysLimit = 300
    private static let sentKeysKey = "Notification.sentKeys"
    private static let legacyResetDedupKeyPrefix = "reset|"
    private static let legacyPendingResetReminderKey = "Notification.pendingResetReminders"

    /// 单个额度窗口的重置观察状态: 记录大于 0 的消耗, 归零时消费并发送
    private struct QuotaWindowResetObservation {
        /// 窗口生命周期标记, 迟到的发送失败回调据此丢弃
        let lifecycleToken = UUID()
        var hasObservedConsumption = false
    }
}

nonisolated struct CodexNotificationContent: Equatable {
    /// 只用于日志分类, 由各静态工厂带出, 保证与实际内容不会错位
    let kind: String
    let title: String
    let body: String

    static func lowQuota(
        limitTitle: String,
        windowLabel: String,
        thresholdPercent: Int
    ) -> CodexNotificationContent {
        CodexNotificationContent(
            kind: "lowQuota",
            title: "Codex 额度不足",
            body: "\(limitTitle) \(windowLabel) 剩余额度已低于 \(thresholdPercent)%"
        )
    }

    static func quotaReset(
        limitTitle: String,
        windowLabel: String
    ) -> CodexNotificationContent {
        CodexNotificationContent(
            kind: "quotaReset",
            title: "额度已重置",
            body: "\(limitTitle) \(windowLabel)"
        )
    }

    static func taskCompleted(project: String?, duration: TimeInterval) -> CodexNotificationContent {
        let projectText = project.map { "「\($0)」" } ?? "Codex"
        return CodexNotificationContent(
            kind: "longTask",
            title: "Codex 任务完成",
            body: "\(projectText) 任务完成, \(CodexActivityDisplayFormat.elapsedDurationFragment(for: duration))"
        )
    }

    static func taskWaiting(project: String?, toolName: String?) -> CodexNotificationContent {
        let subject = project.map { "「\($0)」" } ?? "Codex"
        let action = toolName.map { "\($0) 操作" } ?? "下一步操作"
        return CodexNotificationContent(
            kind: "taskWaiting",
            title: "Codex 等待批准",
            body: "\(subject) 正在等待批准 \(action)"
        )
    }

    static func creditExpiry(count: Int, expirationDate: Date) -> CodexNotificationContent {
        CodexNotificationContent(
            kind: "creditExpiry",
            title: "重置即将过期",
            body: "有 \(count) 个重置次数将于 \(CodexDateFormat.localDisplayString(from: expirationDate)) 过期"
        )
    }

    static func lowBattery(percent: Int) -> CodexNotificationContent {
        CodexNotificationContent(
            kind: "lowBattery",
            title: "已恢复系统休眠",
            body: "电量剩余 \(percent)%, 已停止防休眠"
        )
    }

    static func keepAliveLimit(durationText: String) -> CodexNotificationContent {
        CodexNotificationContent(
            kind: "keepAliveLimit",
            title: "已恢复系统休眠",
            body: "已达防休眠上限 \(durationText), 已停止防休眠"
        )
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension CodexNotificationService: UNUserNotificationCenterDelegate {
    /// 菜单栏常驻应用处于前台时也要展示横幅并播放声音
    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent _: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
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
