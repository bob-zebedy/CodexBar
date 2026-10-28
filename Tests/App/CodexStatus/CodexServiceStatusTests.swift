import Combine
import Foundation
import Testing

struct CodexServiceStatusTests {
    @Test func unrelatedIncidentsDoNotChangeCodexStatus() throws {
        let data = try Self.response(affected: [("chatgpt", "full_outage")])
        #expect(try CodexServiceStatus(data: data) == .operational)
    }

    @Test(arguments: [
        ("api", "Codex API"), ("cli", "CLI"), ("web", "Codex Web"),
        ("extension", "VS Code extension"), ("desktop", "Codex in ChatGPT Desktop")
    ])
    func includesCodexGroupAndDesktop(_ component: String, _ name: String) throws {
        let data = try Self.response(affected: [(component, "degraded_performance")])
        #expect(try CodexServiceStatus(data: data) == CodexServiceStatus(level: .degradedPerformance, componentNames: [name]))
    }

    @Test func reportsHighestComponentsOnceInCatalogOrder() throws {
        let affected = [
            ("web", "partial_outage"), ("cli", "full_outage"), ("api", "full_outage"), ("cli", "degraded_performance"),
            ("chatgpt", "full_outage"), ("web", "operational"), ("desktop", "full_outage"), ("cli", "operational"),
            ("api", "full_outage")
        ]
        let expected = CodexServiceStatus(level: .fullOutage, componentNames: ["Codex API", "Codex in ChatGPT Desktop", "CLI"])
        #expect(try CodexServiceStatus(data: Self.response(affected: affected)) == expected)
        #expect(try CodexServiceStatus(data: Self.response(affected: Array(affected.reversed()))) == expected)
    }

