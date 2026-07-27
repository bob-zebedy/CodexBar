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
    @Published private(set) var maximumDuration: MaximumDuration
    @Published private(set) var helperStatus = HelperStatus.notRegistered
    @Published private(set) var isPreventingSleep = false
    @Published private(set) var hasReachedMaximumDuration = false

    /// helper 安装与注册状态的错误, 注册恢复正常时才清除
    @Published private var registrationErrorMessage: String?
    /// 切换休眠状态过程中的错误, 只能由下一次操作结果或用户动作覆盖
    /// 与注册类错误分开存储: refreshHelperStatus 每次 App 激活都会跑, 不能抹掉操作结果
    @Published private var operationErrorMessage: String?

    /// 注册不成功时操作类错误只是下游噪音, 优先展示注册问题
    var errorMessage: String? {
        registrationErrorMessage ?? operationErrorMessage
    }

    /// 用户开关仍开着, 且 helper 已经真的把休眠关掉
    /// isPreventingSleep 在稳态下已隐含 isEnabled (shouldDisableSleep 要求它)
    /// 叠这一层是为了关开关到 helper 回调之间的异步空窗: 用户意图先落地
    var isActivelyPreventingSleep: Bool {
        isEnabled && isPreventingSleep
    }

    private let activityMonitor: CodexActivityMonitor
    private let codexHookSettings: CodexHookSettings
    private let defaults: UserDefaults
    private let systemSleepService = SystemSleepService()
    private var hasRunningTasks = false
    /// 保留仍活跃且已经进入过运行态的任务, 避免普通快照刷新被误判成新任务
    private var startedRunningTaskIDs = Set<UUID>()
    /// 记录上一份快照中的等待任务, 用于识别等待批准后恢复运行的状态转换
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
    private var retryAttempt = 0
    private var maximumDurationTask: Task<Void, Never>?
    private var maximumDurationStartedAt: Date?
    private var helperRegistrationTask: Task<Void, Never>?
    private var isRefreshingHelper = false
    private var cancellables = Set<AnyCancellable>()
    private var isStarted = false

    init(
        activityMonitor: CodexActivityMonitor,
        codexHookSettings: CodexHookSettings,
        defaults: UserDefaults = .standard
    ) {
        self.activityMonitor = activityMonitor
        self.codexHookSettings = codexHookSettings
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        maximumDuration = (defaults.object(forKey: Self.maximumDurationKey) as? Int)
            .flatMap(MaximumDuration.init(rawValue:)) ?? .twelveHours
    }

    func start() {
        guard !isStarted else {
            return
        }
        isStarted = true

        // Hook 是本功能的依赖, 不是用户意图
        // 只重新求值当前该不该阻止休眠, 绝不改写用户保存的开关
        codexHookSettings.$isEnabled
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.reconcileSleepState()
            }
            .store(in: &cancellables)

        activityMonitor.$snapshot
            .sink { [weak self] snapshot in
                self?.handleActivitySnapshot(snapshot)
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
        resetMaximumDurationState()

        if connection != nil {
            applySleepDisabled(false)
        }
        invalidateConnection()
    }

    func refresh() {
        refreshRegistrationAndSleepState()
    }

    private func refreshRegistrationAndSleepState() {
        refreshHelperStatus()
        if isEnabled || helperStatus.isRegisteredOrAwaitingApproval {
            ensureHelperRegistration(opensSystemSettings: false)
        }
        reconcileSleepState()
    }

    func setEnabled(_ enabled: Bool) {
        guard !enabled || codexHookSettings.isEnabled else {
            return
        }
        guard enabled != isEnabled else {
            return
        }

        AppLog.keepAlive.notice("阻止休眠开关已变更: enabled=\(enabled ? 1 : 0)")
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        registrationErrorMessage = nil
        operationErrorMessage = nil

        if enabled {
            ensureHelperRegistration(opensSystemSettings: true)
        } else {
            resetMaximumDurationState()
        }
        reconcileSleepState()
    }

    func setMaximumDuration(_ duration: MaximumDuration) {
        guard duration != maximumDuration else {
            return
        }

        AppLog.keepAlive.notice("最长阻止时间已变更: duration=\(duration.title, privacy: .public)")
        maximumDuration = duration
        defaults.set(duration.rawValue, forKey: Self.maximumDurationKey)

        guard let maximumDurationStartedAt else {
            return
        }

        if let deadline = maximumDurationDeadline(from: maximumDurationStartedAt),
           Date() >= deadline {
            reachMaximumDuration()
            return
        }

        hasReachedMaximumDuration = false
        scheduleMaximumDurationTask()
        reconcileSleepState()
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
            resetMaximumDurationState()
        } else if !newRunningTaskIDs.isEmpty || !resumedRunningTaskIDs.isEmpty {
            restartMaximumDurationPeriod()
        }
        reconcileSleepState()
    }

    private func restartMaximumDurationPeriod() {
        guard isEnabled else {
            return
        }

        maximumDurationStartedAt = Date()
        hasReachedMaximumDuration = false
        if helperStatus == .enabled, !isRefreshingHelper {
            scheduleMaximumDurationTask()
        }
    }

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

        AppLog.keepAlive.notice("开始注册服务")
        do {
            try service.register()
        } catch {
            refreshHelperStatus()
            if !helperStatus.isRegisteredOrAwaitingApproval {
                AppLog.keepAlive.error(
                    "注册服务失败: detail=\(error.localizedDescription, privacy: .public)"
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

        isRefreshingHelper = true
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
                    "更新服务失败: detail=\(registrationError.localizedDescription, privacy: .public)"
                )
                registrationErrorMessage = "更新服务失败"
            }

            isRefreshingHelper = false
            helperRegistrationTask = nil
            if helperStatus == .requiresApproval, opensSystemSettings {
                openSystemSettings()
            }
            reconcileSleepState(force: true)
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
    /// 同值赋值会让菜单面板和设置页反复空转, 所有 @Published 的写入都走这里
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
                "服务状态变化: from=\(String(describing: previousStatus), privacy: .public); to=\(String(describing: currentStatus), privacy: .public)"
            )
        }
        if helperStatus == .enabled {
            // 注册已正常, 只撤回注册类抱怨
            // 操作类结果 (例如重试耗尽) 必须留到下一次操作有结论为止
            assign(nil, to: \.registrationErrorMessage)
        } else if helperStatus != .requiresApproval {
            releaseSleepPrevention()
            resetMaximumDurationState()
        }
    }

    private func reconcileSleepState(force: Bool = false) {
        let wantsSleepDisabled = shouldDisableSleep

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

    private func applySleepDisabled(_ disabled: Bool) {
        guard appliedSleepDisabled != disabled else {
            return
        }

        if disabled {
            let result = systemSleepService.beginPreventingIdleSleep()
            guard result == kIOReturnSuccess else {
                AppLog.keepAlive.error("阻止空闲休眠失败: error=\(result)")
                operationErrorMessage = "阻止空闲休眠失败"
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
            "发送休眠请求: disabled=\(disabled ? 1 : 0); generation=\(generation)"
        )

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
                AppLog.keepAlive.notice(
                    "收到休眠回复: generation=\(generation); error=\(exitCode); sleepDisabled=\(sleepDisabledAfterOperation ? 1 : 0)"
                )
                guard exitCode == 0 else {
                    // invalidateConnection 会连同 assertion 一起收
                    self.invalidateConnection()
                    AppLog.keepAlive.error("切换休眠状态失败: error=\(exitCode)")
                    self.operationErrorMessage = "切换休眠状态失败"
                    self.scheduleRetryIfNeeded(for: disabled)
                    return
                }

                self.cancelRetryTask()
                self.isPreventingSleep = disabled
                self.operationErrorMessage = nil
                if disabled {
                    AppLog.keepAlive.notice("已接管系统休眠")
                    self.canTrustRestoreResult = true
                    self.beginMaximumDurationCountdownIfNeeded()
                } else {
                    self.finishSleepRestore(
                        sleepDisabledAfterOperation: sleepDisabledAfterOperation
                    )
                }
            }
        }
    }

    private func beginMaximumDurationCountdownIfNeeded() {
        if maximumDurationStartedAt == nil {
            maximumDurationStartedAt = Date()
            hasReachedMaximumDuration = false
        }
        scheduleMaximumDurationTask()
    }

    private func scheduleMaximumDurationTask() {
        cancelMaximumDurationTask()

        guard isStarted,
              let maximumDurationStartedAt,
              !hasReachedMaximumDuration else {
            return
        }

        guard let deadline = maximumDurationDeadline(from: maximumDurationStartedAt) else {
            return
        }

        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else {
            reachMaximumDuration()
            return
        }

        maximumDurationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled, let self else {
                return
            }
            maximumDurationTask = nil
            reachMaximumDuration()
        }
    }

    private func reachMaximumDuration() {
        guard maximumDurationStartedAt != nil,
              !hasReachedMaximumDuration else {
            return
        }

        cancelMaximumDurationTask()
        hasReachedMaximumDuration = true
        let durationTitle = maximumDuration.title
        AppLog.keepAlive.notice("已到阻止休眠上限: duration=\(durationTitle, privacy: .public)")
        reconcileSleepState()
    }

    private func finishSleepRestore(sleepDisabledAfterOperation: Bool) {
        // assertion 无论回复可不可信都要释放, 与下面的判断无关
        let idleSleepResult = systemSleepService.endPreventingIdleSleep()
        if idleSleepResult != kIOReturnSuccess {
            AppLog.keepAlive.error("恢复空闲休眠策略失败: error=\(idleSleepResult)")
            operationErrorMessage = "恢复空闲休眠策略失败"
        }

        let sleepDisabled = sleepDisabledAfterOperation ? 1 : 0
        // 连接断过时 helper 可能已自行恢复并清掉哨兵, 这份回复不带实测状态
        // 不能据此补发合盖休眠: 本轮可能压根不是我们禁用的休眠
        guard canTrustRestoreResult else {
            // 这条判断是防止误发强制休眠的唯一屏障, 生效时必须留痕, 否则误判无从追查
            AppLog.keepAlive.notice("跳过恢复处理: 接管期间连接断开")
            return
        }

        AppLog.keepAlive.notice("已恢复系统休眠: SleepDisabled=\(sleepDisabled)")

        let lidStatus = SystemSleepService.currentStatus()
        let shouldRequestSystemSleep = !sleepDisabledAfterOperation
            && lidStatus?.shouldSleepForLidClosure == true

        let lidClosed = lidStatus.map { $0.isLidClosed ? "1" : "0" } ?? "unknown"
        let lidCausesSleep = lidStatus.map { $0.lidClosureCausesSleep ? "1" : "0" } ?? "unknown"

        guard shouldRequestSystemSleep else {
            AppLog.keepAlive.notice(
                "不请求系统休眠: sleepDisabled=\(sleepDisabled); lidClosed=\(lidClosed, privacy: .public); lidCausesSleep=\(lidCausesSleep, privacy: .public)"
            )
            return
        }

        AppLog.keepAlive.notice(
            "请求系统休眠: sleepDisabled=\(sleepDisabled); lidClosed=\(lidClosed, privacy: .public); lidCausesSleep=\(lidCausesSleep, privacy: .public)"
        )
        let result = SystemSleepService.requestSystemSleep()
        if result != kIOReturnSuccess {
            AppLog.keepAlive.error("请求系统休眠失败: error=\(result)")
            operationErrorMessage = "请求系统休眠失败"
        }
    }

    private func resetMaximumDurationState() {
        cancelMaximumDurationTask()
        maximumDurationStartedAt = nil
        assign(false, to: \.hasReachedMaximumDuration)
    }

    private func cancelMaximumDurationTask() {
        maximumDurationTask?.cancel()
        maximumDurationTask = nil
    }

    private func maximumDurationDeadline(from startedAt: Date) -> Date? {
        maximumDuration.timeInterval.map(startedAt.addingTimeInterval)
    }

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
                // 复用统一清理: 连接失效同样要释放 assertion, 否则空闲休眠会被永久阻止
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
        AppLog.keepAlive.notice("已建立服务连接")
        return connection
    }

    private func handleConnectionFailure(_ error: Error) {
        let shouldRetry = requestInFlight || isPreventingSleep
        let desiredSleepDisabled = shouldDisableSleep
        invalidateConnection()
        AppLog.keepAlive.error(
            "连接服务失败: detail=\(error.localizedDescription, privacy: .public)"
        )
        operationErrorMessage = "连接服务失败"
        if shouldRetry {
            scheduleRetryIfNeeded(for: desiredSleepDisabled)
        }
    }

    private func invalidateConnection() {
        requestGeneration &+= 1
        let connection = connection
        self.connection = nil
        connection?.invalidationHandler = nil
        connection?.interruptionHandler = nil
        connection?.invalidate()
        // 无连接时也会走到这里, 只记真的断掉了一条, 避免空转刷屏
        if connection != nil {
            AppLog.keepAlive.notice("服务连接已失效")
        }
        // 所有能让我们在哨兵已删的情况下再发一次恢复请求的路径都汇到这里, 标志清在这里才严密
        canTrustRestoreResult = false
        appliedSleepDisabled = nil
        requestInFlight = false
        releaseSleepPrevention()
    }

    /// assertion 与 isPreventingSleep 同进同退的唯一出口
    /// 两者必须一起收: 只清标志会让菜单栏图标显示成未防休眠, 而这条 assertion 仍在阻止空闲休眠,
    /// 且没有任何后续路径会释放它; 仍需要防休眠时由重试经 applySleepDisabled(true) 重建
    private func releaseSleepPrevention() {
        _ = systemSleepService.endPreventingIdleSleep()
        assign(false, to: \.isPreventingSleep)
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
        isRefreshingHelper = false
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
                "阻止休眠多次失败, 已停止重试: attempts=\(Self.sleepToggleRetryDelays.count)"
            )
            operationErrorMessage = "阻止休眠多次失败, 已停止重试"
            return
        }

        let delay = Self.sleepToggleRetryDelays[retryAttempt]
        retryAttempt += 1
        let attempt = retryAttempt
        AppLog.keepAlive.notice(
            "安排重试: attempt=\(attempt); delay=\(delay.components.seconds)s; disabled=\(disabled ? 1 : 0)"
        )

        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else {
                return
            }
            retryTask = nil
            guard disabled == shouldDisableSleep else {
                reconcileSleepState()
                return
            }
            appliedSleepDisabled = nil
            applySleepDisabled(disabled)
        }
    }

    /// 用户意图 (isEnabled) 与依赖可用性在这里汇合
    /// 依赖不满足只让效果失效, 不回写 isEnabled
    private var shouldDisableSleep: Bool {
        isStarted
            && isEnabled
            && codexHookSettings.isEnabled
            && hasRunningTasks
            && helperStatus == .enabled
            && !isRefreshingHelper
            && !hasReachedMaximumDuration
    }

    private static let enabledKey = "KeepAlive.isEnabled"
    private static let maximumDurationKey = "KeepAlive.maximumContinuousDurationSeconds"
    private static let helperRegistrationFingerprintKey =
        "KeepAlive.helperRegistrationFingerprint"
    private static let helperRegistrationRetryDelays: [Duration] = [
        .milliseconds(500),
        .seconds(1),
        .seconds(2)
    ]
    private static let operationNotPermittedErrorCode = 1

    /// 切换休眠状态失败后的重试节奏, 逐次翻倍
    /// 列表耗尽 (累计约 8.5 分钟) 即放弃: 瞬时抖动能自愈, 权限类故障不会无限重试
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

