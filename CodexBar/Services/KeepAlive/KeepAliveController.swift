import AppKit
import Combine
import Foundation
import IOKit
import os
import ServiceManagement

@MainActor
final class KeepAliveController: ObservableObject {
    @Published private(set) var isEnabled: Bool
    @Published private(set) var helperStatus = HelperStatus.notRegistered
    @Published private(set) var isPreventingSleep = false
    @Published private(set) var sleepPreventionSource = CodexBarSleepPreventionSource.none
    @Published private(set) var lowBatteryThreshold: LowBatteryThreshold
    /// 等待批准的任务算不算"有任务", 决定审批期间要不要继续挡住睡眠
    @Published private(set) var keepsAwakeWhileWaiting: Bool
    /// 防睡眠生效期间是否连屏幕一起留住, 顺带压住屏保与闲置锁屏
    @Published private(set) var keepsDisplayAwake: Bool
    /// 确认没有内置电池时为 false, 设置页据此隐藏低电量那一行
    @Published private(set) var hasBattery = true
    /// 当前是否因低电量而停止防睡眠, 带滞回所以不等于"电量低于阈值"
    /// 会随电量自己翻转, 不需要外部清除, 与 hasReachedMaximumDuration 那种粘滞标志不是一回事
    @Published private(set) var isLowBatteryActive = false
    /// 低电量保护是不是真的在起作用: 防睡眠本身可用, 阈值开着, 且这台机器确实有电池
    /// 规则收在这里而不是各视图各写一遍: 通知面板要据此置灰那一行, 防睡眠面板据此决定显不显示阈值
    @Published private(set) var isLowBatteryProtectionEnabled = false
    /// 时长上限是不是真的会到点: 防睡眠本身可用, 且没选无限制
    /// 与 isLowBatteryProtectionEnabled 同一个用法, 视图只读结论, 不各自再判一次 unlimited
    /// 只在跨越边界时发信号, 1 小时改 2 小时不必让通知面板白排一轮高度重算
    @Published private(set) var isMaximumDurationEnabled = false

    /// 低电量是不是当下唯一拦住防睡眠的那一项
    /// 由 reconcileSleepState 从 sleepBlockReason 派生, 见那里的说明
    @Published private(set) var isLowBatteryBlocking = false
    /// 子面板入口该不该出现: 用户开关开着且依赖已就绪
    /// 同样从 sleepBlockReason 派生, 于是新增阻断条件时必然要在那个 switch 里表态, 不会漏配
    @Published private(set) var canShowOptions = false
    /// 只供自动重置设置行展示, 不与防睡眠操作错误混在一起
    @Published private(set) var autoResetWakeScheduleErrorMessage: String?

    /// helper 安装与注册状态的错误, 注册恢复正常时才清除
    @Published private var registrationErrorMessage: String?
    /// 切换睡眠状态过程中的错误, 由下一次操作结果 用户动作或明确的依赖失效覆盖
    /// 与注册类错误分开存储: refreshHelperStatus 每次 App 激活都会跑, 不能抹掉操作结果
    @Published private var operationErrorMessage: String?

    /// 注册不成功时操作类错误只是下游噪音, 优先展示注册问题
    var errorMessage: String? {
        (isEnabled ? registrationErrorMessage : nil) ?? operationErrorMessage
    }

    var helperRegistrationErrorMessage: String? {
        registrationErrorMessage
    }

    /// 时长上限的状态转发给 UI, 使调用方不必知道 limiter 的存在
    var maximumDuration: MaximumDuration {
        durationLimiter.duration
    }

    var hasReachedMaximumDuration: Bool {
        durationLimiter.hasReached
    }

    /// 低电量导致睡眠恢复之后回调一次, 参数是触及阈值时的电量; 由 AppDelegate 接到通知服务
    /// 用事件回调而不是 @Published: 触发是一次性动作, 电量回升到解除门槛以上后再次跌破要能重新发一次
    /// async 是为了让补发睡眠等到通知真的提交完: 同步回调只把提交排进下一个 MainActor job,
    /// 而 IOPMSleepSystem 就在当前这个 job 里, 机器会先睡下去
    /// 返回值是通知有没有真的发出去, 决定这一轮算不算已通知
    var onLowBatteryTriggered: ((Int) async -> Bool)?

    /// 达到防睡眠时长上限且睡眠恢复成功之后回调一次
    /// 时长上限本身是粘滞状态, 每个计时周期天然只会进入一次
    var onKeepAliveLimitTriggered: ((MaximumDuration) async -> Bool)?

    /// 用户开关仍开着, 且 helper 已经真的把睡眠关掉
    /// isPreventingSleep 在稳态下已隐含 isEnabled (shouldDisableSleep 要求它)
    /// 叠这一层是为了关开关到 helper 回调之间的异步空窗: 用户意图先落地
    var isActivelyPreventingSleep: Bool {
        isEnabled && isPreventingSleep
    }

    private let activityMonitor: CodexActivityMonitor
    private let codexHookSettings: CodexHookSettings
    private let defaults: UserDefaults
    private let systemSleepService = SystemSleepService()
    private let powerSourceMonitor = PowerSourceMonitor()
    private let durationLimiter: KeepAliveDurationLimiter
    /// 不加 @Published: 设置页在根上观察整个控制器, 任务每起停一次都会重算整页 body
    /// 需要跟着它刷新的只有派生出去的 isLowBatteryBlocking 与 canShowOptions
    private var hasRunningTasks = false
    /// 保留仍活跃且已经进入过运行态的任务, 避免普通快照刷新被误判成新任务
    private var startedRunningTaskIDs = Set<UUID>()
    /// 最近一份快照中的等待任务, 用于识别等待批准后恢复运行的状态转换
    /// 开着 keepsAwakeWhileWaiting 时它同时是"有没有任务撑着防睡眠"的另一半输入
    private var waitingTaskIDs = Set<UUID>()
    /// 同一 App 进程内跨 XPC 重连保持不变, helper 据此把连接变化与租约所有权分开
    private let helperClientSessionID = UUID().uuidString
    private var connection: NSXPCConnection?
    private var appliedSleepPreventionRequested: Bool?
    /// true 请求可能已被 helper 接收却丢了回复, 只有一次成功的 false 才能清除这个可能性
    private var mayHaveHelperLease = false
    private var requestInFlight = false
    private var requestGeneration: UInt64 = 0
    private var pendingRequestCompletion: ((Bool) -> Void)?
    private var retryTask: Task<Void, Never>?
    private var requestTimeoutTask: Task<Void, Never>?
    private let helperRuntimeStatusMonitor = HelperRuntimeStatusMonitor()
    private var retryAttempt = 0
    private var helperRegistrationTask: Task<Void, Never>?
    /// 与 hasRunningTasks 同理: 只经由派生状态影响 UI, 自己不发信号
    private var isRefreshingHelper = false
    private var isAutoResetRequested = false
    private let autoResetWakeScheduler = AutoResetWakeScheduler()
    /// 已排队但还没发出的低电量通知, 值是触及阈值时的电量
    /// 恢复睡眠真的成功才发得出去: 恢复失败时机器仍不会睡, 那时说已恢复会把用户骗去合盖
    private var pendingLowBatteryPercent: Int?
    /// 本轮低电量已经通知过
    /// 只看是否接电不足以收口: 适配器接触不良时供电状态会反复翻转, 每翻一次都会重发一条
    /// 由电量回到解除门槛以上清除, 也就是电量真的回来了才算下一轮
    private var hasNotifiedLowBattery = false
    /// 达到时长上限后等待睡眠恢复成功再发送, 恢复失败时保留给重试路径
    private var pendingKeepAliveLimit: MaximumDuration?
    private var cancellables = Set<AnyCancellable>()
    private var isStarted = false
    private var isPreparingForTermination = false
    private var lastLoggedSleepConditions: SleepConditions?
    /// codexHookSettings.isOperable 的最新值, 由订阅维护
    /// 不直接读那个属性: 订阅回调跑在 willSet, 那时它还是改动前的值
    private var isHookEnabled: Bool