    @Test(arguments: [
        CodexServiceStatus.Level.degradedPerformance, .partialOutage, .fullOutage, .underMaintenance
    ])
    func showsAllAffectedComponentsAtTheSameLevel(_ level: CodexServiceStatus.Level) throws {
        let data = try Self.response(affected: ["web", "api", "cli", "extension", "desktop", "chatgpt"].map {
            ($0, level.rawValue)
        })
        let status = try CodexServiceStatus(data: data)
        #expect(status.level == level)
        #expect(status.componentNames == [
            "Codex API", "Codex Web", "VS Code extension", "Codex in ChatGPT Desktop", "CLI"
        ])
    }

    @Test(arguments: [
        (CodexServiceStatus.Level.fullOutage, CodexServiceStatus.Level.partialOutage),
        (.fullOutage, .degradedPerformance), (.fullOutage, .underMaintenance),
        (.partialOutage, .degradedPerformance), (.partialOutage, .underMaintenance),
        (.degradedPerformance, .underMaintenance)
    ])
    func showsEveryComponentAtTheHighestLevel(
        _ highest: CodexServiceStatus.Level,
        _ lower: CodexServiceStatus.Level
    ) throws {
        let data = try Self.response(affected: [
            ("web", lower.rawValue), ("api", highest.rawValue), ("cli", highest.rawValue),
            ("desktop", lower.rawValue), ("chatgpt", "full_outage")
        ])
        let status = try CodexServiceStatus(data: data)
        #expect(status.level == highest)
        #expect(status.componentNames == ["Codex API", "CLI"])
    }

    @Test func statusEqualityTracksDisplayedComponents() throws {
        let initial = try CodexServiceStatus(data: Self.response(affected: [
            ("api", "full_outage"), ("web", "partial_outage")
        ]))
        let lowerLevelsChanged = try CodexServiceStatus(data: Self.response(affected: [
            ("api", "full_outage"), ("web", "operational"), ("desktop", "under_maintenance"), ("cli", "degraded_performance")
        ]))
        let highestComponentsChanged = try CodexServiceStatus(data: Self.response(affected: [
            ("api", "full_outage"), ("cli", "full_outage")
        ]))
        #expect(initial == lowerLevelsChanged)
        #expect(initial != highestComponentsChanged)
    }

    @Test(arguments: ["api", "cli"])
    func unknownStatusAfterFullOutageIsRejected(_ component: String) throws {
        let data = try Self.response(affected: [("cli", "full_outage"), (component, "new-status")])
        #expect(throws: CodexServiceStatus.ParseError.self) { try CodexServiceStatus(data: data) }
    }

    @Test func incompleteOrUnknownDataDoesNotLookHealthy() throws {
        let unknown = try Self.response(affected: [("cli", "new-status")])
        #expect(throws: CodexServiceStatus.ParseError.self) { try CodexServiceStatus(data: unknown) }
        let missingGroup = try Self.response(groupName: "Other")
        #expect(throws: CodexServiceStatus.ParseError.self) { try CodexServiceStatus(data: missingGroup) }
        let missingComponent = try Self.response(omitsCLI: true)
        #expect(throws: CodexServiceStatus.ParseError.self) { try CodexServiceStatus(data: missingComponent) }
        #expect(throws: DecodingError.self) { try CodexServiceStatus(data: Data(#"{"summary":{}}"#.utf8)) }
    }

    @Test func noImpactAndExplicitRecoveryAreOperational() throws {
        #expect(try CodexServiceStatus(data: Self.response()) == .operational)
        #expect(try CodexServiceStatus(data: Self.response(affected: [("cli", "operational")])) == .operational)
        #expect(CodexServiceStatus.operational.level == .operational)
        #expect(CodexServiceStatus.operational.componentNames.isEmpty)
    }

    @Test func disabledMonitorSkipsRefresh() async throws {
        let probe = ServiceStatusProbe()
        let monitor = CodexServiceStatusMonitor(fetch: { try await probe.fetch() })
        await monitor.refresh()
        #expect(await probe.calls == 0)
        monitor.setEnabled(true)
        await monitor.refresh()
        #expect(monitor.state == .available(.operational))
        monitor.setEnabled(false)
        await monitor.refresh()
        try await Task.sleep(for: .milliseconds(30))
        #expect(await probe.calls == 1)
        #expect(monitor.state == .available(.operational))
    }

    @Test func eachRefreshFetchesWithoutAnIndependentTimer() async throws {
        let probe = ServiceStatusProbe()
        let monitor = CodexServiceStatusMonitor(fetch: { try await probe.fetch() })
        monitor.setEnabled(true)
        await monitor.refresh()
        await monitor.refresh()
        #expect(await probe.calls == 2)
        try await Task.sleep(for: .milliseconds(40))
        #expect(await probe.calls == 2)
    }

    @Test func concurrentRefreshesShareThePendingRequest() async throws {
        let probe = ServiceStatusProbe(holdsFirst: true)
        let monitor = CodexServiceStatusMonitor(fetch: { try await probe.fetch() })
        defer { monitor.setEnabled(false) }
        monitor.setEnabled(true)
        let first = Task { await monitor.refresh() }
        #expect(try await waitForCondition(timeout: .seconds(3), pollInterval: .milliseconds(5)) { await probe.calls == 1 })
        let second = Task { await monitor.refresh() }
        try await Task.sleep(for: .milliseconds(20))
        #expect(await probe.calls == 1)
        await probe.releaseFirst()
        await first.value
        await second.value
        #expect(monitor.state == .available(.operational))
    }

    @Test func failedRefreshDoesNotKeepShowingHealthy() async {
        let probe = ServiceStatusProbe()
        let monitor = CodexServiceStatusMonitor(fetch: { try await probe.fetch() })
        monitor.setEnabled(true)
        await monitor.refresh()
        #expect(monitor.state == .available(.operational))
        var states: [CodexServiceStatusMonitor.State] = []
        let observation = monitor.$state.sink { states.append($0) }
        defer { observation.cancel() }
        await probe.fail()
        await monitor.refresh()
        #expect(monitor.state == .unavailable)
        await probe.recover()
        await monitor.refresh()
        #expect(monitor.state == .available(.operational))
        #expect(states == [.available(.operational), .checking, .unavailable, .checking, .available(.operational)])
    }

    @Test func cancelledResultCannotOverwriteReenabledMonitor() async throws {
        let probe = ServiceStatusProbe(holdsFirst: true)
        let monitor = CodexServiceStatusMonitor(fetch: { try await probe.fetch() })
        defer { monitor.setEnabled(false) }
        monitor.setEnabled(true)
        let first = Task { await monitor.refresh() }
        #expect(try await waitForCondition(timeout: .seconds(3), pollInterval: .milliseconds(5)) { await probe.calls == 1 })
        monitor.setEnabled(false)
        monitor.setEnabled(true)
        await monitor.refresh()
        let outage = CodexServiceStatus(level: .fullOutage, componentNames: ["CLI"])
        #expect(monitor.state == .available(outage))
        await probe.releaseFirst()
        await first.value
        #expect(monitor.state == .available(outage))
        #expect(await probe.calls == 2)
    }

    @Test func sharedUpdateTimeWaitsForServiceStatus() async throws {
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let probe = ServiceStatusProbe(holdsFirst: true)
        let monitor = CodexServiceStatusMonitor(fetch: { try await probe.fetch() })
        defer { monitor.setEnabled(false) }
        monitor.setEnabled(true)
        let model = CodexStatusViewModel(
            service: CodexStatusService(socketURL: URL(fileURLWithPath: "/tmp/\(preferences.suite).sock"), logStorage: nil),
            serviceStatusMonitor: monitor,
            defaults: preferences.defaults
        )
        model.refresh(trigger: .manual)
        #expect(try await waitForCondition(timeout: .seconds(3), pollInterval: .milliseconds(5)) { await probe.calls == 1 })
        #expect(model.isRefreshing)
        #expect(model.autoRefreshCountdownStartedAt == nil)
        model.refresh(trigger: .manual)
        await probe.releaseFirst()
        #expect(try await waitForCondition(timeout: .seconds(3), pollInterval: .milliseconds(5)) { !model.isRefreshing })
        #expect(monitor.state == .available(.operational))
        #expect(model.autoRefreshCountdownStartedAt != nil)
        #expect(await probe.calls == 1)

        var states: [CodexServiceStatusMonitor.State] = []
        let observation = monitor.$state.sink { states.append($0) }
        defer { observation.cancel() }
        model.refresh(trigger: .manual)
        #expect(try await waitForCondition(timeout: .seconds(3), pollInterval: .milliseconds(5)) { !model.isRefreshing })
        let outage = CodexServiceStatus(level: .fullOutage, componentNames: ["CLI"])
        #expect(states == [.available(.operational), .checking, .available(outage)])
        #expect(await probe.calls == 2)
    }

    @Test func notificationsPreserveSharedTimeAndManualRefreshIncludesServiceFailure() async throws {
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let probe = ServiceStatusProbe()
        let monitor = CodexServiceStatusMonitor(fetch: { try await probe.fetch() })
        monitor.setEnabled(true)
        let model = CodexStatusViewModel(
            service: CodexStatusService(socketURL: URL(fileURLWithPath: "/tmp/\(preferences.suite).sock"), logStorage: nil),
            serviceStatusMonitor: monitor,
            defaults: preferences.defaults
        )
        model.refresh(trigger: .manual)
        #expect(try await waitForCondition(timeout: .seconds(3), pollInterval: .milliseconds(5)) { !model.isRefreshing })
        let updatedAt = try #require(model.autoRefreshCountdownStartedAt)
        await probe.fail()
        model.refresh(trigger: .accountNotification)
        #expect(try await waitForCondition(timeout: .seconds(3), pollInterval: .milliseconds(5)) { !model.isRefreshing })
        #expect(model.autoRefreshCountdownStartedAt == updatedAt)
        #expect(monitor.state == .available(.operational))
        #expect(await probe.calls == 1)
        model.refresh(trigger: .manual)
        #expect(try await waitForCondition(timeout: .seconds(3), pollInterval: .milliseconds(5)) { !model.isRefreshing })
        #expect(try #require(model.autoRefreshCountdownStartedAt) > updatedAt)
        #expect(monitor.state == .unavailable)
        #expect(await probe.calls == 2)
    }

    @Test(arguments: ["valid", "http-error", "invalid-json", "oversized-header", "oversized-body"])
    func transportValidatesResponses(_ scenario: String) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ServiceStatusURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Test-Scenario": scenario]
        let service = CodexServiceStatusService(session: URLSession(configuration: configuration))
        if scenario == "valid" {
            #expect(try await service.fetch() == .operational)
        } else {
            await #expect(throws: (any Error).self) { try await service.fetch() }
        }
    }

    fileprivate nonisolated static func response(
        affected: [(id: String, status: String)] = [],
        groupName: String = "Codex",
        omitsCLI: Bool = false
    ) throws -> Data {
        var components = [
            ["id": "api", "name": "Codex API"], ["id": "web", "name": "Codex Web"],
            ["id": "extension", "name": "VS Code extension"], ["id": "desktop", "name": "Codex in ChatGPT Desktop"],
            ["id": "chatgpt", "name": "Conversations"]
        ]
        if !omitsCLI {
            components.append(["id": "cli", "name": "CLI"])
        }
        return try JSONSerialization.data(withJSONObject: ["summary": [
            "components": components,
            "affected_components": affected.map { ["component_id": $0.id, "status": $0.status] },
            "structure": ["items": [["group": [
                "name": groupName, "hidden": false,
                "components": ["api", "cli", "web", "extension"].map { ["component_id": $0] }
            ]]]]
        ]])
    }
}

