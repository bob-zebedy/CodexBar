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

    private static let assertionName = "CodexBar - Codex activity"

    private var assertionID = IOPMAssertionID(kIOPMNullAssertionID)

    func beginPreventingIdleSleep() -> IOReturn {
        guard assertionID == IOPMAssertionID(kIOPMNullAssertionID) else {
            return kIOReturnSuccess
        }

        var createdAssertionID = IOPMAssertionID(kIOPMNullAssertionID)
        // 名称必须是 ASCII: 含中文时 pmset -g assertions 的 named 会显示成空串, 这条断言就失去了标识
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            Self.assertionName as CFString,
            &createdAssertionID
        )
        if result == kIOReturnSuccess {
            assertionID = createdAssertionID
        }
        return result
    }

    func endPreventingIdleSleep() -> IOReturn {
        guard assertionID != IOPMAssertionID(kIOPMNullAssertionID) else {
            return kIOReturnSuccess
        }

        let result = IOPMAssertionRelease(assertionID)
        if result == kIOReturnSuccess || result == kIOReturnNotFound {
            assertionID = IOPMAssertionID(kIOPMNullAssertionID)
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
