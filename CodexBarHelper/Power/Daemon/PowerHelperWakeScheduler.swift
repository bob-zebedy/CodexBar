import Foundation
import IOKit.pwr_mgt

enum PowerHelperWakeScheduler {
    static let owner = CodexBarPowerHelperIPC.serviceIdentifier + ".auto-reset"

    static func replaceSchedule(with date: Date?) -> IOReturn {
        let cancelResult = cancelOwnedEvents()
        guard cancelResult == kIOReturnSuccess else {
            return cancelResult
        }

        guard let date else {
            return kIOReturnSuccess
        }
        let scheduleResult = IOPMSchedulePowerEvent(
            date as CFDate,
            owner as CFString,
            kIOPMAutoWake as CFString
        )
        guard scheduleResult == kIOReturnSuccess else {
            return scheduleResult
        }

        let events = ownedEvents()
        guard events.count == 1,
              let scheduledDate = events[0][kIOPMPowerEventTimeKey] as? Date,
              abs(scheduledDate.timeIntervalSince(date)) <= verificationTolerance else {
            return kIOReturnError
        }
        return kIOReturnSuccess
    }

    static var ownedEventCount: Int {
        ownedEvents().count
    }

    private static func cancelOwnedEvents() -> IOReturn {
        var firstFailure: IOReturn?
        for event in ownedEvents() {
            guard let eventDate = event[kIOPMPowerEventTimeKey] as? Date else {
                firstFailure = firstFailure ?? kIOReturnBadArgument
                continue
            }

            let result = IOPMCancelScheduledPowerEvent(
                eventDate as CFDate,
                owner as CFString,
                kIOPMAutoWake as CFString
            )
            if result != kIOReturnSuccess,
               result != kIOReturnNotFound {
                firstFailure = firstFailure ?? result
            }
        }

        guard ownedEvents().isEmpty else {
            return firstFailure ?? kIOReturnError
        }
        return kIOReturnSuccess
    }

    private static func ownedEvents() -> [NSDictionary] {
        guard let events = IOPMCopyScheduledPowerEvents()?.takeRetainedValue() else {
            return []
        }

        return (events as NSArray).compactMap { value in
            guard let event = value as? NSDictionary,
                  event[kIOPMPowerEventAppNameKey] as? String == owner,
                  event[kIOPMPowerEventTypeKey] as? String == kIOPMAutoWake else {
                return nil
            }
            return event
        }
    }

    private static let verificationTolerance: TimeInterval = 1
}
