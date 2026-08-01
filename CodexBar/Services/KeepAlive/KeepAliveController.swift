import AppKit
import Combine
import CryptoKit
import Foundation
import IOKit
import os
import ServiceManagement

@MainActor
final class KeepAliveController: ObservableObject {
    @Published private(set) var isEnabled: Bool
    @Published private(set) var helperStatus = HelperStatus.notRegistered
    @Published private(set) var isPreventingSleep = false
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

    /// helper 安装与注册状态的错误, 注册恢复正常时才清除
    @Published private var registrationErrorMessage: String?
    /// 切换睡眠状态过程中的错误, 只能由下一次操作结果或用户动作覆盖
    /// 与注册类错误分开存储: refreshHelperStatus 每次 App 激活都会跑, 不能抹掉操作结果
    @Published private var operationErrorMessage: String?

    /// 注册不成功时操作类错误只是下游噪音, 优先展示注册问题
    var errorMessage: String? {
        registrationErrorMessage ?? operationErrorMessage
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
    /// 所以返回值用不上, 也不像低电量那条需要锁存: hasReached 粘滞且此刻已不在防睡眠,
    /// 同一个周期里排不进第二次, 周期边界本身就是重置点
    /// 提交失败这一条就丢了, 重新 flush 需要再来一次睡眠恢复, 而睡眠已经恢复完了
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
    private var connection: NSXPCConnection?
    /// 本轮接管以来连接没有断过, helper 那边的哨兵必然还在
    /// 断过就可能是 helper 已经自行恢复并清掉哨兵, 那之后拿到的回复只是占位值, 不是实测状态
    /// 能这样判断是因为哨兵只由 helper 侧的恢复删除, 而那些路径都要求连接已断
    private var canTrustRestoreResult = false
    private var appliedSleepDisabled: Bool?
    private var requestInFlight = false
    private var requestGeneration: UInt64 = 0
    private var retryTask: Task<Void, Never>?
    private var requestTimeoutTask: Task<Void, Never>?
    private var retryAttempt = 0
    private var helperRegistrationTask: Task<Void, Never>?
    /// 与 hasRunningTasks 同理: 只经由派生状态影响 UI, 自己不发信号
    private var isRefreshingHelper = false
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
    private var lastLoggedSleepConditions: SleepConditions?
    /// codexHookSettings.isOperable 的最新值, 由订阅维护
    /// 不直接读那个属性: 订阅回调跑在 willSet, 那时它还是改动前的值
    private var isHookEnabled: Bool

    /// 防睡眠没生效时缺的是哪一项, 同时充当日志里的 reason= 取值
    private enum SleepBlockReason: String {
        case notStarted
        case userOff
        case hookDisabled
        case noTasks
        case helperUnavailable
        case helperRefreshing
        case lowBattery
        case limitReached
    }

    /// shouldDisableSleep 的求值结果与它依赖的各项, 只用于变化检测与日志
    /// blockReason 与 shouldDisableSleep 同源, 不会出现"字段都满足却报某项缺失"
    /// battery 只放布尔: 放电量百分比会让每掉 1% 都记一条
    private struct SleepConditions: Equatable {
        let blockReason: SleepBlockReason?
        let enabled: Bool
        let hook: Bool
        let tasks: Bool
        let helper: HelperStatus
        let refreshing: Bool
        let battery: Bool
        let limited: Bool
    }

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
        startedRunningTaskIDs.removeAll()
        waitingTaskIDs.removeAll()
        durationLimiter.stop()
        powerSourceMonitor.stop()
        assign(false, to: \.isLowBatteryActive)
        clearPendingLowBatteryNotification()
        pendingKeepAliveLimit = nil

        if connection != nil {
            applySleepDisabled(false)
        }
        invalidateConnection()
    }

    func refresh() {
        // 电源监听注册失败并降级成轮询时, 这是唯一还会即时重读电量的路径
        powerSourceMonitor.refresh()
        refreshRegistrationAndSleepState()
    }

