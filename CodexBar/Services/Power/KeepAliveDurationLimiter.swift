import Combine
import Foundation
import os

/// 累计防睡眠生效时长, 暂停期间不计入上限
/// 使用 SuspendingClock 排除系统时间调整和睡眠时长的影响
/// 达到上限后保留 hasReached 状态, 由新计时周期或上限调整解除
@MainActor
final class KeepAliveDurationLimiter: ObservableObject {
    typealias Duration = KeepAliveController.MaximumDuration

    @Published private(set) var duration: Duration
    @Published private(set) var hasReached = false

    /// 状态变化后需要重新求值一次防睡眠条件, 参数是这次变化的来源
    /// begin pause restart reset 的调用方会立即重新求值, 无需触发此回调
    var onStateChanged: ((LogTrigger) -> Void)?

    private let defaults: UserDefaults
    private var task: Task<Void, Never>?
    /// 已结束计时段的累计时长
    private var accumulated: TimeInterval = 0
    /// 当前这一段的起点, nil 表示没在累加
    private var runningSince: SuspendingClock.Instant?
    /// 防止在途回调在 stop 后重新启动计时器
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

        AppLog.keepAlive.notice("KeepAlive 防睡眠时间上限变更: threshold=\(duration.loggedHours)")
        self.duration = duration
        defaults.set(duration.rawValue, forKey: Self.durationKey)

        // 本轮未计时则没有可解除的上限状态, 无需触发外部重新求值
        guard hasAccumulated else {
            return
        }

        // fireReached 会检查本轮是否已达上限, 避免调大后仍超限时重复记日志和通知外部
        if let limit = duration.timeInterval, elapsed >= limit {
            fireReached()
            return
        }

        clearReached()
        schedule()
        onStateChanged?(.settings)
    }

    /// 防睡眠生效后开始计时, 已在计时则保留当前段
    func begin() {
        if runningSince == nil {
            runningSince = .now
            clearReached()
        }
        schedule()
    }

    /// 防睡眠解除时停止计时, 将当前段计入累计值
    /// 系统睡眠, 低电量阻断或 Power Helper 断开期间不累计时长
    func pause() {
        guard let runningSince else {
            return
        }

        accumulated += TimeInterval(runningSince.duration(to: .now))
        self.runningSince = nil
        cancelTask()
    }

    /// 有新任务或等待任务恢复运行时重新计时
    /// 调用方传入 isPreventingSleep, 尚未生效时只清零, 等 begin 开始计时
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

    /// objectWillChange 会转发给 KeepAliveController, @Published 同值赋值也会刷新高级设置页和活动卡片
    /// 重置 hasReached 时跳过同值写入
    private func clearReached() {
        guard hasReached else {
            return
        }

        hasReached = false
    }

    /// 本轮防睡眠总时长, 包括当前计时段
    private var elapsed: TimeInterval {
        guard let runningSince else {
            return accumulated
        }

        return accumulated + TimeInterval(runningSince.duration(to: .now))
    }

    /// 本轮是否累计过时长, 未累计则没有可解除的上限状态
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

        // 计时器也使用 SuspendingClock, 避免将系统睡眠时间计入上限
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
