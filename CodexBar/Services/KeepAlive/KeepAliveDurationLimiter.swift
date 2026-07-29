import Combine
import Foundation
import os

/// 防休眠的时长上限计时
/// 累计的是真正挡住休眠的那段时间: begin 起表, pause 收表, 收表之后机器睡着或被低电量拦下都不算
/// 时钟用 SuspendingClock 而不是 Date: 后者受系统时间调整影响, 且系统睡眠期间照走
/// hasReached 是粘滞标志: 累计只增不减, 到期之后每一秒都还成立
/// 只有重新开始计时的入口能清除它, 这些清除全部收在 clearReached 里
/// 低电量那条是纯条件判定, 不要照抄这里的粘滞写法
@MainActor
final class KeepAliveDurationLimiter: ObservableObject {
    typealias Duration = KeepAliveController.MaximumDuration

    @Published private(set) var duration: Duration
    @Published private(set) var hasReached = false

    /// 状态变化后需要重新求值一次防休眠条件, 参数是这次变化的来源
    /// begin pause restart reset 不走这里: 它们的调用方本来就会紧接着求值
    var onStateChanged: ((LogTrigger) -> Void)?

    private let defaults: UserDefaults
    private var task: Task<Void, Never>?
    /// 已经收表的累计时长
    private var accumulated: TimeInterval = 0
    /// 当前这一段的起点, nil 表示没在累加
    private var runningSince: SuspendingClock.Instant?
    /// 避免 stop 之后在途回调又把计时器支起来
    private var isRunning = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        duration = (defaults.object(forKey: Self.durationKey) as? Int)
            .flatMap(Duration.init(rawValue:)) ?? .twelveHours
    }

    func start() {
        isRunning = true
    }

    func stop() {
        isRunning = false
        reset()
    }

    func setDuration(_ duration: Duration) {
        guard duration != self.duration else {
            return
        }

        AppLog.keepAlive.notice("KeepAlive 防休眠时间上限变更: threshold=\(duration.loggedHours)")
        self.duration = duration
        defaults.set(duration.rawValue, forKey: Self.durationKey)

        // 这一轮没累计过就没有可解除的状态, 条件没变也就不必让外面重新求值
        guard hasAccumulated else {
            return
        }

        // 走 fireReached 而不是直接 markReached: 这一轮可能已经达过上限
        // 把上限调大但仍然不够时不该再记一条已达上限, 也不该重复通知外面
        if let limit = duration.timeInterval, elapsed >= limit {
            fireReached()
            return
        }

        clearReached()
        schedule()
        onStateChanged?(.settings)
    }

    /// 防休眠真正生效后起表; 已经在走就保持这一段不变
    func begin() {
        if runningSince == nil {
            runningSince = .now
            clearReached()
        }
        schedule()
    }

    /// 防休眠解除时收表, 把这一段并进累计值
    /// 收表之后的时间一律不算: 机器睡着, 低电量拦着, helper 断开都不该占用户的上限
    func pause() {
        guard let runningSince else {
            return
        }

        accumulated += TimeInterval(runningSince.duration(to: .now))
        self.runningSince = nil
        cancelTask()
    }

    /// 有新任务或等待任务恢复运行时重新计时
    /// isPreventingSleep 由调用方给出: 还没真正挡住休眠时只清零, 等 begin 起表
    func restart(isPreventingSleep: Bool) {
        cancelTask()
        accumulated = 0
        clearReached()
        runningSince = isPreventingSleep ? .now : nil
        guard isPreventingSleep else {
            return
        }

        schedule()
    }

    func reset() {
        cancelTask()
        runningSince = nil
        accumulated = 0
        clearReached()
    }

    /// @Published 在 willSet 无条件发信号, 而这里的 objectWillChange 被转发进 KeepAliveController
    /// 同值赋值会让整个高级设置页和活动卡片跟着空转, 所以 hasReached 的清零都走这里
    private func clearReached() {
        guard hasReached else {
            return
        }

        hasReached = false
    }

    /// 这一轮已经挡住休眠的总时长, 含当前还没收表的这一段
    private var elapsed: TimeInterval {
        guard let runningSince else {
            return accumulated
        }

        return accumulated + TimeInterval(runningSince.duration(to: .now))
    }

    /// 这一轮有没有真的累计过, 没累计过就没有可解除的上限状态
    private var hasAccumulated: Bool {
        runningSince != nil || accumulated > 0
    }

    private func schedule() {
        cancelTask()

        guard isRunning,
              runningSince != nil,
              !hasReached,
              let limit = duration.timeInterval else {
            return
        }

        let remaining = limit - elapsed
        guard remaining > 0 else {
            fireReached()
            return
        }

        // 计时器同样走 SuspendingClock, 否则机器睡一夜醒来会当场判定到期
        let deadline = SuspendingClock.Instant.now.advanced(by: .seconds(remaining))
        task = Task { @MainActor [weak self] in
            try? await Task.sleep(until: deadline, clock: SuspendingClock())
            guard !Task.isCancelled, let self else {
                return
            }
            task = nil
            fireReached()
        }
    }

    private func fireReached() {
        guard hasAccumulated, !hasReached else {
            return
        }

        markReached()
        onStateChanged?(.limitReached)
    }

    private func markReached() {
        cancelTask()
        hasReached = true
        let thresholdHours = duration.loggedHours
        AppLog.keepAlive.notice("KeepAlive 已达上限: threshold=\(thresholdHours)")
    }

    private func cancelTask() {
        task?.cancel()
        task = nil
    }

    private static let durationKey = "KeepAlive.maximumContinuousDurationSeconds"
}
