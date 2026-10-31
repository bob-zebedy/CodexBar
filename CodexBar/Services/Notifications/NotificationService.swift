import AppKit
import Combine
import Foundation
import os
import UserNotifications

nonisolated enum AutoResetFailureNotice: String, Sendable {
    case expired
    case authentication
    case permanent
}

/// 订阅额度与实时活动, 统一处理提醒条件, 去重, 触觉反馈与本地通知发送
@MainActor
final class NotificationService: NSObject {
    struct Delivery {
        var setDelegate: (any UNUserNotificationCenterDelegate) -> Void = {
            UNUserNotificationCenter.current().delegate = $0
        }

        var add: (UNNotificationRequest) async throws -> Void = {
            try await UNUserNotificationCenter.current().add($0)
        }

        var remove: ([String]) -> Void = {
            let center = UNUserNotificationCenter.current()
            center.removeDeliveredNotifications(withIdentifiers: $0)
            center.removePendingNotificationRequests(withIdentifiers: $0)
        }
    }

    private let settings: NotificationSettings
    private let statusViewModel: CodexStatusViewModel
    private let activityMonitor: ActivityMonitor
    private let defaults: UserDefaults
    private let delivery: Delivery
    private nonisolated let openMenuSurface: @MainActor @Sendable () -> Void

    private var cancellables = Set<AnyCancellable>()
    private var taskHapticFeedbackTask: Task<Void, Never>?
    private var taskWaitingNotificationIdentifiers = Set<String>()
    private let creditExpiryReminderScheduler = ReminderCheckScheduler()
    private var latestQuotaSnapshot: CodexQuotaSnapshot?

    /// 已发送去重键的内存镜像, 变更时才写回 UserDefaults
    private var sentDedupKeys: [String]
    private var submittingDedupKeys = Set<String>()

    /// 低额度判定依据的两个设置项
    /// @Published 在 willSet 中回调, settings 属性尚未更新, 需使用调用方传入的回调参数
    private struct LowQuotaConditions {
        let isEnabled: Bool
        let thresholdPercent: Int
    }

    /// 额度刷新期间设置不变, 可以直接读取当前值
    private var currentLowQuotaConditions: LowQuotaConditions {
        LowQuotaConditions(
            isEnabled: settings.isLowQuotaEnabled,
            thresholdPercent: settings.lowQuotaThresholdPercent
        )
    }

    /// 可信快照中每个额度窗口的观察状态; 窗口消失后重现会获得新的生命周期标记
    private var quotaWindowObservations: [String: QuotaWindowObservation] = [:]