    // MARK: - 生命周期

    init(
        activityMonitor: CodexActivityMonitor,
        codexHookSettings: CodexHookSettings,
        defaults: UserDefaults = .standard
    ) {
        self.activityMonitor = activityMonitor
        self.codexHookSettings = codexHookSettings
        self.defaults = defaults
        durationLimiter = KeepAliveDurationLimiter(defaults: defaults)
        isHookEnabled = codexHookSettings.isOperable
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        // 默认关闭: 老版本升上来的用户不该多出一条中断任务的路径
        lowBatteryThreshold = (defaults.object(forKey: Self.lowBatteryThresholdKey) as? Int)
            .flatMap(LowBatteryThreshold.init(rawValue:)) ?? .off
        // 同样默认关闭: 等待批准没有终点, 开着它意味着无人值守时机器可能整夜不睡
        keepsAwakeWhileWaiting = defaults.bool(forKey: Self.keepsAwakeWhileWaitingKey)
        // 默认关闭: 它会让人离开后机器一直停在解锁状态, 这个取舍只能由用户自己做
        keepsDisplayAwake = defaults.bool(forKey: Self.keepsDisplayAwakeKey)
        activityMonitor.setActivityProtectionEnabled(isEnabled)
        autoResetWakeScheduler.onErrorMessageChanged = { [weak self] message in
            self?.autoResetWakeScheduleErrorMessage = message
        }
    }

    func start() {
        guard !isStarted else {
            return
        }
        isStarted = true

        // Hook 是本功能的依赖, 不是用户意图
        // 只重新求值当前该不该防止系统睡眠, 绝不改写用户保存的开关
        // 看 isOperable 那两个输入而不是只看 isEnabled: Codex 那边全局关掉 hooks
        // 或者不信任我们的 handler 时事件送不过来, 任务恒为空, 防睡眠也就不该显示成可用
        // @Published 在 willSet 就发信号, 此刻回读 codexHookSettings.isOperable 会拿到
        // 正在变的那一项的旧值; CombineLatest 的两个参数都是各自的新值, 所以只认闭包参数
        Publishers.CombineLatest(codexHookSettings.$isEnabled, codexHookSettings.$isVerified)
            .map { $0 && $1 }
            .removeDuplicates()
            .sink { [weak self] isOperable in
                self?.isHookEnabled = isOperable
                self?.reconcileSleepState(trigger: .hookChanged)
            }
            .store(in: &cancellables)

        activityMonitor.$snapshot
            .sink { [weak self] snapshot in
                self?.handleActivitySnapshot(snapshot)
            }
            .store(in: &cancellables)

        powerSourceMonitor.start { [weak self] in
            self?.handlePowerSourceChange()
        }
        updateBatteryState()

        durationLimiter.start()
        durationLimiter.onStateChanged = { [weak self] trigger in
            self?.reconcileSleepState(trigger: trigger)
        }
        // duration 与 hasReached 由计算属性转发, 变化要接力发出去才能刷新 UI
        durationLimiter.objectWillChange
            .sink { [weak self] in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)

        refreshRegistrationAndSleepState()
    }

    func stop() {
        guard isStarted else {
            return
        }
        isStarted = false
        cancellables.removeAll()
        cancelRetryTask()
        cancelHelperRegistrationTask()
        autoResetWakeScheduler.stop()
        cancelExternalObservation()
        startedRunningTaskIDs.removeAll()
        waitingTaskIDs.removeAll()
        durationLimiter.stop()
        powerSourceMonitor.stop()
        assign(false, to: \.isLowBatteryActive)
        clearPendingLowBatteryNotification()
        pendingKeepAliveLimit = nil

        invalidateConnection()
    }

    /// App 退出时先等 root 侧取消唤醒计划并把已取得的睡眠所有权恢复为 0
    /// 如果本轮没有对应所有权, 两条清理请求都会收敛成无操作成功
    func prepareForTermination() async -> Bool {
        guard isStarted else {
            return true
        }
        guard !isPreparingForTermination else {
            return false
        }

        isPreparingForTermination = true
        cancelRetryTask()
        cancelHelperRegistrationTask()
        cancelExternalObservation()
        let wakeScheduleReleased = await autoResetWakeScheduler.prepareForTermination(
            helperSupportsWakeScheduling: isHelperReadyForAutoResetWake
        )
        let sleepLeaseReleased = await releaseHelperLeaseIfNeeded(trigger: .termination)
        let success = wakeScheduleReleased && sleepLeaseReleased
        guard !success else {
            return true
        }

        // 退出被取消时恢复正常状态, 不能让一次失败把运行中的任务永久放开
        autoResetWakeScheduler.resumeAfterTerminationCancellation()
        isPreparingForTermination = false
        reconcileSleepState(trigger: .termination, force: true)
        return false
    }

    func refresh() {
        // 电源监听注册失败并降级成轮询时, 这是唯一还会即时重读电量的路径
        powerSourceMonitor.refresh()
        refreshRegistrationAndSleepState()
    }

    private func refreshRegistrationAndSleepState() {
        guard helperRegistrationTask == nil else {
            reconcileSleepState(trigger: .statusRefresh)
            return
        }

        refreshHelperStatus()
        if isEnabled
            || isAutoResetRequested
            || helperStatus.isRegisteredOrAwaitingApproval {
            ensureHelperRegistration()
        }
        reconcileSleepState(trigger: .statusRefresh)
        reconcileAutoResetWakeSchedule()
    }

    // MARK: - 设置入口

    func setEnabled(_ enabled: Bool) {
        // 与 sleepBlockReason 读同一份镜像, 类内只保留一个 Hook 状态的真相来源
        guard !enabled || isHookEnabled else {
            return
        }
        guard enabled != isEnabled else {
            return
        }

        AppLog.keepAlive.notice("KeepAlive 开关变更: enabled=\(enabled ? 1 : 0)")
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        activityMonitor.setActivityProtectionEnabled(enabled)
        registrationErrorMessage = nil
        operationErrorMessage = nil

        if enabled {
            ensureHelperRegistration()
        } else {
            durationLimiter.reset()
        }
        reconcileSleepState(trigger: .settings)
    }

    func setMaximumDuration(_ duration: MaximumDuration) {
        durationLimiter.setDuration(duration)
        // limiter 只在这一轮累计过时才回调, 所以派生值不能等 reconcileSleepState 来带
        publishNotificationDependencies()
    }

    /// 只改"哪些任务算数", 不参与拦截判定
    /// 所以它不进 sleepBlockReason: 关着它时审批中的任务报的仍然是 noTasks, 与没有任务同一回事
    func setKeepsAwakeWhileWaiting(_ enabled: Bool) {
        guard enabled != keepsAwakeWhileWaiting else {
            return
        }

        AppLog.keepAlive.notice("KeepAlive 等待批准时保持防睡眠变更: enabled=\(enabled ? 1 : 0)")
        keepsAwakeWhileWaiting = enabled
        defaults.set(enabled, forKey: Self.keepsAwakeWhileWaitingKey)
        // 快照不会因为改设置重发一次, 正等着批准的那些任务只能在这里重新求值
        reconcileSleepState(trigger: .settings)
    }