extension KeepAliveController {
    enum MaximumDuration: Int, CaseIterable, Identifiable {
        case oneHour = 3600
        case twoHours = 7200
        case fourHours = 14400
        case eightHours = 28800
        case twelveHours = 43200
        case twentyFourHours = 86400
        case unlimited = -1

        var id: Int {
            rawValue
        }

        var title: String {
            switch self {
            case .oneHour:
                "1 小时"
            case .twoHours:
                "2 小时"
            case .fourHours:
                "4 小时"
            case .eightHours:
                "8 小时"
            case .twelveHours:
                "12 小时"
            case .twentyFourHours:
                "24 小时"
            case .unlimited:
                "无限制"
            }
        }

        var timeInterval: TimeInterval? {
            self == .unlimited ? nil : TimeInterval(rawValue)
        }
    }

    enum HelperStatus: Equatable {
        case notRegistered
        case enabled
        case requiresApproval
        case notFound

        var isRegisteredOrAwaitingApproval: Bool {
            self == .enabled || self == .requiresApproval
        }

        init(_ status: SMAppService.Status) {
            switch status {
            case .notRegistered:
                self = .notRegistered
            case .enabled:
                self = .enabled
            case .requiresApproval:
                self = .requiresApproval
            case .notFound:
                self = .notFound
            @unknown default:
                self = .notFound
            }
        }
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
