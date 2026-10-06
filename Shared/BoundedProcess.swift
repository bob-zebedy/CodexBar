import Darwin
import Foundation
import Synchronization

/// 同步入口只能在后台执行, 异步入口将阻塞 I/O 放到独立队列
nonisolated enum BoundedProcess {
    enum OutputMode: Sendable {
        case merged
        case separate
    }

    struct Configuration: Sendable {
        var outputMode: OutputMode = .merged
        var gracefulTimeout: TimeInterval = 0.25
        var killTimeout: TimeInterval = 0.5
        var drainTimeout: TimeInterval = 0.25
        /// 指定时执行与输出排空共用期限, 并计入排队和启动耗时
        var deadline: ContinuousClock.Instant?
    }

    enum Completion: Equatable, Sendable {
        case exited
        case launchFailed(String)
        case ioFailed(Int32)
        case invalidConfiguration
        case timedOut
        case cancelled
    }

    struct Output: Sendable {
        var data = Data()
        var isTruncated = false
        var reachedEOF = false
    }

    struct Result: Sendable {
        let completion: Completion
        var standardOutput = Output(reachedEOF: true)
        var standardError = Output(reachedEOF: true)
        var terminationStatus: Int32?
        var terminationReason: Process.TerminationReason?
        /// 返回后由调用方接管, 内核不再访问该进程
        var runningProcess: Process?

        var exitCode: Int32 {
            completion == .exited ? terminationStatus ?? -1 : -1
        }

        var timedOut: Bool {
            completion == .timedOut
        }

        var output: String {
            if case let .launchFailed(message) = completion {
                return message
            }
            // helper 和后台服务保留替换无效 UTF-8 字节的展示行为
            // swiftlint:disable:next optional_data_string_conversion
            return String(decoding: standardOutput.data, as: UTF8.self)
        }
    }

    private static let workers = DispatchQueue(label: "CodexBar.process", qos: .userInitiated, attributes: .concurrent)

    static func run(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval = 2.5,
        environment: [String: String]? = nil,
        configuration: Configuration = Configuration()
    ) -> Result {
        execute(executable: executable, arguments: arguments, timeout: timeout, environment: environment, configuration: configuration) {
            Task.isCancelled
        }
    }

    static func runAsync(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval = 2.5,
        environment: [String: String]? = nil,
        configuration: Configuration = Configuration()
    ) async -> Result {
        let cancelled = Mutex(false)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                workers.async {
                    let result = execute(
                        executable: executable, arguments: arguments, timeout: timeout,
                        environment: environment, configuration: configuration,
                        isCancelled: { cancelled.withLock { $0 } }
                    )
                    // 只有执行者完成清理后才能返回, 取消回调不接触进程或 continuation
                    continuation.resume(returning: result)
                }
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
    }

    private static func execute(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval,
        environment: [String: String]?,
        configuration: Configuration,
        isCancelled: () -> Bool
    ) -> Result {
        guard !isCancelled() else { return Result(completion: .cancelled) }
        guard [timeout, configuration.gracefulTimeout, configuration.killTimeout, configuration.drainTimeout].allSatisfy(\.isFinite) else {
            return Result(completion: .invalidConfiguration)
        }
        if let deadline = configuration.deadline, ContinuousClock.now >= deadline {
            return Result(completion: .timedOut)
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        let readers = configuration.outputMode == .merged ? [PipeReader()] : [PipeReader(), PipeReader()]
        defer { readers.forEach { $0.close() } }
        for reader in readers {
            if let error = reader.configure() {
                return Result(completion: .ioFailed(error))
            }
        }
        process.standardOutput = readers[0].pipe
        process.standardError = readers.last!.pipe
        guard !isCancelled() else { return Result(completion: .cancelled) }
        do {
            try process.run()
        } catch {
            return Result(completion: .launchFailed(error.localizedDescription))
        }
        readers.forEach { $0.closeWriter() }
        let deadline = configuration.deadline ?? ContinuousClock.now.advanced(by: .seconds(max(0, timeout)))
        var execution = Execution(process: process, readers: readers, configuration: configuration, deadline: deadline)
        return execution.wait(isCancelled: isCancelled)
    }

    private enum Phase {
        case running
        case terminating(until: ContinuousClock.Instant)
        case killing(until: ContinuousClock.Instant)
        case draining(until: ContinuousClock.Instant)
    }

    private struct Execution {
        let process: Process
        let readers: [PipeReader]
        let configuration: Configuration
        let deadline: ContinuousClock.Instant
        var phase = Phase.running
        var completion: Completion?

        mutating func wait(isCancelled: () -> Bool) -> Result {
            while true {
                for reader in readers {
                    if let error = reader.drain(), completion == nil || completion == .exited {
                        completion = .ioFailed(error)
                    }
                }
                let now = ContinuousClock.now
                if !process.isRunning {
                    if case .draining = phase {} else {
                        completion = completion ?? .exited
                        var end = now.advanced(by: .seconds(max(0, configuration.drainTimeout)))
                        if configuration.deadline != nil {
                            end = min(end, deadline)
                        }
                        phase = .draining(until: end)
                        // 退出可能发生在本轮读取之后, 再读取一次已到达的尾部字节
                        continue
                    }
                }

                switch phase {
                case .running:
                    if completion == nil {
                        if now >= deadline {
                            completion = .timedOut
                        } else if isCancelled() {
                            completion = .cancelled
                        }
                    }
                    if completion != nil {
                        phase = .terminating(until: now.advanced(by: .seconds(max(0, configuration.gracefulTimeout))))
                        if process.isRunning {
                            process.terminate()
                        }
                    }
                case let .terminating(end):
                    if now >= end {
                        phase = .killing(until: now.advanced(by: .seconds(max(0, configuration.killTimeout))))
                        if process.isRunning {
                            kill(process.processIdentifier, SIGKILL)
                        }
                    }
                case let .killing(end):
                    if now >= end {
                        return result()
                    }
                case let .draining(end):
                    if readers.allSatisfy(\.output.reachedEOF) || now >= end || isCancelled() {
                        return result()
                    }
                }
                pause()
            }
        }

        private func pause() {
            let next: ContinuousClock.Instant = switch phase {
            case .running: deadline
            case let .terminating(end), let .killing(end), let .draining(end): end
            }
            let remaining = ContinuousClock.now.duration(to: next)
            if remaining > .zero {
                let duration = min(remaining, .milliseconds(10)).components
                Thread.sleep(forTimeInterval: Double(duration.seconds) + Double(duration.attoseconds) / 1e18)
            }
        }

        private func result() -> Result {
            let running = process.isRunning
            return Result(
                completion: completion ?? .exited,
                standardOutput: readers[0].output,
                standardError: readers.count == 2 ? readers[1].output : Output(reachedEOF: true),
                terminationStatus: running ? nil : process.terminationStatus,
                terminationReason: running ? nil : process.terminationReason,
                runningProcess: running ? process : nil
            )
        }
    }

    /// 仅由执行线程访问, 字节上限与每轮读取次数分别限制内存和取消延迟
    private final class PipeReader {
        let pipe = Pipe()
        var output = Output()
        private var writerClosed = false
        private var readFailed = false
        private var buffer = [UInt8](repeating: 0, count: 8192)

        func configure() -> Int32? {
            let descriptor = pipe.fileHandleForReading.fileDescriptor
            let flags = fcntl(descriptor, F_GETFL)
            guard flags != -1, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != -1 else { return errno }
            return nil
        }

        func drain() -> Int32? {
            guard !output.reachedEOF, !readFailed else { return nil }
            for _ in 0 ..< 8 {
                let count = Darwin.read(pipe.fileHandleForReading.fileDescriptor, &buffer, buffer.count)
                if count > 0 {
                    let kept = min(count, 65536 - output.data.count)
                    output.data.append(contentsOf: buffer.prefix(kept))
                    if kept < count {
                        output.isTruncated = true
                    }
                } else if count == 0 {
                    output.reachedEOF = true
                    return nil
                } else {
                    let code = errno
                    if code == EINTR {
                        continue
                    }
                    if code == EAGAIN || code == EWOULDBLOCK {
                        return nil
                    }
                    readFailed = true
                    return code
                }
            }
            return nil
        }

        func closeWriter() {
            guard !writerClosed else { return }
            writerClosed = true
            try? pipe.fileHandleForWriting.close()
        }

        func close() {
            closeWriter()
            try? pipe.fileHandleForReading.close()
        }
    }
}