    /// 与防睡眠的实际效果绑在一起: 只在真的挡住睡眠时留住屏幕, 低电量或达到上限解除时一并放开
    func setKeepsDisplayAwake(_ enabled: Bool) {
        guard enabled != keepsDisplayAwake else {
            return
        }

        AppLog.keepAlive.notice("KeepAlive 保持屏幕常亮变更: enabled=\(enabled ? 1 : 0)")
        keepsDisplayAwake = enabled
        defaults.set(enabled, forKey: Self.keepsDisplayAwakeKey)
        reconcileDisplayAwake()
    }

    func setLowBatteryThreshold(_ threshold: LowBatteryThreshold) {
        guard threshold != lowBatteryThreshold else {
            return
        }

        AppLog.keepAlive.notice(
            "KeepAlive 低电量阈值变更: threshold=\(threshold.rawValue)"
        )
        lowBatteryThreshold = threshold
        defaults.set(threshold.rawValue, forKey: Self.lowBatteryThresholdKey)
        // 换了阈值就是新的一轮: 旧阈值下打的锁存对新阈值不成立
        // 留着它会让提高阈值后第一次真正触发的低电量不提醒
        clearPendingLowBatteryNotification()
        updateBatteryState()
        reconcileSleepState(trigger: .settings)
    }

    // MARK: - 电量与任务变化

    private func handlePowerSourceChange() {
        let wasBatteryLow = isLowBatteryActive
        updateBatteryState()
        guard isLowBatteryActive != wasBatteryLow else {
            return
        }

        reconcileSleepState(trigger: .battery)
    }

    /// 纯条件判定: 只看当下, 不记"低过电"这笔账, 所以充上电会自动恢复
    /// 滞回让解除门槛比触发门槛高一截, 否则电量在阈值附近抖动会反复切换睡眠状态
    /// 读不到电量时维持上一次的判定, 两种情形各有各的理由
    /// 从没读到过时保持不触发: 误触发会当场断掉用户任务, 漏触发最坏也有系统强制睡眠兜底
    /// 已经在保护中时不清零: 一次瞬时失败不该让防睡眠反复开关, 那还会绕过滞回并重发通知
    private func updateBatteryState() {
        let reading = powerSourceMonitor.reading
        // 读失败时维持上一次的判定, 与下面 isLowBatteryActive 同一条规则
        // unreadable.hasBattery 是 true (从没读到过时按"可能有"处理), 无条件赋值会让一次
        // IOKit 缺口把已确认没有电池的台式机翻回有电池, 低电量那一行跟着闪进闪出
        if reading != .unreadable {
            assign(reading.hasBattery, to: \.hasBattery)
        }
        // 阈值与 hasBattery 都只在这条路径上变, 派生值跟着一起收在这里
        // 走这里而不是等 reconcileSleepState: handlePowerSourceChange 在低电量结论没变时就返回了,
        // 而 hasBattery 可能在同一次读数里刚变过
        publishNotificationDependencies()

        // 保护关掉了就没有可维持的状态, 这一条要排在读数判断之前
        guard let threshold = lowBatteryThreshold.percent else {
            assign(false, to: \.isLowBatteryActive)
            clearPendingLowBatteryNotification()
            return
        }

        // 读失败与确认没有电池必须分开: 后者该清零, 前者维持现状
        guard reading != .unreadable else {
            return
        }

        guard let status = reading.status else {
            assign(false, to: \.isLowBatteryActive)
            clearPendingLowBatteryNotification()
            return
        }

        // 这一轮结束的标志是电量真的回来了, 不是接上了电源
        // 排在供电状态之前: 充电期间也要能收口, 否则下一次拔线还算同一轮
        if status.percent >= threshold + Self.lowBatteryHysteresis {
            clearPendingLowBatteryNotification()
        }

        guard status.isOnBattery else {
            assign(false, to: \.isLowBatteryActive)
            return
        }

        let wasBatteryLow = isLowBatteryActive
        let isLow = wasBatteryLow
            ? status.percent < threshold + Self.lowBatteryHysteresis
            : status.percent <= threshold
        assign(isLow, to: \.isLowBatteryActive)
        guard isLow, !wasBatteryLow else {
            return
        }

        // 百分比只在这里记一次; 放进 SleepConditions 会让每掉 1% 刷一条
        // 本来就没在挡睡眠时这一跌不改变任何事, 但仍要记: 这是排查"为什么在这个电量断的"的唯一依据
        let wasPreventingSleep = isActivelyPreventingSleep
            && sleepPreventionSource == .codexBar
        let details = LogFields.joined(
            "percent=\(status.percent)",
            "threshold=\(threshold)",
            "action=\(wasPreventingSleep ? "release" : "none")"
        )
        AppLog.keepAlive.notice("KeepAlive 电量已触及阈值: \(details, privacy: .public)")

        // 没挡过就不通知: "已恢复系统睡眠"会变成一句空话, 启动时电量本就偏低的机器首当其冲
        guard wasPreventingSleep, !hasNotifiedLowBattery else {
            return
        }

        // 这里只排队不发: 睡眠还没真的恢复, 恢复请求可能失败并耗尽重试
        pendingLowBatteryPercent = status.percent
    }

    /// 排队的低电量通知在睡眠真的恢复之后才发
    /// 途中接上电源时拦下防睡眠的已经不是低电量, 那条通知随即作废
    private func flushPendingLowBatteryNotification() async {
        guard let percent = pendingLowBatteryPercent else {
            return
        }

        pendingLowBatteryPercent = nil
        guard isLowBatteryBlocking else {
            return
        }

        // 锁存要等通知真的发出去才打: 打在入队处或提交前, 都会让没送达的那一条吃掉整轮配额
        // 使这一轮之后真正触发的低电量再也提醒不了
        hasNotifiedLowBattery = await onLowBatteryTriggered?(percent) ?? false
    }

    /// 恢复睡眠成功之后按当下的拦截原因发对应的那一条, 顺带把另一条作废
    /// 作废低电量只写 pendingLowBatteryPercent, 不能改走 clearPendingLowBatteryNotification:
    /// 那个方法会连 hasNotifiedLowBattery 一起清, 而这一轮低电量还没结束 (电量没回到解除门槛),
    /// 清了会让下一次跌破阈值重发第二条, 也就是供电状态反复翻转时每翻一次一条
    private func flushPendingSleepRestoreNotification() async {
        switch sleepBlockReason {
        case .lowBattery:
            pendingKeepAliveLimit = nil
            await flushPendingLowBatteryNotification()
        case .limitReached:
            pendingLowBatteryPercent = nil
            guard let duration = pendingKeepAliveLimit else {
                return
            }

            pendingKeepAliveLimit = nil
            _ = await onKeepAliveLimitTriggered?(duration)
        default:
            pendingLowBatteryPercent = nil
            pendingKeepAliveLimit = nil
        }
    }

    private func clearPendingLowBatteryNotification() {
        pendingLowBatteryPercent = nil
        hasNotifiedLowBattery = false
    }

    private func handleActivitySnapshot(_ snapshot: CodexActivitySnapshot) {
        let runningTaskIDs = keepAliveTaskIDs(in: snapshot.runningTasks)
        let currentWaitingTaskIDs = keepAliveTaskIDs(in: snapshot.waitingTasks)
        let activeTaskIDs = runningTaskIDs.union(currentWaitingTaskIDs)

        startedRunningTaskIDs.formIntersection(activeTaskIDs)
        let newRunningTaskIDs = runningTaskIDs.subtracting(startedRunningTaskIDs)
        let resumedRunningTaskIDs = runningTaskIDs
            .intersection(waitingTaskIDs)
            .subtracting(currentWaitingTaskIDs)
        startedRunningTaskIDs.formUnion(runningTaskIDs)
        waitingTaskIDs = currentWaitingTaskIDs

        hasRunningTasks = !runningTaskIDs.isEmpty
        if activeTaskIDs.isEmpty {
            durationLimiter.reset()
        } else if !newRunningTaskIDs.isEmpty || !resumedRunningTaskIDs.isEmpty {
            restartMaximumDurationPeriod()
        }
        reconcileSleepState(trigger: .taskChanged)
    }