    private func refreshRegistrationAndSleepState() {
        refreshHelperStatus()
        if isEnabled || helperStatus.isRegisteredOrAwaitingApproval {
            ensureHelperRegistration(opensSystemSettings: false)
        }
        reconcileSleepState(trigger: .statusRefresh)
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
        registrationErrorMessage = nil
        operationErrorMessage = nil

        if enabled {
            ensureHelperRegistration(opensSystemSettings: true)
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

        AppLog.keepAlive.notice("KeepAlive 等待批准时保持变更: enabled=\(enabled ? 1 : 0)")
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
        AppLog.keepAlive.notice(
            "KeepAlive 电量已触及阈值: percent=\(status.percent); threshold=\(threshold); action=\(wasPreventingSleep ? "release" : "none", privacy: .public)"
        )

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
        let runningTaskIDs = Set(snapshot.runningTasks.map(\.id))
        let currentWaitingTaskIDs = Set(snapshot.waitingTasks.map(\.id))
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

    private func ensureHelperRegistration(opensSystemSettings: Bool) {
        let service = Self.helperService
        refreshHelperStatus()

        switch helperStatus {
        case .enabled, .requiresApproval:
            if helperRegistrationNeedsRefresh {
                refreshRegisteredHelper(opensSystemSettings: opensSystemSettings)
            } else if helperStatus == .requiresApproval, opensSystemSettings {
                openSystemSettings()
            }
            return
        case .notRegistered, .notFound:
            guard Self.helperAssetsArePresent else {
                registrationErrorMessage = "服务异常, 请重新安装 CodexBar"
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
                registrationErrorMessage = "注册服务失败"
            }
        }

        refreshHelperStatus()
        recordHelperRegistrationIfCurrent()
        if helperStatus == .requiresApproval, opensSystemSettings {
            openSystemSettings()
        }
    }

    private func refreshRegisteredHelper(opensSystemSettings: Bool) {
        guard helperRegistrationTask == nil,
              Self.helperAssetsArePresent else {
            return
        }

        assign(true, to: \.isRefreshingHelper)
        cancelRetryTask()
        invalidateConnection()
        // 连接已失效, 重试也取消了, 之前的操作类错误已经过期
        registrationErrorMessage = nil
        operationErrorMessage = nil

        let service = Self.helperService
        helperRegistrationTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            var registrationError: Error?
            do {
                try Task.checkCancellation()
                try await service.unregister()
                try Task.checkCancellation()
                try await registerRefreshedHelper(service)
            } catch is CancellationError {
                return
            } catch {
                registrationError = error
            }

            guard isStarted, !Task.isCancelled else {
                return
            }

            refreshHelperStatus()
            if helperStatus.isRegisteredOrAwaitingApproval {
                recordHelperRegistrationIfCurrent()
            } else if let registrationError {
                AppLog.keepAlive.error(
                    "Helper 注册更新失败: detail=\(registrationError.localizedDescription, privacy: .public)"
                )
                registrationErrorMessage = "更新服务失败"
            }

            assign(false, to: \.isRefreshingHelper)
            helperRegistrationTask = nil
            if helperStatus == .requiresApproval, opensSystemSettings {
                openSystemSettings()
            }
            reconcileSleepState(trigger: .helperRegistered, force: true)
        }
    }

    private func registerRefreshedHelper(_ service: SMAppService) async throws {
        await Task.yield()

        var retryDelays = Self.helperRegistrationRetryDelays.makeIterator()
        while true {
            do {
                try service.register()
                return
            } catch {
                guard Self.isTransientHelperRegistrationError(error),
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

    private static func isTransientHelperRegistrationError(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == SMAppServiceErrorDomain
            && error.code == operationNotPermittedErrorCode
    }

    private func refreshHelperStatus() {
        let previousStatus = helperStatus
        assign(HelperStatus(Self.helperService.status), to: \.helperStatus)
        // 每次 App 激活都会跑, 只记真正的迁移, 否则日志会被无变化的求值淹没
        // 取局部量再插值: Logger 的插值是 autoclosure, 直接写属性会被要求显式 self, 与 --self remove 冲突
        let currentStatus = helperStatus
        if currentStatus != previousStatus {
            AppLog.keepAlive.notice(
                "Helper 注册状态变化: from=\(String(describing: previousStatus), privacy: .public); to=\(String(describing: currentStatus), privacy: .public)"
            )
        }
        if helperStatus == .enabled {
            // 注册已正常, 只撤回注册类抱怨
            // 操作类结果 (例如重试耗尽) 必须留到下一次操作有结论为止
            assign(nil, to: \.registrationErrorMessage)
        } else if helperStatus != .requiresApproval {
            releaseSleepPrevention()
            durationLimiter.reset()
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

        guard wantsSleepDisabled else {
            cancelRetryTask()
            if connection != nil, appliedSleepDisabled != false || isPreventingSleep {
                applySleepDisabled(false)
            } else {
                releaseSleepPrevention()
            }
            return
        }

        if force {
            appliedSleepDisabled = nil
        }
        applySleepDisabled(true)
    }

    /// 只有实际防睡眠正在生效时达到上限才排队
    /// 其他原因先解除防睡眠时即使累计时长足够, 也不能把恢复动作归因给时长上限
    private func updatePendingKeepAliveLimitNotification(for blockReason: SleepBlockReason?) {
        guard blockReason == .limitReached else {
            pendingKeepAliveLimit = nil
            return
        }

        guard pendingKeepAliveLimit == nil, isActivelyPreventingSleep else {
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
        case .notStarted, .userOff, .hookDisabled, .helperUnavailable:
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
        AppLog.keepAlive.notice(
            "KeepAlive 条件变化: trigger=\(triggerName, privacy: .public); want=\(blockReason == nil ? 1 : 0); enabled=\(conditions.enabled ? 1 : 0); hook=\(conditions.hook ? 1 : 0); tasks=\(conditions.tasks ? 1 : 0); helper=\(helperName, privacy: .public); refreshing=\(conditions.refreshing ? 1 : 0); battery=\(conditions.battery ? 1 : 0); limited=\(conditions.limited ? 1 : 0)"
        )

        guard let previous, previous.blockReason == nil, let blockReason else {
            return
        }

        AppLog.keepAlive.notice("KeepAlive 已解除: reason=\(blockReason.rawValue, privacy: .public)")
    }

    // MARK: - 睡眠切换与恢复

    private func applySleepDisabled(_ disabled: Bool) {
        guard appliedSleepDisabled != disabled else {
            return
        }

        if disabled {
            let result = systemSleepService.beginPreventingIdleSleep()
            guard result == kIOReturnSuccess else {
                AppLog.keepAlive.error("空闲断言建立失败: code=\(result)")
                operationErrorMessage = "防止空闲睡眠失败"
                scheduleRetryIfNeeded(for: true)
                return
            }
        }

        let connection = connection ?? makeConnection()
        appliedSleepDisabled = disabled
        requestInFlight = true
        requestGeneration &+= 1
        let generation = requestGeneration
        // 与下面的回复日志配成一对, 缺回复即说明请求丢在 XPC 途中或 helper 无响应
        AppLog.keepAlive.notice(
            "Helper XPC 请求已发送: op=\(disabled ? "disable" : "restore", privacy: .public); generation=\(generation)"
        )
        scheduleRequestTimeout(for: disabled, generation: generation)

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

        helper.setSleepDisabled(disabled) { [weak self] exitCode, sleepDisabledAfterOperation in
            Task { @MainActor in
                guard let self, generation == self.requestGeneration else {
                    return
                }
                self.requestInFlight = false
                self.cancelRequestTimeout()
                let replyResult = exitCode == 0 ? "ok" : "failed"
                AppLog.keepAlive.notice(
                    "Helper XPC 回复已收到: generation=\(generation); result=\(replyResult, privacy: .public); exit=\(exitCode)"
                )
                guard exitCode == 0 else {
                    // invalidateConnection 会连同 assertion 一起收
                    self.invalidateConnection()
                    AppLog.keepAlive.error("系统睡眠切换失败: generation=\(generation); exit=\(exitCode)")
                    self.operationErrorMessage = "切换睡眠状态失败"
                    self.scheduleRetryIfNeeded(for: disabled)
                    return
                }

                self.cancelRetryTask()
                self.isPreventingSleep = disabled
                self.operationErrorMessage = nil
                // 屏幕跟着实际效果走, 这里是它唯一的建立时机
                self.reconcileDisplayAwake()
                if disabled {
                    // lidCausesSleep=0 说明这一轮 pmset 是空转的, 真正在挡的只有空闲断言
                    // 排查「开了却还是睡了」时先看这个字段
                    let lidStatus = SystemSleepService.currentStatus()
                    let lidCausesSleep = lidStatus
                        .map { $0.lidClosureCausesSleep ? "1" : "0" } ?? "unknown"
                    AppLog.keepAlive.notice(
                        "系统睡眠已关闭: generation=\(generation); lidCausesSleep=\(lidCausesSleep, privacy: .public)"
                    )
                    self.canTrustRestoreResult = true
                    self.durationLimiter.begin()
                } else {
                    // 先收表再走恢复: finishSleepRestore 可能直接把机器送去睡
                    self.durationLimiter.pause()
                    // 通知同样要赶在补发睡眠之前发出去, 理由与收表相同
                    // 走到这里 pmset 已经恢复成功, 那句"已恢复系统睡眠"才站得住
                    await self.flushPendingSleepRestoreNotification()
                    // 上面这一步会挂起, 期间可能已经有新的禁用请求接管
                    // 那时再走恢复会释放掉刚建立的空闲断言, 所以重新认一次代
                    guard generation == self.requestGeneration else {
                        return
                    }
                    self.finishSleepRestore(
                        sleepDisabledAfterOperation: sleepDisabledAfterOperation
                    )
                }
            }
        }
    }

    private func finishSleepRestore(sleepDisabledAfterOperation: Bool) {
        // assertion 无论回复可不可信都要释放, 与下面的判断无关
        let idleSleepResult = systemSleepService.endPreventingIdleSleep()
        if idleSleepResult != kIOReturnSuccess {
            AppLog.keepAlive.error("空闲断言释放失败: code=\(idleSleepResult)")
            operationErrorMessage = "恢复空闲睡眠策略失败"
        }

        let sleepDisabled = sleepDisabledAfterOperation ? 1 : 0
        // 连接断过时 helper 可能已自行恢复并清掉哨兵, 这份回复不带实测状态
        // 不能据此补发合盖睡眠: 本轮可能压根不是我们禁用的睡眠
        guard canTrustRestoreResult else {
            // 这条判断是防止误发强制睡眠的唯一屏障, 生效时必须留痕, 否则误判无从追查
            AppLog.keepAlive.notice("系统睡眠恢复结果不可信: reason=connectionLost")
            return
        }

        AppLog.keepAlive.notice("系统睡眠已恢复: sleepDisabled=\(sleepDisabled)")

        let lidStatus = SystemSleepService.currentStatus()
        let shouldRequestSystemSleep = !sleepDisabledAfterOperation
            && lidStatus?.shouldSleepForLidClosure == true

        // 合盖是边沿事件, 错过那一刻系统不会再评估
        // 我们挡过一次就得在恢复后补一脚, 否则盖着的机器会一直醒着
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
            operationErrorMessage = "请求系统睡眠失败"
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
                guard let self, self.connection === connection else {
                    return
                }
                let shouldRetry = self.requestInFlight || self.isPreventingSleep
                let desiredSleepDisabled = self.shouldDisableSleep
                // 复用统一清理: 连接失效同样要释放 assertion, 否则空闲睡眠会被永久阻止
                self.invalidateConnection()
                if shouldRetry {
                    self.scheduleRetryIfNeeded(for: desiredSleepDisabled)
                }
            }
        }
        connection.interruptionHandler = { [weak self] in
            Task { @MainActor in
                self?.handleConnectionFailure(KeepAliveError.connectionInterrupted)
            }
        }
        connection.resume()
        self.connection = connection
        AppLog.keepAlive.notice("Helper XPC 已连接")
        return connection
    }

    private func handleConnectionFailure(_ error: Error) {
        let shouldRetry = requestInFlight || isPreventingSleep
        let desiredSleepDisabled = shouldDisableSleep
        invalidateConnection()
        AppLog.keepAlive.error(
            "Helper XPC 连接失败: detail=\(error.localizedDescription, privacy: .public)"
        )
        operationErrorMessage = "连接服务失败"
        if shouldRetry {
            scheduleRetryIfNeeded(for: desiredSleepDisabled)
        }
    }

    /// helper 起不来时 setSleepDisabled 既不回复也不触发 errorHandler, 请求就那么挂着
    /// 没有这道超时, 界面会显示防睡眠开着而实际没生效, 日志里只剩一条没有配对回复的请求已发送
    private func scheduleRequestTimeout(for disabled: Bool, generation: UInt64) {
        requestTimeoutTask?.cancel()
        requestTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.helperRequestTimeout)
            // 认状态而不是认取消位: 每条取消路径都同时推进了 generation 或清了 in-flight,
            // 认状态就不必依赖将来每个新路径都记得 cancel
            guard let self, generation == requestGeneration, requestInFlight else {
                return
            }

            let timeout = LogDuration.seconds(Self.helperRequestTimeout)
            AppLog.keepAlive.error(
                "Helper XPC 请求超时: op=\(disabled ? "disable" : "restore", privacy: .public); generation=\(generation); timeout=\(timeout, privacy: .public)"
            )
            // 连接已经不可信, 收掉它再走既有的重试阶梯, 与切换失败同一条路径
            invalidateConnection()
            operationErrorMessage = "服务无响应"
            scheduleRetryIfNeeded(for: disabled)
        }
    }

    private func cancelRequestTimeout() {
        requestTimeoutTask?.cancel()
        requestTimeoutTask = nil
    }

    private func invalidateConnection() {
        cancelRequestTimeout()
        requestGeneration &+= 1
        let connection = connection
        self.connection = nil
        connection?.invalidationHandler = nil
        connection?.interruptionHandler = nil
        connection?.invalidate()
        // 无连接时也会走到这里, 只记真的断掉了一条, 避免空转刷屏
        if connection != nil {
            // trusted 记的是断开这一刻的可信度: 它一断, 后面那轮恢复回复就不再可信
            // 也就不会补发睡眠, 这是追查「任务结束了机器却没睡」的唯一线索
            let trusted = canTrustRestoreResult ? 1 : 0
            AppLog.keepAlive.notice("Helper XPC 已断开: trusted=\(trusted)")
        }
        // 所有能让我们在哨兵已删的情况下再发一次恢复请求的路径都汇到这里, 标志清在这里才严密
        canTrustRestoreResult = false
        appliedSleepDisabled = nil
        requestInFlight = false
        releaseSleepPrevention()
    }

    /// assertion 与 isPreventingSleep 同进同退的唯一出口
    /// 两者必须一起收: 只清标志会让菜单栏图标显示成未防睡眠, 而这条 assertion 仍在防止空闲睡眠,
    /// 且没有任何后续路径会释放它; 仍需要防睡眠时由重试经 applySleepDisabled(true) 重建
    private func releaseSleepPrevention() {
        _ = systemSleepService.endPreventingIdleSleep()
        assign(false, to: \.isPreventingSleep)
        // 空闲断言与屏幕成对: 这里之后睡眠不再被挡, 屏幕也没有留住的理由
        reconcileDisplayAwake()
        // 收表跟着实际效果走: 这里之后睡眠不再被挡, 那段时间不该占用户的上限
        durationLimiter.pause()
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
    }

    private func scheduleRetryIfNeeded(for disabled: Bool) {
        guard isStarted,
              helperStatus == .enabled,
              disabled == shouldDisableSleep,
              retryTask == nil else {
            return
        }

        // 每次重试都会重建特权连接并以 root 拉起 pmset
        // 固定 2 秒无上限重试会让持续失败的 helper 变成无限循环
        guard retryAttempt < Self.sleepToggleRetryDelays.count else {
            AppLog.keepAlive.error(
                "KeepAlive 切换重试已放弃: attempts=\(Self.sleepToggleRetryDelays.count)"
            )
            operationErrorMessage = "防睡眠多次失败, 已停止重试"
            return
        }

        let delay = Self.sleepToggleRetryDelays[retryAttempt]
        retryAttempt += 1
        let attempt = retryAttempt
        let wait = LogDuration.seconds(delay)
        AppLog.keepAlive.notice(
            "睡眠切换重试: attempt=\(attempt); delay=\(wait, privacy: .public); disabled=\(disabled ? 1 : 0)"
        )

        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else {
                return
            }
            retryTask = nil
            guard disabled == shouldDisableSleep else {
                reconcileSleepState(trigger: .retry)
                return
            }
            appliedSleepDisabled = nil
            applySleepDisabled(disabled)
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
        if !isEnabled {
            return .userOff
        }
        if !isHookEnabled {
            return .hookDisabled
        }
        if !hasKeepAliveTasks {
            return .noTasks
        }
        if helperStatus != .enabled {
            return .helperUnavailable
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
    private static let helperRegistrationFingerprintKey = "KeepAlive.helperRegistrationFingerprint"
    private static let helperRegistrationRetryDelays: [Duration] = [
        .milliseconds(500),
        .seconds(1),
        .seconds(2)
    ]
    private static let operationNotPermittedErrorCode = 1

    /// 与 helper 的 watchdog 宽限是一对, 取值和理由都在 CodexBarHelperIPC 那边
    private static let helperRequestTimeout = Duration.seconds(
        CodexBarHelperIPC.requestTimeoutSeconds
    )

    /// 切换睡眠状态失败后的重试节奏, 逐次翻倍
    /// 列表耗尽即放弃 (延时累计约 8.5 分钟, 每轮再等一次超时约 10 分钟): 瞬时抖动能自愈, 权限类故障不会无限重试
    private static let sleepToggleRetryDelays: [Duration] = [
        .seconds(2),
        .seconds(4),
        .seconds(8),
        .seconds(16),
        .seconds(32),
        .seconds(64),
        .seconds(128),
        .seconds(256)
    ]

    // MARK: - helper 资源与指纹

    private static var helperService: SMAppService {
        SMAppService.daemon(plistName: CodexBarHelperIPC.daemonPlistName)
    }

    private static var helperAssetsArePresent: Bool {
        FileManager.default.fileExists(atPath: daemonPlistURL.path)
            && FileManager.default.isExecutableFile(atPath: helperExecutableURL.path)
    }

    private var helperRegistrationNeedsRefresh: Bool {
        guard let fingerprint = Self.helperRegistrationFingerprint else {
            return false
        }
        return defaults.string(forKey: Self.helperRegistrationFingerprintKey) != fingerprint
    }

    private func recordHelperRegistrationIfCurrent() {
        guard helperStatus.isRegisteredOrAwaitingApproval,
              let fingerprint = Self.helperRegistrationFingerprint else {
            return
        }
        defaults.set(fingerprint, forKey: Self.helperRegistrationFingerprintKey)
    }

    private static var helperRegistrationFingerprint: String? {
        guard let helperData = try? Data(contentsOf: helperExecutableURL, options: .mappedIfSafe),
              let daemonPlistData = try? Data(contentsOf: daemonPlistURL, options: .mappedIfSafe) else {
            return nil
        }

        var hasher = SHA256()
        for (name, data) in [
            (helperExecutableURL.lastPathComponent, helperData),
            (daemonPlistURL.lastPathComponent, daemonPlistData)
        ] {
            hasher.update(data: Data("\(name)\n\(data.count)\n".utf8))
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static var appContentsURL: URL {
        Bundle.main.bundleURL.appending(path: "Contents", directoryHint: .isDirectory)
    }

    private static var helperExecutableURL: URL {
        appContentsURL
            .appending(path: "Resources", directoryHint: .isDirectory)
            .appending(path: "CodexBarHelper")
    }

    private static var daemonPlistURL: URL {
        appContentsURL
            .appending(path: "Library/LaunchDaemons", directoryHint: .isDirectory)
            .appending(path: CodexBarHelperIPC.daemonPlistName)
    }
}

private enum KeepAliveError: LocalizedError {
    case invalidHelperProxy
    case connectionInterrupted

    var errorDescription: String? {
        switch self {
        case .invalidHelperProxy:
            "服务接口无效"
        case .connectionInterrupted:
            "服务连接中断"
        }
    }
}
