import Foundation
import Synchronization

struct PmsetResult {
    let exitCode: Int32
    let output: String
}

struct PowerHelperSleepOperations {
    var read: () -> (result: PmsetResult, value: Bool?)
    var write: (Bool) -> PmsetResult

    static var system: Self {
        Self(read: PmsetRunner.currentSleepDisabled, write: PmsetRunner.setSleepDisabled)
    }
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

    /// 所有调用均由 Power Helper 状态队列串行执行, 未退出的旧写入不能与新操作重叠
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