    private func keepAliveTaskIDs(in tasks: [CodexActivityTaskSnapshot]) -> Set<UUID> {
        Set(tasks.lazy.filter { !$0.isAnonymous }.map(\.id))
    }

    /// 还没真正挡住睡眠时只清零不起表, 等禁用成功后由 begin 补上
    private func restartMaximumDurationPeriod() {
        guard isEnabled else {
            return
        }

        durationLimiter.restart(isPreventingSleep: isPreventingSleep)
    }

    // MARK: - helper 注册

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func ensureHelperRegistration() {
        guard helperRegistrationTask == nil else {
            return
        }

        let service = KeepAliveHelperConfiguration.service
        refreshHelperStatus()

        switch helperStatus {
        case .enabled, .requiresApproval:
            if KeepAliveHelperConfiguration.registrationNeedsRefresh(defaults: defaults) {
                refreshRegisteredHelper()
            } else if helperStatus == .enabled,
                      let updateIdentifier = KeepAliveHelperConfiguration.pendingUpdateIdentifier(
                          defaults: defaults
                      ) {
                completePendingHelperUpdate(updateIdentifier)
            } else {
                reconcileAutoResetWakeSchedule()
            }
            return
        case .notRegistered, .notFound:
            guard KeepAliveHelperConfiguration.assetsArePresent else {
                registrationErrorMessage = KeepAliveLocalizedMessage.helperAssetsMissing
                return
            }
        }

        AppLog.keepAlive.notice("Helper 注册开始")
        do {
            try service.register()
        } catch {
            refreshHelperStatus()
            if !helperStatus.isRegisteredOrAwaitingApproval {
                AppLog.keepAlive.error(
                    "Helper 注册失败: detail=\(error.localizedDescription, privacy: .public)"
                )
                registrationErrorMessage = KeepAliveLocalizedMessage.registrationFailed
            }
        }

        refreshHelperStatus()
        KeepAliveHelperConfiguration.recordRegistration(defaults: defaults, status: helperStatus)
        if helperStatus == .enabled,
           let updateIdentifier = KeepAliveHelperConfiguration.pendingUpdateIdentifier(
               defaults: defaults
           ) {
            completePendingHelperUpdate(updateIdentifier)
        }
        reconcileAutoResetWakeSchedule()
    }