private actor ServiceStatusProbe {
    private(set) var calls = 0
    private var fails = false
    private let holdsFirst: Bool
    private var first: CheckedContinuation<CodexServiceStatus, Never>?

    init(holdsFirst: Bool = false) {
        self.holdsFirst = holdsFirst
    }

    func fetch() async throws -> CodexServiceStatus {
        calls += 1
        if holdsFirst, calls == 1 {
            return await withCheckedContinuation { first = $0 }
        }
        if fails {
            throw URLError(.notConnectedToInternet)
        }
        return holdsFirst ? CodexServiceStatus(level: .fullOutage, componentNames: ["CLI"]) : .operational
    }

    func fail() {
        fails = true
    }

    func recover() {
        fails = false
    }

    func releaseFirst() {
        first?.resume(returning: .operational)
        first = nil
    }
}

private final nonisolated class ServiceStatusURLProtocol: URLProtocol, @unchecked Sendable {
    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let scenario = request.value(forHTTPHeaderField: "X-Test-Scenario") ?? "valid"
        do {
            let data: Data = switch scenario {
            case "invalid-json": Data("<html>Unavailable</html>".utf8)
            case "oversized-body": Data(repeating: 32, count: 256 * 1024 + 1)
            default: try CodexServiceStatusTests.response()
            }
            let headers = scenario == "oversized-header" ? ["Content-Length": "1048576"] : [:]
            let response = HTTPURLResponse(url: request.url!, statusCode: scenario == "http-error" ? 503 : 200, httpVersion: nil, headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
