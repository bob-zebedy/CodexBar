import Darwin
import Foundation

/// 子进程关闭结果, 让调用方区分正常退出和强杀兜底
nonisolated enum ProcessTerminationResult: Equatable {
    case alreadyExited
    case terminated
    case killed
    case stillRunning
}

/// 先 terminate, 超时后 SIGKILL 的统一收口
nonisolated enum ProcessTermination {
    private static let pollInterval: TimeInterval = 0.02

    static func terminate(
        _ process: Process,
        gracefulTimeout: TimeInterval,
        killTimeout: TimeInterval
    ) -> ProcessTerminationResult {
        guard process.isRunning else {
            return .alreadyExited
        }

        process.terminate()
        if waitUntilExit(process, timeout: gracefulTimeout) {
            return .terminated
        }

        kill(process.processIdentifier, SIGKILL)
        if waitUntilExit(process, timeout: killTimeout) {
            return .killed
        }

        return .stillRunning
    }

    private static func waitUntilExit(_ process: Process, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(max(timeout, 0))
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: pollInterval)
        }

        return !process.isRunning
    }
}