    private func refreshRegisteredHelper() {
        let requiresSleepReset = helperStatus == .enabled
        guard helperRegistrationTask == nil,
              KeepAliveHelperConfiguration.assetsArePresent else {
            return
        }
        guard autoResetWakeScheduler.beginHelperInterruptionPreparation() else {
            return
        }
        guard let updateIdentifier = KeepAliveHelperConfiguration.beginUpdate(
            defaults: defaults,
            requiresSleepReset: requiresSleepReset
        ) else {
            autoResetWakeScheduler.resumeAfterHelperInterruption()
            return
        }

        assign(true, to: \.isRefreshingHelper)
        cancelRetryTask()
        cancelExternalObservation()
        invalidateConnection()
        // 刷新期间已冻结新接管, 旧 helper 由 unregister 终止
        registrationErrorMessage = nil
        operationErrorMessage = nil

        let service = KeepAliveHelperConfiguration.service
        helperRegistrationTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            defer {
                autoResetWakeScheduler.resumeAfterHelperInterruption()
            }
            let updateResult = await replaceRegisteredHelper(service)

            guard !(updateResult.error is CancellationError),
                  isStarted,
                  !Task.isCancelled else {
                return
            }

            refreshHelperStatus()
            var helperWasUpdated = false
            if updateResult.didUnregisterHelper,
               helperStatus.isRegisteredOrAwaitingApproval {
                KeepAliveHelperConfiguration.recordRegistration(
                    defaults: defaults,
                    status: helperStatus
                )
                if !requiresSleepReset {
                    helperWasUpdated = true
                } else if helperStatus == .enabled {
                    helperWasUpdated = await completeHelperUpdate(updateIdentifier)
                } else {
                    // 从 enabled 更新后若需要系统批准, 一次性重置会在批准后继续
                    helperWasUpdated = true
                }
            }

            if !helperWasUpdated {
                let detail = updateResult.error?.localizedDescription ?? "readinessFailed"
                AppLog.keepAlive.error(
                    "Helper 注册更新失败: detail=\(detail, privacy: .public)"
                )
                registrationErrorMessage = KeepAliveLocalizedMessage.updateFailed
            }

            assign(!helperWasUpdated && helperStatus == .enabled, to: \.isRefreshingHelper)
            helperRegistrationTask = nil
            reconcileSleepState(trigger: .helperRegistered, force: true)
            reconcileAutoResetWakeSchedule()
        }
    }

    private func registerRefreshedHelper(_ service: SMAppService) async throws {
        await Task.yield()

        var retryDelays = KeepAliveHelperConfiguration.registrationRetryDelays.makeIterator()
        while true {
            do {
                try service.register()
                return
            } catch {
                let status = HelperStatus(service.status)
                if status.isRegisteredOrAwaitingApproval {
                    return
                }
                guard KeepAliveHelperConfiguration.isTransientRegistrationError(error),
                      let retryDelay = retryDelays.next() else {
                    throw error
                }
                try await Task.sleep(for: retryDelay)
            }
        }
    }

    /// @Published 在 willSet 无条件发信号, 不比较新旧值
    /// refreshHelperStatus 每次 App 激活跑, releaseSleepPrevention 每条活动快照都会经过
    /// 同值赋值会让菜单面板和设置页反复空转, 所以反复求值路径上的写入都走这里
    /// 用户动作与一次性的操作结果本来就不会重复, 直接赋值即可
    private func assign<Value: Equatable>(
        _ value: Value,
        to keyPath: ReferenceWritableKeyPath<KeepAliveController, Value>
    ) {
        guard self[keyPath: keyPath] != value else {
            return
        }
        self[keyPath: keyPath] = value
    }

    private func refreshHelperStatus() {
        let previousStatus = helperStatus
        assign(HelperStatus(KeepAliveHelperConfiguration.service.status), to: \.helperStatus)
        // 每次 App 激活都会跑, 只记真正的迁移, 否则日志会被无变化的求值淹没
        // 取局部量再插值: Logger 的插值是 autoclosure, 直接写属性会被要求显式 self, 与 --self remove 冲突
        let currentStatus = helperStatus
        if currentStatus != previousStatus {
            let details = LogFields.joined(
                "from=\(String(describing: previousStatus))",
                "to=\(String(describing: currentStatus))"
            )
            AppLog.keepAlive.notice("Helper 注册状态变化: \(details, privacy: .public)")
        }
        if helperStatus == .enabled {
            // 注册已正常, 只撤回注册类抱怨
            // 操作类结果 (例如重试耗尽) 必须留到下一次操作有结论为止
            assign(nil, to: \.registrationErrorMessage)
        } else {
            // 明确失去授权后停止重连, 租约是否已释放仍由原有清理链路确认
            cancelRetryTask()
            invalidateConnection()
            assign(nil, to: \.operationErrorMessage)
            if helperStatus != .requiresApproval {
                durationLimiter.reset()
            }
            publishDerivedState(blockReason: sleepBlockReason)
            reconcileAutoResetWakeSchedule()
        }
    }

    // MARK: - 决策与条件日志

    private func reconcileSleepState(trigger: LogTrigger, force: Bool = false) {
        let blockReason = sleepBlockReason
        let wantsSleepDisabled = blockReason == nil
        updatePendingKeepAliveLimitNotification(for: blockReason)
        publishDerivedState(blockReason: blockReason)
        // 挂在这条所有输入都会经过的路上, 否则关掉防睡眠开关要等 XPC 回复绕回来才放开屏幕
        reconcileDisplayAwake()
        logSleepConditionsIfChanged(blockReason: blockReason, trigger: trigger)

        // Helper 未授权或刷新期间不发普通租约请求, 未确认的租约留待恢复后清理
        guard helperStatus == .enabled, !isRefreshingHelper else {
            cancelRetryTask()
            releaseSleepPrevention()
            return
        }

        guard wantsSleepDisabled else {
            cancelRetryTask()
            if mayHaveHelperLease || isPreventingSleep {
                applySleepPreventionRequested(false)
            } else {
                releaseSleepPrevention()
            }
            return
        }

        if force {
            appliedSleepPreventionRequested = nil
        }
        applySleepPreventionRequested(true)
    }

    /// 只有实际防睡眠正在生效时达到上限才排队
    /// 其他原因先解除防睡眠时即使累计时长足够, 也不能把恢复动作归因给时长上限
    private func updatePendingKeepAliveLimitNotification(for blockReason: SleepBlockReason?) {
        guard blockReason == .limitReached else {
            pendingKeepAliveLimit = nil
            return
        }

        guard pendingKeepAliveLimit == nil,
              isActivelyPreventingSleep,
              sleepPreventionSource == .codexBar else {
            return
        }

        pendingKeepAliveLimit = maximumDuration
    }

    /// UI 关心的两个布尔都从 blockReason 派生, 且只在这里写
    /// 这么做是因为 sleepBlockReason 里的输入 (任务, helper 刷新中) 变化远比结论频繁,
    /// 让它们各自 @Published 会把整个设置页拖着一起重算
    /// 新增阻断条件时 allowsOptions 那个 switch 必须表态, 于是不会出现"入口亮着却点不动"
    private func publishDerivedState(blockReason: SleepBlockReason?) {
        assign(blockReason == .lowBattery, to: \.isLowBatteryBlocking)
        assign(Self.allowsOptions(blockReason), to: \.canShowOptions)
        publishNotificationDependencies()
    }

    /// 通知面板那两行的置灰依据
    /// 输入分散在三条路径上 (用户开关与 Hook 走 reconcileSleepState, 电量与阈值走 updateBatteryState,
    /// 上限走 setMaximumDuration), 所以规则只写这一份, 三处都调它
    private func publishNotificationDependencies() {
        let isKeepAliveUsable = isEnabled && isHookEnabled
        assign(
            isKeepAliveUsable && hasBattery && lowBatteryThreshold != .off,
            to: \.isLowBatteryProtectionEnabled
        )
        assign(
            isKeepAliveUsable && maximumDuration != .unlimited,
            to: \.isMaximumDurationEnabled
        )
    }

    /// 缺依赖时收起入口, 只是没在防睡眠 (没任务, 低电量, 已达上限) 时仍然要能改设置
    private static func allowsOptions(_ blockReason: SleepBlockReason?) -> Bool {
        switch blockReason {
        case .notStarted, .userOff, .hookDisabled, .helperUnavailable, .terminating:
            false
        case nil, .noTasks, .helperRefreshing, .lowBattery, .limitReached:
            true
        }
    }

    /// 任何一项变了才记一条, 逐次求值不记
    /// want 为 0 时这条是唯一能看出「是哪一项把它拉下来」的依据
    private func logSleepConditionsIfChanged(
        blockReason: SleepBlockReason?,
        trigger: LogTrigger
    ) {
        let conditions = SleepConditions(
            blockReason: blockReason,
            enabled: isEnabled,
            hook: isHookEnabled,
            tasks: hasKeepAliveTasks,
            helper: helperStatus,
            refreshing: isRefreshingHelper,
            battery: isLowBatteryActive,
            limited: hasReachedMaximumDuration
        )
        guard conditions != lastLoggedSleepConditions else {
            return
        }

        let previous = lastLoggedSleepConditions
        lastLoggedSleepConditions = conditions

        let triggerName = trigger.rawValue
        let helperName = String(describing: conditions.helper)
        let details = LogFields.joined(
            "trigger=\(triggerName)",
            "want=\(blockReason == nil ? 1 : 0)",
            "enabled=\(conditions.enabled ? 1 : 0)",
            "hook=\(conditions.hook ? 1 : 0)",
            "tasks=\(conditions.tasks ? 1 : 0)",
            "helper=\(helperName)",
            "refreshing=\(conditions.refreshing ? 1 : 0)",
            "battery=\(conditions.battery ? 1 : 0)",
            "limited=\(conditions.limited ? 1 : 0)"
        )
        AppLog.keepAlive.notice("KeepAlive 条件变化: \(details, privacy: .public)")

        guard let previous, previous.blockReason == nil, let blockReason else {
            return
        }

        AppLog.keepAlive.notice("KeepAlive 已解除: reason=\(blockReason.rawValue, privacy: .public)")
    }

    // MARK: - 睡眠切换与恢复

    private func applySleepPreventionRequested(
        _ requested: Bool,
        force: Bool = false,
        isObservation: Bool = false,
        completion: ((Bool) -> Void)? = nil
    ) {
        guard force || appliedSleepPreventionRequested != requested else {
            completion?(true)
            return
        }

        if requested, !isPreventingSleep {
            let result = systemSleepService.beginPreventingIdleSleep()
            guard result == kIOReturnSuccess else {
                AppLog.keepAlive.error("空闲断言建立失败: code=\(result)")
                operationErrorMessage = KeepAliveLocalizedMessage.preventIdleSleepFailed
                scheduleRetryIfNeeded(for: true)
                completion?(false)
                return
            }
        }

        helperRuntimeStatusMonitor.cancelRequest()
        completePendingRequest(success: false)
        let connection = connection ?? makeConnection()
        appliedSleepPreventionRequested = requested
        if requested {
            // 发出后就要按可能被 helper 接收处理, 不能等回复才记这笔租约
            mayHaveHelperLease = true
        }
        requestInFlight = true
        requestGeneration &+= 1
        let generation = requestGeneration
        pendingRequestCompletion = completion
        if !isObservation {
            let details = LogFields.joined(
                "op=\(requested ? "acquire" : "release")",
                "generation=\(generation)"
            )
            AppLog.keepAlive.notice("Helper XPC 请求已发送: \(details, privacy: .public)")
        }
        scheduleRequestTimeout(for: requested, generation: generation)

        let errorHandler: (Error) -> Void = { [weak self] error in
            Task { @MainActor in
                guard let self, generation == self.requestGeneration else {
                    return
                }
                self.handleConnectionFailure(error)
            }
        }
        guard let helper = connection.remoteObjectProxyWithErrorHandler(errorHandler)
            as? CodexBarHelperProtocol else {
            handleConnectionFailure(KeepAliveError.invalidHelperProxy)
            return
        }

        let reply: @Sendable (Int32, Int, Bool) -> Void = { [weak self] exitCode, sourceRawValue, sleepDisabledAfterOperation in
            Task { @MainActor [weak self] in
                await self?.handleSleepPreventionReply(
                    exitCode: exitCode,
                    sourceRawValue: sourceRawValue,
                    sleepDisabledAfterOperation: sleepDisabledAfterOperation,
                    requested: requested,
                    generation: generation,
                    isObservation: isObservation
                )
            }
        }
        helper.setSleepPreventionRequested(
            requested,
            clientSessionID: helperClientSessionID,
            generation: generation,
            reply: reply
        )
    }

    private func handleSleepPreventionReply(
        exitCode: Int32,
        sourceRawValue: Int,
        sleepDisabledAfterOperation: Bool,
        requested: Bool,
        generation: UInt64,
        isObservation: Bool
    ) async {
        guard generation == requestGeneration else {
            return
        }
        requestInFlight = false
        cancelRequestTimeout()
        let replyResult = exitCode == 0 ? "ok" : "failed"
        if !isObservation || exitCode != 0 {
            let details = LogFields.joined(
                "generation=\(generation)",
                "result=\(replyResult)",
                "exit=\(exitCode)"
            )
            AppLog.keepAlive.notice("Helper XPC 回复已收到: \(details, privacy: .public)")
        }
        guard exitCode == 0 else {
            handleSleepPreventionFailure(
                requested: requested,
                generation: generation,
                detail: "exit=\(exitCode)"
            )
            return
        }
        guard let source = CodexBarSleepPreventionSource(rawValue: sourceRawValue),
              !requested || (source != .none && sleepDisabledAfterOperation) else {
            let details = LogFields.joined(
                "source=\(sourceRawValue)",
                "sleepDisabled=\(sleepDisabledAfterOperation ? 1 : 0)"
            )
            handleSleepPreventionFailure(
                requested: requested,
                generation: generation,
                detail: details
            )
            return
        }

        cancelRetryTask()
        isPreventingSleep = requested
        operationErrorMessage = nil
        let previousSource = sleepPreventionSource
        updateSleepPreventionSource(source, requested: requested)
        reconcileDisplayAwake()

        if requested {
            finishSleepPreventionAcquire(
                source: source,
                previousSource: previousSource,
                generation: generation,
                isObservation: isObservation
            )
        } else {
            await finishSleepPreventionRelease(
                source: source,
                sleepDisabledAfterOperation: sleepDisabledAfterOperation,
                generation: generation
            )
        }
    }

    private func handleSleepPreventionFailure(
        requested: Bool,
        generation: UInt64,
        detail: String
    ) {
        let details = LogFields.joined(
            "generation=\(generation)",
            "detail=\(detail)"
        )
        AppLog.keepAlive.error("系统睡眠切换失败: \(details, privacy: .public)")
        handleHelperFailure(KeepAliveLocalizedMessage.toggleSleepFailed, retrying: requested)
    }

    private func updateSleepPreventionSource(
        _ source: CodexBarSleepPreventionSource,
        requested: Bool
    ) {
        if requested {
            assign(source, to: \.sleepPreventionSource)
            reconcileExternalObservation()
        } else {
            mayHaveHelperLease = false
            cancelExternalObservation()
            assign(.none, to: \.sleepPreventionSource)
        }
    }

    private func finishSleepPreventionAcquire(
        source: CodexBarSleepPreventionSource,
        previousSource: CodexBarSleepPreventionSource,
        generation: UInt64,
        isObservation: Bool
    ) {
        let lidStatus = SystemSleepService.currentStatus()
        let lidCausesSleep = lidStatus.map { $0.lidClosureCausesSleep ? "1" : "0" } ?? "unknown"
        if !isObservation || source != previousSource {
            let details = LogFields.joined(
                "generation=\(generation)",
                "source=\(String(describing: source))",
                "lidCausesSleep=\(lidCausesSleep)"
            )
            AppLog.keepAlive.notice("已防止系统睡眠: \(details, privacy: .public)")
        }
        durationLimiter.begin()
        completePendingRequest(success: true)
    }

    private func finishSleepPreventionRelease(
        source: CodexBarSleepPreventionSource,
        sleepDisabledAfterOperation: Bool,
        generation: UInt64
    ) async {
        durationLimiter.pause()
        if source == .codexBar, !sleepDisabledAfterOperation {
            await flushPendingSleepRestoreNotification()
        } else {
            pendingLowBatteryPercent = nil
            pendingKeepAliveLimit = nil
        }
        guard generation == requestGeneration else {
            return
        }
        finishSleepRestore(
            source: source,
            sleepDisabledAfterOperation: sleepDisabledAfterOperation
        )
        completePendingRequest(success: true)
    }

    private func finishSleepRestore(
        source: CodexBarSleepPreventionSource,
        sleepDisabledAfterOperation: Bool
    ) {
        let idleSleepResult = systemSleepService.endPreventingIdleSleep()
        if idleSleepResult != kIOReturnSuccess {
            AppLog.keepAlive.error("空闲断言释放失败: code=\(idleSleepResult)")
            operationErrorMessage = KeepAliveLocalizedMessage.restoreIdleSleepFailed
        }

        let sleepDisabled = sleepDisabledAfterOperation ? 1 : 0
        guard source == .codexBar else {
            let details = LogFields.joined(
                "source=\(String(describing: source))",
                "sleepDisabled=\(sleepDisabled)"
            )
            AppLog.keepAlive.notice("系统睡眠未修改: \(details, privacy: .public)")
            return
        }

        AppLog.keepAlive.notice("系统睡眠已恢复: sleepDisabled=\(sleepDisabled)")

        let lidStatus = SystemSleepService.currentStatus()
        let shouldRequestSystemSleep = !sleepDisabledAfterOperation
            && lidStatus?.shouldSleepForLidClosure == true

        // 合盖是边沿事件, 错过那一刻系统不会再评估
        // 只有 CodexBar 自己挡过并恢复为 0 才补发, 外部来源不属于我们的合盖边沿
        guard shouldRequestSystemSleep else {
            let reason: String = if sleepDisabledAfterOperation {
                "stillDisabled"
            } else if let lidStatus {
                lidStatus.isLidClosed ? "clamshellMode" : "lidOpen"
            } else {
                "unknown"
            }
            AppLog.keepAlive.notice(
                "睡眠补发已跳过: reason=\(reason, privacy: .public)"
            )
            return
        }

        AppLog.keepAlive.notice("睡眠补发已请求")
        let result = SystemSleepService.requestSystemSleep()
        if result != kIOReturnSuccess {
            AppLog.keepAlive.error("睡眠补发失败: code=\(result)")
            operationErrorMessage = KeepAliveLocalizedMessage.requestSystemSleepFailed
        }
    }

    private func completePendingRequest(success: Bool) {
        let completion = pendingRequestCompletion
        pendingRequestCompletion = nil
        completion?(success)
    }

    private func fetchHelperRuntimeStatus() async -> HelperRuntimeStatus? {
        guard !requestInFlight, !helperRuntimeStatusMonitor.isRequestInFlight else {
            return nil
        }
        let connection = connection ?? makeConnection()
        return await helperRuntimeStatusMonitor.fetch(
            connection: connection,
            timeout: KeepAliveHelperConfiguration.requestTimeout,
            onConnectionFailure: { [weak self] error in
                self?.handleConnectionFailure(error)
            },
            onTimeout: { [weak self] in
                self?.handleHelperStatusTimeout()
            }
        )
    }

    private func resetSleepAfterHelperUpdate(_ updateIdentifier: String) async -> Bool {
        guard !requestInFlight, !helperRuntimeStatusMonitor.isRequestInFlight else {
            return false
        }
        let connection = connection ?? makeConnection()
        return await helperRuntimeStatusMonitor.resetSleepAfterUpdate(
            connection: connection,
            updateIdentifier: updateIdentifier,
            timeout: KeepAliveHelperConfiguration.requestTimeout,
            onConnectionFailure: { [weak self] error in
                self?.handleConnectionFailure(error)
            },
            onTimeout: { [weak self] in
                self?.handleHelperStatusTimeout()
            }
        )
    }

    private func handleHelperStatusTimeout() {
        handleHelperFailure(
            KeepAliveLocalizedMessage.noResponse,
            retrying: isPreventingSleep ? shouldDisableSleep : nil
        )
    }

    private func releaseHelperLeaseIfNeeded(trigger: LogTrigger) async -> Bool {
        let blockReason = sleepBlockReason
        publishDerivedState(blockReason: blockReason)
        reconcileDisplayAwake()
        logSleepConditionsIfChanged(blockReason: blockReason, trigger: trigger)

        guard mayHaveHelperLease || isPreventingSleep else {
            releaseSleepPrevention()
            return true
        }

        return await withCheckedContinuation { continuation in
            applySleepPreventionRequested(false, force: true) { success in
                continuation.resume(returning: success)
            }
        }
    }

    // MARK: - XPC 连接与重试

    private func makeConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(
            machServiceName: CodexBarHelperIPC.machServiceName,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(
            with: CodexBarHelperProtocol.self
        )
        connection.invalidationHandler = { [weak self, weak connection] in
            Task { @MainActor in
                guard let self, let connection, self.connection === connection else {
                    return
                }
                self.handleHelperFailure(nil, retrying: self.requestInFlight || self.isPreventingSleep ? self.shouldDisableSleep : nil)
            }
        }
        connection.interruptionHandler = { [weak self, weak connection] in
            Task { @MainActor in
                guard let self, let connection, self.connection === connection else {
                    return
                }
                self.handleConnectionFailure(KeepAliveError.connectionInterrupted)
            }
        }
        connection.resume()
        self.connection = connection
        AppLog.keepAlive.notice("Helper XPC 已连接")
        return connection
    }

    private func handleConnectionFailure(_ error: Error) {
        AppLog.keepAlive.error("Helper XPC 连接失败: detail=\(error.localizedDescription, privacy: .public)")
        handleHelperFailure(
            KeepAliveLocalizedMessage.connectionFailed,
            retrying: requestInFlight || isPreventingSleep ? shouldDisableSleep : nil
        )
    }

    /// 断连和超时统一先复核授权, retrying 为 nil 时只收敛状态, 不重试租约
    private func handleHelperFailure(_ message: String?, retrying requested: Bool?) {
        invalidateConnection()
        refreshHelperStatus()
        guard helperStatus == .enabled else {
            return
        }
        if let message {
            operationErrorMessage = message
        }
        if let requested {
            scheduleRetryIfNeeded(for: requested)
        }
    }

    /// helper 起不来时 XPC 方法既不回复也不触发 errorHandler, 请求就那么挂着
    /// 没有这道超时, 界面会显示防睡眠开着而实际没生效, 日志里只剩一条没有配对回复的请求已发送
    private func scheduleRequestTimeout(for requested: Bool, generation: UInt64) {
        requestTimeoutTask?.cancel()
        requestTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: KeepAliveHelperConfiguration.requestTimeout)
            // 认状态而不是认取消位: 每条取消路径都同时推进了 generation 或清了 in-flight,
            // 认状态就不必依赖将来每个新路径都记得 cancel
            guard let self, generation == requestGeneration, requestInFlight else {
                return
            }

            let timeout = LogDuration.seconds(KeepAliveHelperConfiguration.requestTimeout)
            let details = LogFields.joined(
                "op=\(requested ? "acquire" : "release")",
                "generation=\(generation)",
                "timeout=\(timeout)"
            )
            AppLog.keepAlive.error("Helper XPC 请求超时: \(details, privacy: .public)")
            handleHelperFailure(KeepAliveLocalizedMessage.noResponse, retrying: requested)
        }
    }

    private func cancelRequestTimeout() {
        requestTimeoutTask?.cancel()
        requestTimeoutTask = nil
    }

    private func invalidateConnection() {
        cancelRequestTimeout()
        cancelExternalObservation()
        helperRuntimeStatusMonitor.cancelRequest()
        requestGeneration &+= 1
        let connection = connection
        self.connection = nil
        connection?.invalidationHandler = nil
        connection?.interruptionHandler = nil
        connection?.invalidate()
        completePendingRequest(success: false)
        // 无连接时也会走到这里, 只记真的断掉了一条, 避免空转刷屏
        if connection != nil {
            let mayHaveLease = mayHaveHelperLease ? 1 : 0
            AppLog.keepAlive.notice("Helper XPC 已断开: mayHaveLease=\(mayHaveLease)")
        }
        // 断连不能清 mayHaveHelperLease, 请求可能已在 helper 执行只是回复丢了
        appliedSleepPreventionRequested = nil
        requestInFlight = false
        releaseSleepPrevention()
    }

    /// assertion 与 isPreventingSleep 同进同退的唯一出口
    /// 两者必须一起收: 只清标志会让菜单栏图标显示成未防睡眠, 而这条 assertion 仍在防止空闲睡眠,
    /// 且没有任何后续路径会释放它; 仍需要防睡眠时由重试重建
    private func releaseSleepPrevention() {
        _ = systemSleepService.endPreventingIdleSleep()
        cancelExternalObservation()
        assign(false, to: \.isPreventingSleep)
        assign(.none, to: \.sleepPreventionSource)
        // 空闲断言与屏幕成对: 这里之后睡眠不再被挡, 屏幕也没有留住的理由
        reconcileDisplayAwake()
        // 收表跟着实际效果走: 这里之后睡眠不再被挡, 那段时间不该占用户的上限
        durationLimiter.pause()
    }

    /// pmset 轮询统一由 helper 执行, App 这里只读取缓存状态来刷新来源显示
    private func reconcileExternalObservation() {
        guard sleepPreventionSource == .external,
              isPreventingSleep,
              shouldDisableSleep else {
            cancelExternalObservation()
            return
        }
        helperRuntimeStatusMonitor.startObservation(
            interval: KeepAliveHelperConfiguration.externalObservationInterval
        ) { [weak self] in
            guard let self,
                  sleepPreventionSource == .external,
                  isPreventingSleep,
                  shouldDisableSleep else {
                self?.cancelExternalObservation()
                return
            }
            guard !requestInFlight,
                  let status = await fetchHelperRuntimeStatus() else {
                return
            }
            handleExternalObservation(status)
        }
    }

    private func handleExternalObservation(_ status: HelperRuntimeStatus) {
        guard sleepPreventionSource == .external,
              isPreventingSleep,
              shouldDisableSleep else {
            return
        }

        switch status.externalObservationAction {
        case .sourceBecameCodexBar:
            let previousSource = sleepPreventionSource
            updateSleepPreventionSource(.codexBar, requested: true)
            finishSleepPreventionAcquire(
                source: .codexBar,
                previousSource: previousSource,
                generation: requestGeneration,
                isObservation: true
            )
        case .reacquireLease:
            applySleepPreventionRequested(true, force: true, isObservation: true)
        case .none:
            break
        }
    }

    private func cancelExternalObservation() {
        helperRuntimeStatusMonitor.cancelObservation()
    }

    // MARK: - 屏幕常亮

    /// 用户开关与防睡眠实际效果的汇合点, 两边任意一个变了都要过这里
    /// 跟 isActivelyPreventingSleep 走, 于是低电量拦下, 达到上限, 任务结束时屏幕都会跟着放开
    /// 失败只记日志不占 operationErrorMessage: 那个字段是睡眠切换的结论, 会顶到设置页最前面,
    /// 让一个附加效果的失败显示成防睡眠本身出错
    private func reconcileDisplayAwake() {
        let shouldKeepAwake = keepsDisplayAwake && isActivelyPreventingSleep
        guard shouldKeepAwake != systemSleepService.isPreventingDisplaySleep else {
            return
        }

        guard shouldKeepAwake else {
            let result = systemSleepService.endPreventingDisplaySleep()
            if result != kIOReturnSuccess {
                AppLog.keepAlive.error("显示断言释放失败: code=\(result)")
                return
            }

            AppLog.keepAlive.notice("显示断言已释放")
            return
        }

        let result = systemSleepService.beginPreventingDisplaySleep()
        guard result == kIOReturnSuccess else {
            AppLog.keepAlive.error("显示断言建立失败: code=\(result)")
            return
        }

        AppLog.keepAlive.notice("显示断言已建立")
    }

    private func cancelRetryTask() {
        retryTask?.cancel()
        retryTask = nil
        // 成功或任务结束都会走到这里, 重试预算随之重置
        retryAttempt = 0
    }

    private func cancelHelperRegistrationTask() {
        helperRegistrationTask?.cancel()
        helperRegistrationTask = nil
        assign(false, to: \.isRefreshingHelper)
        reconcileAutoResetWakeSchedule()
        autoResetWakeScheduler.resumeAfterHelperInterruption()
    }

    private func scheduleRetryIfNeeded(for requested: Bool) {
        refreshHelperStatus()
        guard isStarted,
              helperStatus == .enabled,
              requested == shouldDisableSleep,
              retryTask == nil else {
            return
        }

        // 每次重试都会重建特权连接并以 root 拉起 pmset
        // 固定 2 秒无上限重试会让持续失败的 helper 变成无限循环
        guard retryAttempt < KeepAliveHelperConfiguration.sleepToggleRetryDelays.count else {
            AppLog.keepAlive.error(
                "KeepAlive 切换重试已放弃: attempts=\(KeepAliveHelperConfiguration.sleepToggleRetryDelays.count)"
            )
            operationErrorMessage = KeepAliveLocalizedMessage.retryLimitReached
            return
        }

        let delay = KeepAliveHelperConfiguration.sleepToggleRetryDelays[retryAttempt]
        retryAttempt += 1
        let attempt = retryAttempt
        let wait = LogDuration.seconds(delay)
        let details = LogFields.joined(
            "attempt=\(attempt)",
            "delay=\(wait)",
            "requested=\(requested ? 1 : 0)"
        )
        AppLog.keepAlive.notice("睡眠切换重试: \(details, privacy: .public)")

        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else {
                return
            }
            retryTask = nil
            refreshHelperStatus()
            guard helperStatus == .enabled else {
                return
            }
            guard requested == shouldDisableSleep else {
                reconcileSleepState(trigger: .retry)
                return
            }
            appliedSleepPreventionRequested = nil
            applySleepPreventionRequested(requested)
        }
    }

    // MARK: - 防睡眠条件判定

    /// 用户意图 (isEnabled) 与依赖可用性在这里汇合
    /// 依赖不满足只让效果失效, 不回写 isEnabled
    private var shouldDisableSleep: Bool {
        sleepBlockReason == nil
    }

    /// 等待批准算不算"有任务"由用户开关决定, 快照与设置两条路径共用这一份规则
    private var hasKeepAliveTasks: Bool {
        hasRunningTasks || (keepsAwakeWhileWaiting && !waitingTaskIDs.isEmpty)
    }

    /// 按顺序返回第一个不满足的条件, 全部满足时为 nil
    /// 判定与日志共用这一份顺序, 新增条件不会漏进日志
    private var sleepBlockReason: SleepBlockReason? {
        if !isStarted {
            return .notStarted
        }
        if isPreparingForTermination {
            return .terminating
        }
        if !isEnabled {
            return .userOff
        }
        if !isHookEnabled {
            return .hookDisabled
        }
        // 先检查依赖, 避免 Hook 恢复任务前以 noTasks 提前放出未授权 Helper 的设置入口
        if helperStatus != .enabled {
            return .helperUnavailable
        }
        if !hasKeepAliveTasks {
            return .noTasks
        }
        if isRefreshingHelper {
            return .helperRefreshing
        }
        if isLowBatteryActive {
            return .lowBattery
        }
        if hasReachedMaximumDuration {
            return .limitReached
        }
        return nil
    }

    // MARK: - 常量

    private static let enabledKey = "KeepAlive.isEnabled"
    private static let lowBatteryThresholdKey = "KeepAlive.lowBatteryThresholdPercent"
    private static let keepsAwakeWhileWaitingKey = "KeepAlive.keepsAwakeWhileWaiting"
    private static let keepsDisplayAwakeKey = "KeepAlive.keepsDisplayAwake"
    /// 解除门槛比触发门槛高这么多个百分点, 避免电量在阈值附近抖动导致反复切换
    private static let lowBatteryHysteresis = 5
}

