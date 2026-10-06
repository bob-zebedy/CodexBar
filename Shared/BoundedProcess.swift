import Darwin
import Foundation

/// 同步调用必须在非主队列执行, 管道读取和进程终止均有期限
nonisolated enum BoundedProcess {
    struct Result {
        let exitCode: Int32
        let output: String
        let timedOut: Bool
        let runningProcess: Process?
    }

    static func run(executable: URL, arguments: [String], timeout: TimeInterval = 2.5) -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch {
            return Result(exitCode: -1, output: error.localizedDescription, timedOut: false, runningProcess: nil)
        }
        pipe.fileHandleForWriting.closeFile()
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
        defer { pipe.fileHandleForReading.closeFile() }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(max(0, timeout)))
        let killDeadline = deadline.advanced(by: .milliseconds(250))
        let end = killDeadline.advanced(by: .milliseconds(500))
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        var terminated = false
        var killed = false
        while true {
            // 每轮读取有界, 持续输出不能阻止检查超时
            for _ in 0 ..< 8 {
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                guard count > 0 else { break }
                if output.count < 65536 {
                    output.append(contentsOf: buffer.prefix(min(count, 65536 - output.count)))
                }
            }
            if !process.isRunning {
                break
            }
            if clock.now >= deadline, !terminated {
                terminated = true
                process.terminate()
            }
            if clock.now >= killDeadline, !killed {
                killed = true
                kill(process.processIdentifier, SIGKILL)
            }
            if clock.now >= end {
                break
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        let running = process.isRunning
        return Result(
            exitCode: terminated || running ? -1 : process.terminationStatus,
            output: String(decoding: output, as: UTF8.self),
            timedOut: terminated,
            runningProcess: running ? process : nil
        )
    }
}
