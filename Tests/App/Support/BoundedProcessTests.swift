import Darwin
import Foundation
import Testing

struct BoundedProcessTests {
    @Test nonisolated func preservesArgumentsEnvironmentAndMergedOutput() {
        let result = BoundedProcess.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf '%s' \"$1\"; printf '%s' \"$PROCESS_TEST_VALUE\" >&2; exit 7", "test", "a $value `literal`"],
            environment: ["PROCESS_TEST_VALUE": " with spaces"]
        )
        #expect(result.exitCode == 7)
        #expect(result.output == "a $value `literal` with spaces")
        #expect(!result.timedOut)
        #expect(result.runningProcess == nil)
    }

    @Test nonisolated func missingExecutableDoesNotReportTimeout() {
        let result = BoundedProcess.run(
            executable: URL(fileURLWithPath: "/tmp/\(UUID().uuidString)/missing"), arguments: []
        )
        #expect(result.exitCode == -1)
        #expect(!result.output.isEmpty)
        #expect(!result.timedOut)
        #expect(result.runningProcess == nil)
    }

    @Test func cancellationTerminatesOnlyTheCommandPromptly() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let task = Task.detached {
            BoundedProcess.run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "trap '' TERM; printf ready > \"$PROCESS_TEST_DIR/ready\"; while :; do :; done"],
                timeout: 15, environment: ["PROCESS_TEST_DIR": directory.url.path]
            )
        }
        defer { task.cancel() }
        try await directory.waitForFile("ready")
        let started = ContinuousClock.now
        task.cancel()
        let result = await task.value
        #expect(result.exitCode != 0)
        #expect(!result.timedOut)
        #expect(result.runningProcess == nil)
        #expect(result.completion == .cancelled)
        #expect(started.duration(to: .now) < .seconds(3))
    }

    @Test nonisolated func processTimeoutKillsUncooperativeChildAndBoundsOutput() {
        let started = ContinuousClock.now
        let result = BoundedProcess.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' TERM; while :; do printf '0123456789abcdef'; done"], timeout: 0.1
        )
        #expect(result.timedOut)
        #expect(result.exitCode != 0)
        #expect(result.runningProcess == nil)
        #expect(result.output.utf8.count <= 65536)
        #expect(started.duration(to: .now) < .seconds(3))
        let next = BoundedProcess.run(executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["recovered"])
        #expect(next.exitCode == 0)
        #expect(next.output == "recovered")
    }

    @Test func separatesAndBoundsBothStreamsWithoutBlockingTheChild() async {
        let result = await BoundedProcess.runAsync(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", """
            i=0
            while [ "$i" -lt 6000 ]; do
                printf '0123456789abcdef'
                printf 'fedcba9876543210' >&2
                i=$((i + 1))
            done
            """], timeout: 5, configuration: .init(outputMode: .separate)
        )
        #expect(result.completion == .exited)
        #expect(result.exitCode == 0)
        #expect(result.standardOutput.data == Data(String(repeating: "0123456789abcdef", count: 4096).utf8))
        #expect(result.standardError.data == Data(String(repeating: "fedcba9876543210", count: 4096).utf8))
        #expect(result.standardOutput.isTruncated)
        #expect(result.standardError.isTruncated)
        #expect(result.standardOutput.reachedEOF)
        #expect(result.standardError.reachedEOF)
    }

    @Test(arguments: [65535, 65536, 65537])
    func capturesTheTailAndReportsActualTruncation(_ size: Int) async {
        let text = String(repeating: "x", count: size - 1) + "!"
        let result = await BoundedProcess.runAsync(executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["%s", text])
        #expect(result.exitCode == 0)
        #expect(result.standardOutput.data == Data(text.utf8.prefix(65536)))
        #expect(result.standardOutput.isTruncated == (size > 65536))
        #expect(result.standardOutput.reachedEOF)
    }

    @Test func preservesRawBytesForCallerSpecificDecoding() async {
        let result = await BoundedProcess.runAsync(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "printf '\\377'; printf 'fallback' >&2"],
            configuration: .init(outputMode: .separate)
        )
        #expect(result.standardOutput.data == Data([255]))
        #expect(String(data: result.standardOutput.data, encoding: .utf8) == nil)
        #expect(result.output == "�")
        #expect(String(data: result.standardError.data, encoding: .utf8) == "fallback")
    }

    @Test(arguments: [false, true])
    func alreadyCancelledTaskDoesNotLaunch(_ synchronous: Bool) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            let arguments = ["-c", "printf started > \"$PROCESS_TEST_DIR/started\""]
            if synchronous {
                return BoundedProcess.run(
                    executable: URL(fileURLWithPath: "/bin/sh"), arguments: arguments,
                    environment: ["PROCESS_TEST_DIR": directory.url.path]
                )
            }
            return await BoundedProcess.runAsync(
                executable: URL(fileURLWithPath: "/bin/sh"), arguments: arguments,
                environment: ["PROCESS_TEST_DIR": directory.url.path]
            )
        }
        let result = await task.value
        #expect(result.completion == .cancelled)
        #expect(result.terminationStatus == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.url.appendingPathComponent("started").path))
    }

    @Test(arguments: [false, true])
    func asyncCancellationWaitsForGracefulOrForcedCleanup(_ ignoresTermination: Bool) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let script = try directory.executable("""
        \(ignoresTermination ? "trap '' TERM" : "trap 'printf stopped; exit 23' TERM")
        printf ready > "$PROCESS_TEST_DIR/ready"
        while :; do :; done
        """)
        let task = Task {
            await BoundedProcess.runAsync(
                executable: script, arguments: [], timeout: 15, environment: ["PROCESS_TEST_DIR": directory.url.path]
            )
        }
        defer { task.cancel() }
        try await directory.waitForFile("ready")
        let started = ContinuousClock.now
        task.cancel()
        let result = await task.value
        #expect(result.completion == .cancelled)
        #expect(result.runningProcess == nil)
        #expect(result.terminationStatus == (ignoresTermination ? SIGKILL : 23))
        #expect(result.terminationReason == (ignoresTermination ? .uncaughtSignal : .exit))
        if !ignoresTermination {
            #expect(result.output == "stopped")
        }
        #expect(started.duration(to: .now) < .seconds(3))
    }

    @Test(arguments: ["while :; do :; done", "while :; do printf x; printf y >&2; done"])
    func asyncTimeoutRemainsBoundedWithIdleOrBusyPipes(_ body: String) async {
        let started = ContinuousClock.now
        let result = await BoundedProcess.runAsync(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "trap '' TERM; " + body],
            timeout: 0.15, configuration: .init(outputMode: .separate)
        )
        #expect(result.completion == .timedOut)
        #expect(result.runningProcess == nil)
        #expect(result.standardOutput.data.count <= 65536)
        #expect(result.standardError.data.count <= 65536)
        #expect(started.duration(to: .now) < .seconds(3))
    }

    @Test func signalExitIsDistinctFromTimeout() async {
        let result = await BoundedProcess.runAsync(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "kill -KILL $$"]
        )
        #expect(result.completion == .exited)
        #expect(result.exitCode == SIGKILL)
        #expect(result.terminationReason == .uncaughtSignal)
    }

    @Test func inheritedWriterDoesNotPreventCompletionOrKillTheDescendant() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let pidURL = directory.url.appendingPathComponent("child.pid")
        defer {
            if let text = try? String(contentsOf: pidURL, encoding: .utf8), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                kill(pid, SIGKILL)
            }
        }
        let started = ContinuousClock.now
        let result = await BoundedProcess.runAsync(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", """
            /bin/sleep 10 &
            printf '%s' "$!" > "$PROCESS_TEST_DIR/child.pid"
            printf tail
            """], environment: ["PROCESS_TEST_DIR": directory.url.path]
        )
        #expect(result.exitCode == 0)
        #expect(result.output == "tail")
        #expect(!result.standardOutput.reachedEOF)
        #expect(started.duration(to: .now) < .seconds(3))
        let pid = try #require(Int32(String(contentsOf: pidURL, encoding: .utf8)))
        #expect(kill(pid, 0) == 0)
    }

    @Test func expiredDeadlineAndInvalidBudgetDoNotLaunch() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let script = try directory.executable("printf started > \"$PROCESS_TEST_DIR/started\"")
        let expired = await BoundedProcess.runAsync(
            executable: script, arguments: [], environment: ["PROCESS_TEST_DIR": directory.url.path],
            configuration: .init(deadline: .now.advanced(by: .seconds(-1)))
        )
        #expect(expired.completion == .timedOut)
        let invalid = await BoundedProcess.runAsync(
            executable: script, arguments: [], timeout: .infinity, environment: ["PROCESS_TEST_DIR": directory.url.path]
        )
        #expect(invalid.completion == .invalidConfiguration)
        #expect(!FileManager.default.fileExists(atPath: directory.url.appendingPathComponent("started").path))
    }

    @Test func cancellationRacingExitAlwaysFinishesOnce() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let command = try directory.executable("""
        printf ready > "$PROCESS_TEST_DIR/$PROCESS_TEST_INDEX.ready"
        while [ ! -f "$PROCESS_TEST_DIR/$PROCESS_TEST_INDEX.exit" ]; do :; done
        printf done
        """)
        for iteration in 0 ..< 20 {
            let task = Task {
                await BoundedProcess.runAsync(
                    executable: command, arguments: [], timeout: 5,
                    environment: ["PROCESS_TEST_DIR": directory.url.path, "PROCESS_TEST_INDEX": String(iteration)]
                )
            }
            defer { task.cancel() }
            try await directory.waitForFile("\(iteration).ready")
            _ = try directory.write("exit", to: "\(iteration).exit")
            if iteration.isMultiple(of: 2) {
                await Task.yield()
            }
            task.cancel()
            let result = await task.value
            #expect(result.completion == .cancelled || result.completion == .exited)
            #expect(result.runningProcess == nil)
            if result.completion == .exited {
                #expect(result.output == "done")
            }
        }
    }

    @Test func repeatedLaunchFailuresAndCompletionsDoNotAccumulateDescriptors() async throws {
        let executable = URL(fileURLWithPath: "/usr/bin/true")
        for _ in 0 ..< 3 {
            _ = await BoundedProcess.runAsync(executable: executable, arguments: [])
        }
        let before = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
        let missing = URL(fileURLWithPath: "/tmp/\(UUID().uuidString)/missing")
        for _ in 0 ..< 20 {
            let failed = await BoundedProcess.runAsync(executable: missing, arguments: [], configuration: .init(outputMode: .separate))
            guard case .launchFailed = failed.completion else {
                Issue.record("Expected launch failure")
                return
            }
            let completed = await BoundedProcess.runAsync(executable: executable, arguments: [], configuration: .init(outputMode: .separate))
            #expect(completed.exitCode == 0)
            #expect(completed.runningProcess == nil)
        }
        let after = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
        // Foundation 和测试框架可能延迟打开描述符, 不要求全进程数量完全一致
        #expect(after <= before + 2)
    }
}