extension KeepAliveController {
    private func replaceRegisteredHelper(_ service: SMAppService) async -> (didUnregisterHelper: Bool, error: Error?) {
        do {
            try Task.checkCancellation()
            guard await autoResetWakeScheduler.cancelBeforeHelperInterruption() else {
                throw KeepAliveError.wakeScheduleCancellationFailed
            }
            reconcileAutoResetWakeSchedule()
            try Task.checkCancellation()
            try await service.unregister()
            mayHaveHelperLease = false
            try Task.checkCancellation()
            try await registerRefreshedHelper(service)
            return (true, nil)
        } catch is CancellationError {
            return (false, CancellationError())
        } catch {
            return (false, error)
        }
    }

    func setAutoResetRequested(_ requested: Bool) {
        guard requested != isAutoResetRequested else {
            if requested {
                reconcileAutoResetWakeSchedule()
            }
            return
        }

        isAutoResetRequested = requested
        autoResetWakeScheduler.setRequested(requested)
        if requested, isStarted {
            ensureHelperRegistration()
        }
        reconcileAutoResetWakeSchedule()
    }

    func setAutoResetWakeDate(_ date: Date?) {
        autoResetWakeScheduler.setWakeDate(date)
    }

    private var isHelperReadyForAutoResetWake: Bool {
        guard helperStatus == .enabled,
              !isRefreshingHelper,
              !KeepAliveHelperConfiguration.registrationNeedsRefresh(defaults: defaults) else {
            return false
        }
        return KeepAliveHelperConfiguration.pendingUpdateIdentifier(defaults: defaults) == nil
    }

