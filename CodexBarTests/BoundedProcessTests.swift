import Foundation
import Testing

struct BoundedProcessTests {
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
}
