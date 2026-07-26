import Foundation
import IOKit
import IOKit.pwr_mgt

@MainActor
final class SystemSleepService {
    struct Status: Equatable, Sendable {
        let isLidClosed: Bool
        let lidClosureCausesSleep: Bool

        var shouldSleepForLidClosure: Bool {
            isLidClosed && lidClosureCausesSleep
        }
    }

    private static let idleSleepAssertionName = "CodexBar - Codex task running"

    private var idleSleepAssertionID = IOPMAssertionID(kIOPMNullAssertionID)

    func beginPreventingIdleSleep() -> IOReturn {
        guard idleSleepAssertionID == IOPMAssertionID(kIOPMNullAssertionID) else {
            return kIOReturnSuccess
        }

        var assertionID = IOPMAssertionID(kIOPMNullAssertionID)
        // 名称必须是 ASCII: 含中文时 pmset -g assertions 会把 named 显示成空串,
        // 这条断言在诊断输出里就失去了标识, 只能靠进程名辨认
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            Self.idleSleepAssertionName as CFString,
            &assertionID
        )
        if result == kIOReturnSuccess {
            idleSleepAssertionID = assertionID
        }
        return result
    }

    func endPreventingIdleSleep() -> IOReturn {
        guard idleSleepAssertionID != IOPMAssertionID(kIOPMNullAssertionID) else {
            return kIOReturnSuccess
        }

        let result = IOPMAssertionRelease(idleSleepAssertionID)
        if result == kIOReturnSuccess || result == kIOReturnNotFound {
            idleSleepAssertionID = IOPMAssertionID(kIOPMNullAssertionID)
        }
        return result == kIOReturnNotFound ? kIOReturnSuccess : result
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