    private func reconcileAutoResetWakeSchedule() {
        autoResetWakeScheduler.setHelperReady(
            isStarted && isHelperReadyForAutoResetWake
        )
    }
}

private extension KeepAliveController {
    func completePendingHelperUpdate(_ updateIdentifier: String) {
        guard helperRegistrationTask == nil else {
            return
        }

        assign(true, to: \.isRefreshingHelper)
        reconcileAutoResetWakeSchedule()
        cancelRetryTask()
        cancelExternalObservation()
        registrationErrorMessage = nil
        operationErrorMessage = nil

        helperRegistrationTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            let succeeded = await completeHelperUpdate(updateIdentifier)
            guard isStarted, !Task.isCancelled else {
                return
            }
            if !succeeded {
                registrationErrorMessage = KeepAliveLocalizedMessage.updateFailed
            }

            assign(!succeeded && helperStatus == .enabled, to: \.isRefreshingHelper)
            helperRegistrationTask = nil
            reconcileSleepState(trigger: .helperRegistered, force: true)
            reconcileAutoResetWakeSchedule()
        }
    }

    func completeHelperUpdate(_ updateIdentifier: String) async -> Bool {
        for delay in KeepAliveHelperConfiguration.updateCompletionRetryDelays {
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled else {
                return false
            }

            refreshHelperStatus()
            guard helperStatus == .enabled else {
                continue
            }
            if await resetSleepAfterHelperUpdate(updateIdentifier) {
                KeepAliveHelperConfiguration.completeUpdate(
                    updateIdentifier,
                    defaults: defaults
                )
                mayHaveHelperLease = false
                appliedSleepPreventionRequested = nil
                operationErrorMessage = nil
                return true
            }
        }
        return false
    }
}
