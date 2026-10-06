import Foundation
import IOKit.pwr_mgt
import Synchronization

struct PmsetResult {
    let exitCode: Int32
    let output: String
}

// MARK: - pmset 调用

enum PmsetRunner {
    static func setSleepDisabled(_ disabled: Bool) -> PmsetResult {
        run(arguments: ["-a", "disablesleep", disabled ? "1" : "0"])
    }

    static func currentSleepDisabled() -> (result: PmsetResult, value: Bool?) {
        let result = run(arguments: ["-g"])
        return (result, parseSleepDisabled(from: result.output))
    }

    /// 所有调用均由 helper 状态队列串行执行, 未退出的旧写入不能与新操作重叠
    private static let unfinished = Mutex<Process?>(nil)

    private static func run(arguments: [String]) -> PmsetResult {
        unfinished.withLock { process in
            guard process?.isRunning != true else {
                return PmsetResult(exitCode: -1, output: "previous pmset process has not exited")
            }
            let result = BoundedProcess.run(executable: URL(fileURLWithPath: "/usr/bin/pmset"), arguments: arguments)
            process = result.runningProcess
            return PmsetResult(exitCode: result.exitCode, output: result.timedOut ? "pmset timed out: " + result.output : result.output)
        }
    }

    private static func parseSleepDisabled(from output: String) -> Bool? {
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2, fields[0] == "SleepDisabled" else {
                continue
            }
            switch fields[1] {
            case "0":
                return false
            case "1":
                return true
            default:
                return nil
            }
        }
        // pmset 只在 disablesleep=1 时输出 SleepDisabled, 字段缺失表示默认值 0
        return false
    }
}

enum AutoResetWakeScheduler {
    static let owner = CodexBarHelperIPC.machServiceName + ".auto-reset"

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