    init(
        settings: NotificationSettings,
        statusViewModel: CodexStatusViewModel,
        activityMonitor: ActivityMonitor,
        defaults: UserDefaults = .standard,
        delivery: Delivery = Delivery(),
        openMenuSurface: @escaping @MainActor @Sendable () -> Void
    ) {
        self.settings = settings
        self.statusViewModel = statusViewModel
        self.activityMonitor = activityMonitor
        self.defaults = defaults
        self.delivery = delivery
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
        delivery.setDelegate(self)
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

        // 睡眠可能错过重置次数的临期检查, 唤醒时补检
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

    // MARK: - 任务提醒

    @discardableResult
    func handleActivityTransition(_ transition: ActivityTransition) -> Task<Bool, Never>? {
        performTaskHapticFeedbackIfEnabled()

        guard settings.canDeliver else {
            return nil
        }

        switch transition {
        case let .waiting(task, _):
            guard settings.isTaskWaitingEnabled else {
                return nil
            }
            let taskID = task.id
            let identifier = Self.taskWaitingNotificationIdentifier(for: taskID)
            taskWaitingNotificationIdentifiers.insert(identifier)
            return send(
                .taskWaiting(project: task.projectName, actionText: task.approvalActionText),
                sound: settings.taskWaitingSound,
                identifier: identifier,
                isStillRelevant: { [weak self] in
                    self?.activityMonitor.snapshot.blockingWaitingTaskIDs.contains(taskID) ?? false
                },
                onSubmissionFailure: { [weak self] in
                    self?.taskWaitingNotificationIdentifiers.remove(identifier)
                }
            )
        case let .completed(completion):
            guard settings.isTaskCompletionEnabled,
                  let duration = completion.duration,
                  duration >= TimeInterval(settings.taskCompletionMinimumDurationSeconds) else {
                return nil
            }
            return send(
                .taskCompleted(project: completion.projectName, duration: duration),
                sound: settings.taskCompletionSound
            )
        }
    }

    private func reconcileTaskWaitingNotifications(with snapshot: ActivitySnapshot) {
        let activeIdentifiers = Set(snapshot.blockingWaitingTaskIDs.map {
            Self.taskWaitingNotificationIdentifier(for: $0)
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

    // MARK: - 异常任务保护

    func notifyProtection(_ notice: ProtectionNotice) async -> Bool {
        guard settings.canDeliver else {
            return false
        }

        let identifier = Self.protectionNotificationIdentifier(
            taskID: notice.taskID,
            attemptID: notice.attemptID
        )
        let deliveryTask = send(
            .protection(
                project: notice.projectName,
                inactivityDurationText: notice.inactivityDurationText
            ),
            sound: .systemDefault,
            identifier: identifier,
            isStillRelevant: { [weak self] in
                self?.activityMonitor.isProtectionNoticeRelevant(
                    taskID: notice.taskID,
                    attemptID: notice.attemptID
                ) ?? false
            },
            retryCount: 0
        )
        return await deliveryTask?.value ?? false
    }

    func invalidateProtectionNotification(taskID: UUID, attemptID: UUID) {
        let identifier = Self.protectionNotificationIdentifier(
            taskID: taskID,
            attemptID: attemptID
        )
        removeNotifications(withIdentifiers: [identifier])
    }

    // MARK: - 快照处理

    private func handleSnapshot(_ snapshot: CodexQuotaSnapshot?) {
        guard let snapshot else {
            latestQuotaSnapshot = nil
            quotaWindowObservations.removeAll()
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
            if quotaWindowObservations[stateKey] == nil {
                quotaWindowObservations[stateKey] = QuotaWindowObservation()
            }
            processQuotaWindow(window, limit: limit, stateKey: stateKey, lowQuota: lowQuota)
        }
        quotaWindowObservations = quotaWindowObservations.filter {
            observedWindowKeys.contains($0.key)
        }
    }

    /// 枚举可信快照中有数据的额度窗口, 在此统一定义窗口过滤和 stateKey 生成规则
    private func forEachQuotaWindowWithData(
        in snapshot: CodexQuotaSnapshot,
        _ body: (QuotaWindow, CodexQuotaLimitSnapshot, String) -> Void
    ) {
        let accountKey = Self.accountKey(for: snapshot)
        for limit in snapshot.limits {
            for window in limit.windows where window.hasData {
                let stateKey = Self.quotaWindowStateKey(
                    accountKey: accountKey,
                    limitID: limit.limitID,
                    windowID: window.id
                )
                body(window, limit, stateKey)
            }
        }
    }

    /// 设置刚变就按新值重判一次, 不必等下一个刷新周期
    /// 清除上次观察后使用新阈值判定, 使当前额度达到新阈值时立即触发提醒
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
            quotaWindowObservations[stateKey]?.lowQuota = LowQuotaObservation()
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

        let crossedThreshold = quotaWindowObservations[stateKey]?.lowQuota.observe(
            remainingPercent: window.remainingPercent,
            resetsAt: window.resetsAt,
            thresholdPercent: lowQuota.thresholdPercent
        )

        guard let resetsAt = window.resetsAt,
              crossedThreshold == true,
              lowQuota.isEnabled else {
            return
        }

        // 记录用户设置的阈值以说明通知原因, 不记录用量数据
        let threshold = lowQuota.thresholdPercent
        let details = LogFields.joined(
            "kind=lowQuota",
            "threshold=\(threshold)",
            "direction=down"
        )
        AppLog.notification.notice("阈值已穿越: \(details, privacy: .public)")

        let dedupKey = lowQuotaDedupKey(stateKey: stateKey, resetsAt: resetsAt)
        let lifecycleToken = quotaWindowObservations[stateKey]?.lifecycleToken
        send(
            .lowQuota(
                limitTitle: limit.title,
                windowLabel: window.label,
                thresholdPercent: lowQuota.thresholdPercent
            ),
            sound: settings.lowQuotaSound,
            dedupKey: dedupKey,
            onSubmissionFailure: { [weak self] in
                guard let self, quotaWindowObservations[stateKey]?.lifecycleToken == lifecycleToken else { return }
                quotaWindowObservations[stateKey]?.lowQuota = LowQuotaObservation()
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
            quotaWindowObservations[stateKey]?.hasObservedConsumption = true
        } else if usedPercent == 0,
                  quotaWindowObservations[stateKey]?.hasObservedConsumption == true {
            // 归零即消费待重置状态; 开关或授权此刻不可用时不保留补发
            quotaWindowObservations[stateKey]?.hasObservedConsumption = false
            guard settings.canDeliver,
                  settings.isQuotaResetEnabled,
                  let lifecycleToken = quotaWindowObservations[stateKey]?.lifecycleToken else {
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
                          quotaWindowObservations[stateKey]?.lifecycleToken == lifecycleToken else {
                        return
                    }

                    quotaWindowObservations[stateKey]?.hasObservedConsumption = true
                }
            )
        }
    }

    // MARK: - 自动重置

    func notifyAutoResetSucceeded(
        remainingCount: Int?,
        dedupToken: String
    ) {
        guard settings.canDeliver, settings.isAutoResetEnabled else {
            return
        }

        send(
            .autoResetSucceeded(remainingCount: remainingCount),
            sound: settings.autoResetSound,
            dedupKey: "autoResetSucceeded|\(dedupToken)"
        )
    }

    func notifyAutoResetFailed(
        reason: AutoResetFailureNotice,
        dedupToken: String
    ) {
        guard settings.canDeliver, settings.isAutoResetEnabled else {
            return
        }

        send(
            .autoResetFailed(reason: reason),
            sound: settings.autoResetSound,
            dedupKey: "autoResetFailed|\(dedupToken)|\(reason.rawValue)"
        )
    }

    // MARK: - 低电量保护

    /// 由 KeepAliveController 在低电量导致睡眠恢复成功之后调用, 恢复失败不会走到这里
    /// 调用方保证同一轮低电量只发一次, 电量回到解除门槛以上才开始下一轮, 此处无需再次去重
    /// 调用方在提交完成前保留空闲断言, 避免系统先进入空闲睡眠
    /// 返回提交结果, 调用方仅在成功时标记本轮已通知
    func notifyLowBatteryProtection(percent: Int) async -> Bool {
        guard settings.canDeliver, settings.isLowBatteryEnabled else {
            return false
        }

        return await send(
            .lowBattery(percent: percent),
            sound: settings.lowBatterySound
        )?.value ?? false
    }

    // MARK: - 防睡眠时长上限

    /// 由 KeepAliveController 在达到时长上限且睡眠恢复成功之后调用
    /// 调用方在提交完成前保留空闲断言, 与低电量通知一致
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
        guard !snapshot.isRateLimitsStale,
              settings.isCreditExpiryEnabled,
              let dates = snapshot.resetCreditExpirationDates else {
            scheduleNextCreditExpiryCheck(dates: [])
            return
        }

        let accountKey = Self.accountKey(for: snapshot)
        let now = Date()
        let dueDates = dates.filter {
            Self.creditExpiryReminderDay(expirationDate: $0, now: now) != nil
        }

        // 将过期时间相同的机会合并成一条通知, 分组和去重键均精确到秒
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

    /// app-server 的重置时间可能在连接重建后出现秒级漂移, 误差不超过容差时复用旧 key
    private func lowQuotaDedupKey(stateKey: String, resetsAt: Date) -> String {
        let prefix = "low|\(stateKey)|"
        let resetEpoch = Self.epoch(resetsAt)
        let matchesReset: (String) -> Bool = { key in
            guard key.hasPrefix(prefix),
                  let existingEpoch = Int(key.dropFirst(prefix.count)) else {
                return false
            }

            return LowQuotaObservation.matchesReset(existingEpoch, resetEpoch)
        }

        if let existingKey = sentDedupKeys.first(where: matchesReset) {
            return existingKey
        }
        if let existingKey = submittingDedupKeys.first(where: matchesReset) {
            return existingKey
        }

        return "\(prefix)\(resetEpoch)"
    }

    private func rememberSentDedupKey(_ key: String) {
        sentDedupKeys.append(key)
        if sentDedupKeys.count > Self.sentKeysLimit {
            sentDedupKeys.removeFirst(sentDedupKeys.count - Self.sentKeysLimit)
        }

        defaults.set(sentDedupKeys, forKey: Self.sentKeysKey)
    }

    // MARK: - 发送与文案

    /// 统一提交通知, 处理去重, 时效判定和失败回调
    /// 去重在创建异步任务前完成, 避免连续调用重复提交
    ///
    /// 日志只记录 kind, 不记录包含项目名和任务信息的 title 与 body
    ///
    /// - Returns: 提交任务, 调用方可 await 其 value 获取提交结果
    @discardableResult
    private func send(
        _ notification: NotificationContent,
        sound: NotificationSoundOption,
        identifier: String = UUID().uuidString,
        dedupKey: String? = nil,
        isStillRelevant: (() -> Bool)? = nil,
        onSubmissionFailure: (() -> Void)? = nil,
        retryCount: Int = NotificationService.notificationSubmissionRetryCount
    ) -> Task<Bool, Never>? {
        let kind = notification.kind
        if let dedupKey {
            guard !sentDedupKeys.contains(dedupKey),
                  submittingDedupKeys.insert(dedupKey).inserted else {
                let details = LogFields.joined(
                    "kind=\(kind)",
                    "reason=duplicate"
                )
                AppLog.notification.notice("通知已跳过: \(details, privacy: .public)")
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
                onSubmissionFailure: onSubmissionFailure,
                retryCount: retryCount
            ) ?? false
        }
    }

    /// 返回通知是否提交成功, 调用方据此标记已通知
    private func deliver(
        _ request: UNNotificationRequest,
        kind: String,
        dedupKey: String?,
        isStillRelevant: (() -> Bool)?,
        onSubmissionFailure: (() -> Void)?,
        retryCount: Int
    ) async -> Bool {
        defer {
            if let dedupKey {
                submittingDedupKeys.remove(dedupKey)
            }
        }

        for _ in 0 ... max(0, retryCount) {
            guard isStillRelevant?() != false else {
                let details = LogFields.joined(
                    "kind=\(kind)",
                    "reason=obsolete"
                )
                AppLog.notification.notice("通知已跳过: \(details, privacy: .public)")
                return false
            }
            do {
                try await delivery.add(request)
                guard isStillRelevant?() != false else {
                    // 投递后任务状态又变了, 撤回避免用户看到过期提醒
                    let details = LogFields.joined(
                        "kind=\(kind)",
                        "reason=obsolete"
                    )
                    AppLog.notification.notice("通知已撤回: \(details, privacy: .public)")
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

        // 重试耗尽后才记录失败日志, 单次失败继续重试
        let details = LogFields.joined(
            "kind=\(kind)",
            "reason=retryExhausted"
        )
        AppLog.notification.error("通知发送失败: \(details, privacy: .public)")
        onSubmissionFailure?()
        return false
    }

    private func removeNotifications(withIdentifiers identifiers: [String]) {
        delivery.remove(identifiers)
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

    private nonisolated static func protectionNotificationIdentifier(
        taskID: UUID,
        attemptID: UUID
    ) -> String {
        "protection|\(taskID.uuidString)|\(attemptID.uuidString)"
    }

    private nonisolated static func quotaWindowStateKey(
        accountKey: String,
        limitID: String,
        windowID: String
    ) -> String {
        "\(accountKey)|\(limitID)|\(windowID)"
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

    struct LowQuotaObservation {
        private var remainingPercent: Int?
        private var resetEpoch: Int?

        mutating func observe(remainingPercent: Int, resetsAt: Date?, thresholdPercent: Int) -> Bool {
            let newResetEpoch = resetsAt.map { Int($0.timeIntervalSince1970) }
            let isSameCycle = resetEpoch.flatMap { previous in
                newResetEpoch.map { Self.matchesReset(previous, $0) }
            } ?? false
            let previousRemainingPercent = isSameCycle ? self.remainingPercent : nil
            // 周期比较和持久化去重都以固定时间为锚点
            if !isSameCycle {
                resetEpoch = newResetEpoch
            }
            self.remainingPercent = remainingPercent
            return newResetEpoch != nil && remainingPercent <= thresholdPercent
                && (previousRemainingPercent.map { $0 > thresholdPercent } ?? true)
        }

        static func matchesReset(_ lhs: Int, _ rhs: Int) -> Bool {
            abs(TimeInterval(lhs) - TimeInterval(rhs)) <= 60
        }
    }

    private struct QuotaWindowObservation {
        /// 窗口生命周期标记, 迟到的发送失败回调据此丢弃
        let lifecycleToken = UUID()
        var lowQuota = LowQuotaObservation()
        var hasObservedConsumption = false
    }
}

extension NotificationService: UNUserNotificationCenterDelegate {
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
