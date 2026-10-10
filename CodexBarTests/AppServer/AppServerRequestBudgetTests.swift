import Darwin
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct AppServerRequestBudgetTests {
    @Test func expiredBudgetNeverSendsRequest() async throws {
        let server = try SharedServerFixture { peer in
            var byte: UInt8 = 0
            #expect(Darwin.read(peer.descriptor, &byte, 1) == 0)
        }
        defer { server.close() }
        let socketURL = server.url
        try await Task.detached {
            let session = try AccountSession(socketURL: socketURL, logStorage: nil)
            defer { session.close() }
            let budget = AppServerRequestBudget(deadline: Date().addingTimeInterval(-1))
            #expect(throws: CodexStatusError.self) {
                try AppServerRequestBudget.$current.withValue(budget) {
                    let _: [String: String] = try session.request("account/read", as: [String: String].self)
                }
            }
        }.value
        try server.finish()
    }

    @Test func requestBudgetBoundsPartialFrameRead() async throws {
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let server = try SharedServerFixture { peer in
            _ = try peer.readMessage()
            var header: [UInt8] = [0x81, 100, 123]
            #expect(Darwin.write(peer.descriptor, &header, header.count) == header.count)
            #expect(release.wait(timeout: .now() + 3) == .success)
        }
        defer { server.close() }
        let socketURL = server.url
        try await Task.detached {
            let session = try AccountSession(socketURL: socketURL, logStorage: nil)
            defer { session.close() }
            let started = ContinuousClock.now
            let budget = AppServerRequestBudget(deadline: Date().addingTimeInterval(0.1))
            #expect(throws: CodexStatusError.self) {
                try AppServerRequestBudget.$current.withValue(budget) {
                    let _: [String: String] = try session.request("account/read", as: [String: String].self)
                }
            }
            #expect(started.duration(to: .now) < .seconds(1))
            #expect(!session.isOpen)
        }.value
        release.signal()
        try server.finish()
    }

    @Test func constrainedBudgetCannotExtendMonotonicDeadline() {
        let original = AppServerRequestBudget(deadline: Date().addingTimeInterval(60))
        let movedClock = Date().addingTimeInterval(-3600)
        let constrained = original.constrained(to: original.wallDeadline, now: movedClock)
        #expect(constrained.deadline <= original.deadline)
        #expect(constrained.wallDeadline == original.wallDeadline)
    }

    @Test func expiredCreditIsRejectedBeforeConsumeEvenWithRemainingRequestBudget() async throws {
        let server = try SharedServerFixture { peer in
            let initialize = try peer.readMessage()
            try peer.reply(to: initialize, result: ["userAgent": "codex/0.162.0"])
            #expect(try peer.readMessage()["method"] as? String == "initialized")
            for _ in 0 ..< 2 {
                let account = try peer.readMessage()
                #expect(account["method"] as? String == "account/read")
                try peer.reply(to: account, result: ["account": ["type": "chatgpt", "email": "test@example.com", "planType": "plus"]])
            }
            // 请求预算仍有余量, 但凭证已进入安全截止区间
            var byte: UInt8 = 0
            #expect(Darwin.read(peer.descriptor, &byte, 1) == 0)
        }
        defer { server.close() }
        let socketURL = server.url
        try await Task.detached {
            let service = CodexStatusService(socketURL: socketURL)
            do {
                _ = try await service.consumeResetCredit(
                    id: "test-credit", idempotencyKey: "test-key",
                    expectedAccountIdentity: "chatgpt\u{0}test@example.com",
                    expirationDate: Date().addingTimeInterval(30),
                    budget: AppServerRequestBudget(deadline: Date().addingTimeInterval(60))
                )
                Issue.record("Credit past safety cutoff was consumed")
            } catch AutoResetServiceError.deadlineReached {
                // 预期截止, actor 释放后关闭测试连接
            }
        }.value
        try server.finish()
    }
}
