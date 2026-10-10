import Foundation
import IOKit
import IOKit.pwr_mgt
import os

@MainActor
final class SystemSleepService {
    /// 两条断言只差类型与名字, 持有和释放的规则完全一样
    /// 名称必须是 ASCII: 含中文时 pmset -g assertions 的 named 会显示成空串, 断言就失去了标识
    private struct Assertion {
        let type: CFString
        let name: CFString
        private var id = IOPMAssertionID(kIOPMNullAssertionID)

        init(type: CFString, name: CFString) {
            self.type = type
            self.name = name
        }

        var isActive: Bool {
            id != IOPMAssertionID(kIOPMNullAssertionID)
        }

        mutating func begin(create: (CFString, CFString, inout IOPMAssertionID) -> IOReturn) -> IOReturn {
            guard !isActive else {
                return kIOReturnSuccess
            }

            var createdAssertionID = IOPMAssertionID(kIOPMNullAssertionID)
            let result = create(type, name, &createdAssertionID)
            if result == kIOReturnSuccess {
                id = createdAssertionID
            }
            return result
        }

        mutating func end(release: (IOPMAssertionID) -> IOReturn) -> IOReturn {
            guard isActive else {
                return kIOReturnSuccess
            }

            let result = release(id)
            if result == kIOReturnSuccess || result == kIOReturnNotFound {
                id = IOPMAssertionID(kIOPMNullAssertionID)
            }
            return result == kIOReturnNotFound ? kIOReturnSuccess : result
        }
    }

    private let createAssertion: (CFString, CFString, inout IOPMAssertionID) -> IOReturn
    private let releaseAssertion: (IOPMAssertionID) -> IOReturn
    private let declareActivity: (CFString, inout IOPMAssertionID) -> IOReturn
    private let displayReleaseRetryDelays: [Duration]
    private var displayReleaseRetryTask: Task<Void, Never>?
    private var sleepAssertion: Assertion
    private var displayAssertion = Assertion(
        type: kIOPMAssertionTypeNoDisplaySleep as CFString,
        name: "CodexBar - Codex activity display" as CFString
    )
    /// 复用同一个 ID 重新触发, 每次传 null 会新建一条, pmset -g assertions 里会堆成一串同名断言
    private var userActivityAssertionID = IOPMAssertionID(kIOPMNullAssertionID)
    private var userActivityTask: Task<Void, Never>?
    /// 上一拍声明成功没有, 用来只在成败翻转时记日志; 每轮起表时归位成"成功"
    private var didDeclareUserActivity = true

    var isPreventingDisplaySleep: Bool {
        displayAssertion.isActive && userActivityTask != nil
    }

    var hasDisplaySleepResources: Bool {
        displayAssertion.isActive || userActivityTask != nil
            || userActivityAssertionID != IOPMAssertionID(kIOPMNullAssertionID)
    }

    init(
        sleepAssertionName: String = "CodexBar - Codex activity",
        createAssertion: @escaping (CFString, CFString, inout IOPMAssertionID) -> IOReturn = { type, name, id in
            IOPMAssertionCreateWithName(type, IOPMAssertionLevel(kIOPMAssertionLevelOn), name, &id)
        },
        releaseAssertion: @escaping (IOPMAssertionID) -> IOReturn = { IOPMAssertionRelease($0) },
        declareActivity: @escaping (CFString, inout IOPMAssertionID) -> IOReturn = { name, id in
            IOPMAssertionDeclareUserActivity(name, kIOPMUserActiveLocal, &id)
        },
        displayReleaseRetryDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(5)]
    ) {
        self.createAssertion = createAssertion
        self.releaseAssertion = releaseAssertion
        self.declareActivity = declareActivity
        self.displayReleaseRetryDelays = displayReleaseRetryDelays
        sleepAssertion = Assertion(
            type: kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            name: sleepAssertionName as CFString
        )
    }

    func beginPreventingIdleSleep() -> IOReturn {
        sleepAssertion.begin(create: createAssertion)
    }

    func endPreventingIdleSleep() -> IOReturn {
        sleepAssertion.end(release: releaseAssertion)
    }

    /// 屏幕不睡与不进屏保是两件事, 后者要靠节拍声明用户活动, 所以两者收在同一对方法里
    func beginPreventingDisplaySleep() -> IOReturn {
        displayReleaseRetryTask?.cancel()
        displayReleaseRetryTask = nil
        let result = displayAssertion.begin(create: createAssertion)
        guard result == kIOReturnSuccess else {
            return result
        }

        startUserActivityTicks()
        return result
    }

    func endPreventingDisplaySleep() -> IOReturn {
        userActivityTask?.cancel()
        userActivityTask = nil
        didDeclareUserActivity = true
        displayReleaseRetryTask?.cancel()
        displayReleaseRetryTask = nil
        let result = releaseDisplayAssertions()
        if result != kIOReturnSuccess {
            scheduleDisplayReleaseRetry()
        }
        return result
    }

    private func releaseDisplayAssertions() -> IOReturn {
        var activityResult = kIOReturnSuccess
        if userActivityAssertionID != IOPMAssertionID(kIOPMNullAssertionID) {
            activityResult = releaseAssertion(userActivityAssertionID)
            if activityResult == kIOReturnSuccess || activityResult == kIOReturnNotFound {
                userActivityAssertionID = IOPMAssertionID(kIOPMNullAssertionID)
                activityResult = kIOReturnSuccess
            }
        }
        let displayResult = displayAssertion.end(release: releaseAssertion)
        return displayResult == kIOReturnSuccess ? activityResult : displayResult
    }

    private func scheduleDisplayReleaseRetry() {
        displayReleaseRetryTask = Task { @MainActor [weak self, delays = displayReleaseRetryDelays] in
            for delay in delays {
                do { try await Task.sleep(for: delay) } catch { return }
                guard let self, !Task.isCancelled else { return }
                if releaseDisplayAssertions() == kIOReturnSuccess {
                    displayReleaseRetryTask = nil
                    AppLog.keepAlive.notice("显示断言已释放: reason=retry")
                    return
                }
            }
            self?.displayReleaseRetryTask = nil
            AppLog.keepAlive.error("显示断言释放重试已耗尽")
        }
    }

    /// 屏保与闲置锁屏跟的是系统 idle 计时, 显示断言只保证屏幕不睡, 挡不住它们
    private func startUserActivityTicks() {
        // 断言已在而节拍断了的那一轮会重新走到这里, 不先收掉旧的会留下一个空转的 Task
        userActivityTask?.cancel()
        userActivityTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else {
                    return
                }

                declareUserActivity()
                try? await Task.sleep(for: Self.userActivityInterval)
            }
        }
    }

    /// 定期声明用户活动时只记录成败变化, 避免持续失败产生重复日志
    private func declareUserActivity() {
        let result = declareActivity(displayAssertion.name, &userActivityAssertionID)
        let didSucceed = result == kIOReturnSuccess
        defer {
            didDeclareUserActivity = didSucceed
        }
        guard didSucceed != didDeclareUserActivity else {
            return
        }

        if didSucceed {
            AppLog.keepAlive.notice("显示断言声明用户活动已恢复")
        } else {
            AppLog.keepAlive.error("显示断言声明用户活动失败: code=\(result)")
        }
    }

    /// 节拍取得比系统能设的最短屏保等待时间 (1 分钟) 小
    private static let userActivityInterval = Duration.seconds(30)
}
