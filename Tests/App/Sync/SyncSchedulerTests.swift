import Foundation
import Testing

struct SyncSchedulerTests {
    @Test func cancellingSyncDoesNotReviveOldTaskAfterReenable() async throws {
        var active = true
        var starts = 0
        var cancelled = false
        var release: CheckedContinuation<Void, Never>?
        let scheduler = SyncScheduler(
            syncActivation: { active ? .active : .syncOff },
            maintenance: { _, _ in
                starts += 1
                if starts == 1 {
                    await withCheckedContinuation { release = $0 }
                    do {
                        try SyncCancellation.check(isEnabled: { true })
                    } catch is CancellationError {
                        cancelled = true
                    } catch {
                        Issue.record(error)
                    }
                }
                return nil
            },
            rebuild: { _, _ in throw CancellationError() }
        )
        scheduler.requestSync(trigger: .manual)
        for _ in 0 ..< 100 where release == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(starts == 1)
        active = false
        scheduler.requestSync(trigger: .settings)
        active = true
        scheduler.requestSync(trigger: .settings)
        #expect(starts == 1)
        release?.resume()
        for _ in 0 ..< 100 where starts != 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(cancelled)
        #expect(starts == 2)
        scheduler.cancel()
    }
}
