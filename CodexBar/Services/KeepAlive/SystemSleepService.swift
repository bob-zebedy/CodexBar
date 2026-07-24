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

    private var idleSleepAssertionID = IOPMAssertionID(kIOPMNullAssertionID)

    func beginPreventingIdleSleep() -> IOReturn {
        guard idleSleepAssertionID == IOPMAssertionID(kIOPMNullAssertionID) else {
            return kIOReturnSuccess
        }

        var assertionID = IOPMAssertionID(kIOPMNullAssertionID)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Codex 任务正在运行" as CFString,
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
