import Foundation
import IOKit
import IOKit.pwr_mgt
import os

@MainActor
final class SystemSleepService {
    struct Status: Equatable, Sendable {
        let isLidClosed: Bool
        let lidClosureCausesSleep: Bool

        var shouldSleepForLidClosure: Bool {
            isLidClosed && lidClosureCausesSleep
        }
    }

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

        mutating func begin() -> IOReturn {
            guard !isActive else {
                return kIOReturnSuccess
            }

            var createdAssertionID = IOPMAssertionID(kIOPMNullAssertionID)
            let result = IOPMAssertionCreateWithName(
                type,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                name,
                &createdAssertionID
            )
            if result == kIOReturnSuccess {
                id = createdAssertionID
            }
            return result
        }

        mutating func end() -> IOReturn {
            guard isActive else {
                return kIOReturnSuccess
            }

            let result = IOPMAssertionRelease(id)
            if result == kIOReturnSuccess || result == kIOReturnNotFound {
                id = IOPMAssertionID(kIOPMNullAssertionID)
            }
            return result == kIOReturnNotFound ? kIOReturnSuccess : result
        }
    }

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

    /// 认节拍而不是认断言: 释放失败的那一轮会留下"断言还在但节拍已停", 认断言会把它当成还留着屏幕,
    /// 之后再要留住时被判定成无事可做, 于是屏幕不睡而屏保照常启动
    /// 反过来"节拍在而断言不在"不可达, 节拍只在断言建立成功之后才起
    var isPreventingDisplaySleep: Bool {
        userActivityTask != nil
    }

    init(sleepAssertionName: String = "CodexBar - Codex activity") {
        sleepAssertion = Assertion(
            type: kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            name: sleepAssertionName as CFString
        )
    }

    func beginPreventingIdleSleep() -> IOReturn {
        sleepAssertion.begin()
    }

    func endPreventingIdleSleep() -> IOReturn {
        sleepAssertion.end()
    }

    /// 屏幕不睡与不进屏保是两件事, 后者要靠节拍声明用户活动, 所以两者收在同一对方法里
    func beginPreventingDisplaySleep() -> IOReturn {
        let result = displayAssertion.begin()
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
        if userActivityAssertionID != IOPMAssertionID(kIOPMNullAssertionID) {
            IOPMAssertionRelease(userActivityAssertionID)
            userActivityAssertionID = IOPMAssertionID(kIOPMNullAssertionID)
        }
        return displayAssertion.end()
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

    /// 逐次声明不记日志, 只在成败翻转时记一条: 这是 30 秒一拍的高频路径, 持续失败会把日志刷满
    private func declareUserActivity() {
        let result = IOPMAssertionDeclareUserActivity(
            displayAssertion.name,
            kIOPMUserActiveLocal,
            &userActivityAssertionID
        )
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

    static func currentStatus() -> Status? {
        let rootDomain = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPMrootDomain")
        )
        guard rootDomain != IO_OBJECT_NULL else {
            return nil
        }
        defer {
            IOObjectRelease(rootDomain)
        }

        guard let isLidClosed = booleanProperty("AppleClamshellState", of: rootDomain),
              let lidClosureCausesSleep = booleanProperty(
                  "AppleClamshellCausesSleep",
                  of: rootDomain
              ) else {
            return nil
        }
        return Status(
            isLidClosed: isLidClosed,
            lidClosureCausesSleep: lidClosureCausesSleep
        )
    }

    static func requestSystemSleep() -> IOReturn {
        let connection = IOPMFindPowerManagement(mach_port_t(MACH_PORT_NULL))
        guard connection != IO_OBJECT_NULL else {
            return kIOReturnNotFound
        }
        defer {
            IOServiceClose(connection)
        }
        return IOPMSleepSystem(connection)
    }

    /// 节拍取得比系统能设的最短屏保等待时间 (1 分钟) 小
    private static let userActivityInterval = Duration.seconds(30)

    private static func booleanProperty(
        _ key: String,
        of rootDomain: io_service_t
    ) -> Bool? {
        guard let value = IORegistryEntryCreateCFProperty(
            rootDomain,
            key as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() else {
            return nil
        }
        return (value as? NSNumber)?.boolValue
    }
}
