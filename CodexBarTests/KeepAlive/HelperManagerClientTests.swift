import Foundation
import ServiceManagement
import Testing

@Suite(.timeLimit(.minutes(1)))
struct HelperManagerClientTests {
    @Test func transientStatusFailureRecoversWithinSameRequest() async throws {
        let execution = HelperManagerExecutionStub(failures: 1, status: .enabled)
        let client = HelperManagerClient(retryDelay: .zero, executeCommand: { try await execution.execute($0) })
        #expect(try await client.perform(.status) == .enabled)
        #expect(await execution.commands == [.status, .status])
    }

    @Test(arguments: [SMAppService.Status.notRegistered, .enabled, .requiresApproval, .notFound])
    func validStatusIsNeverRetried(_ status: SMAppService.Status) async throws {
        let execution = HelperManagerExecutionStub(failures: 0, status: status)
        let client = HelperManagerClient(retryDelay: .zero, executeCommand: { try await execution.execute($0) })
        #expect(try await client.perform(.status) == status)
        #expect(await execution.commands == [.status])
    }

    @Test func persistentFailureStopsAfterThreeAttemptsAndAllowsLaterRefresh() async throws {
        let execution = HelperManagerExecutionStub(failures: 3, status: .enabled)
        let client = HelperManagerClient(retryDelay: .zero, executeCommand: { try await execution.execute($0) })
        await #expect(throws: HelperManagerClient.ClientError.self) {
            try await client.perform(.status)
        }
        #expect(await execution.commands.count == 3)
        #expect(try await client.perform(.status) == .enabled)
        #expect(await execution.commands.count == 4)
    }

    @Test(arguments: [HelperManagement.Command.register, .unregister])
    func mutationsAreNeverRetried(_ command: HelperManagement.Command) async {
        let execution = HelperManagerExecutionStub(failures: 3, status: .enabled)
        let client = HelperManagerClient(retryDelay: .zero, executeCommand: { try await execution.execute($0) })
        await #expect(throws: HelperManagerClient.ClientError.self) {
            try await client.perform(command)
        }
        #expect(await execution.commands == [command])
    }

    @Test func cancellationStopsRetryAndAllowsNextRequest() async throws {
        let execution = HelperManagerExecutionStub(failures: 1, status: .enabled)
        let client = HelperManagerClient(retryDelay: .seconds(30), executeCommand: { try await execution.execute($0) })
        let request = Task { try await client.perform(.status) }
        await execution.waitForFirstAttempt()
        request.cancel()
        await #expect(throws: CancellationError.self) {
            try await request.value
        }
        #expect(await execution.commands == [.status])
        #expect(try await client.perform(.status) == .enabled)
        #expect(await execution.commands == [.status, .status])
    }

    @Test(arguments: [SMAppService.Status.notRegistered, .enabled, .requiresApproval, .notFound])
    func statusKeepsSystemMeaning(_ status: SMAppService.Status) throws {
        let data = try reply(status)
        #expect(try HelperManagerClient.status(from: data, command: .status) == status)
    }

    @Test func pendingApprovalIsRegisteredButNotEnabled() throws {
        let data = try reply(.requiresApproval, errorDomain: SMAppServiceErrorDomain, errorCode: 1)
        let status = try HelperManagerClient.status(from: data, command: .register)
        #expect(status == .requiresApproval)
        #expect(KeepAliveController.HelperStatus(status).isRegisteredOrAwaitingApproval)
    }

    @Test func registrationFailureCannotBeMistakenForApproval() throws {
        let data = try reply(.notRegistered, errorDomain: SMAppServiceErrorDomain, errorCode: 1)
        #expect(throws: NSError.self) {
            try HelperManagerClient.status(from: data, command: .register)
        }
    }

    @Test func unregistrationFailureIsNotHiddenByEnabledStatus() throws {
        let data = try reply(.enabled, errorDomain: SMAppServiceErrorDomain, errorCode: 1)
        #expect(throws: NSError.self) {
            try HelperManagerClient.status(from: data, command: .unregister)
        }
    }

    @Test func malformedReplyDoesNotBecomeNotRegistered() {
        for data in [Data(), Data("{}".utf8), Data("{\"status\":999}".utf8)] {
            #expect(throws: (any Error).self) {
                try HelperManagerClient.status(from: data, command: .status)
            }
        }
    }

    private func reply(_ status: SMAppService.Status, errorDomain: String? = nil, errorCode: Int? = nil) throws -> Data {
        try JSONEncoder().encode(HelperManagement.Reply(status: status.rawValue, errorDomain: errorDomain, errorCode: errorCode))
    }
}

private actor HelperManagerExecutionStub {
    private var failures: Int
    private let status: SMAppService.Status
    private(set) var commands: [HelperManagement.Command] = []
    private var firstAttempt: CheckedContinuation<Void, Never>?

    init(failures: Int, status: SMAppService.Status) {
        self.failures = failures
        self.status = status
    }

    func execute(_ command: HelperManagement.Command) throws -> SMAppService.Status {
        commands.append(command)
        firstAttempt?.resume()
        firstAttempt = nil
        if failures > 0 {
            failures -= 1
            throw HelperManagerClient.ClientError.executionFailed
        }
        return status
    }

    func waitForFirstAttempt() async {
        guard commands.isEmpty else { return }
        await withCheckedContinuation { firstAttempt = $0 }
    }
}
