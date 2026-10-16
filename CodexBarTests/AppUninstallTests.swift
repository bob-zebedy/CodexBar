import AppKit
import Darwin
import Foundation
import ServiceManagement
import Testing

@MainActor
struct AppUninstallTests {
    @Test func exitedProcessDoesNotWaitForStaleApplicationState() async throws {
        let application = StaleUninstallApplication(processID: Int32.max)
        #expect(!application.isTerminated)
        try #require(kill(application.processIdentifier, 0) == -1 && errno == ESRCH)
        try await AppUninstallCommand.quitApplications([application], timeout: .zero)
    }

    @Test func runningProcessStillPreventsCleanup() async {
        let application = StaleUninstallApplication(processID: getpid())
        await #expect(throws: AppUninstallError.self) {
            try await AppUninstallCommand.quitApplications([application], timeout: .zero)
        }
        #expect(kill(getpid(), 0) == 0)
    }

    @Test func exitedProcessAwaitingReapingDoesNotBlockCleanup() async throws {
        let processID = try await Task.detached {
            let executable = try #require(strdup("/usr/bin/true"))
            defer { free(executable) }
            var arguments: [UnsafeMutablePointer<CChar>?] = [executable, nil]
            var processID: pid_t = 0
            let result = posix_spawn(&processID, executable, nil, nil, &arguments, nil)
            guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
            var info = siginfo_t()
            guard waitid(P_PID, id_t(processID), &info, WEXITED | WNOWAIT) == 0 else {
                let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                _ = kill(processID, SIGKILL)
                _ = waitpid(processID, nil, 0)
                throw error
            }
            return processID
        }.value
        defer { _ = waitpid(processID, nil, WNOHANG) }
        #expect(kill(processID, 0) == 0)
        try await AppUninstallCommand.quitApplications([StaleUninstallApplication(processID: processID)], timeout: .zero)
    }

    @Test(arguments: [pid_t(-1), pid_t(0)])
    func unknownProcessIdentityStillPreventsCleanup(processID: pid_t) async {
        await #expect(throws: AppUninstallError.self) {
            try await AppUninstallCommand.quitApplications([StaleUninstallApplication(processID: processID)], timeout: .zero)
        }
    }

    @Test func observesProcessExitDespiteStaleApplicationState() async throws {
        let process = try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sleep")
            process.arguments = ["10"]
            try process.run()
            return process
        }.value
        let termination = Task {
            try await Task.sleep(for: .milliseconds(25))
            process.terminate()
        }
        defer {
            termination.cancel()
            if process.isRunning {
                process.terminate()
            }
        }
        let application = StaleUninstallApplication(processID: process.processIdentifier)
        #expect(kill(application.processIdentifier, 0) == 0)
        try await AppUninstallCommand.quitApplications([application], timeout: .seconds(5))
        #expect(!application.isTerminated)
        #expect(kill(application.processIdentifier, 0) == -1 && errno == ESRCH)
    }

    @Test(arguments: ["CodexBar.app", "CodexBar Debug.app"])
    func acceptsExecutableFromAppBundle(name: String) throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let appURL = try appBundle(in: directory, name: name)
        let executable = try AppUninstall.validatedExecutableURL(appURL: appURL)
        #expect(executable.path == appURL.appending(path: "Contents/MacOS/CodexBar").path)
    }

    @Test func rejectsAppWithDifferentIdentifier() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let appURL = try appBundle(in: directory, identifier: "test.other-app")
        #expect(throws: AppUninstallError.self) { try AppUninstall.validatedExecutableURL(appURL: appURL) }
    }

    @Test func rejectsExecutableOutsideMacOSDirectory() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let appURL = try appBundle(in: directory)
        try FileManager.default.moveItem(
            at: appURL.appending(path: "Contents/MacOS/CodexBar"),
            to: appURL.appending(path: "CodexBar")
        )
        #expect(throws: AppUninstallError.self) { try AppUninstall.validatedExecutableURL(appURL: appURL) }
    }

    @Test(arguments: AppUninstall.Step.allCases)
    func failurePreservesAppAndReportsEveryStep(failingStep: AppUninstall.Step) async throws {
        var visited: [AppUninstall.Step] = []
        var completed: [AppUninstall.Step] = []
        let report = try await AppUninstall.run(
            options: AppUninstallOptions(arguments: ["--uninstall"]),
            progress: { step, status in
                if status != .running {
                    completed.append(step)
                }
            },
            perform: { step in
                visited.append(step)
                if step == failingStep {
                    throw AppUninstallError("模拟清理失败")
                }
                return .succeeded
            }
        )
        #expect(report.hasFailures)
        #expect(report.results[failingStep] == .failed("模拟清理失败"))
        #expect(completed == AppUninstall.Step.allCases)
        #expect(visited.contains(.trash) == (failingStep == .trash))
        #expect(report.results[.trash] != .succeeded)
    }

    @Test(arguments: [AppUninstall.Step.hooks, .loginItem, .helper, .preferences])
    func cleanupFailureContinuesIndependentSteps(failingStep: AppUninstall.Step) async throws {
        var visited: [AppUninstall.Step] = []
        let report = try await AppUninstall.run(options: AppUninstallOptions(arguments: ["--uninstall"])) { step in
            visited.append(step)
            if step == failingStep {
                throw AppUninstallError("模拟清理失败")
            }
            return .succeeded
        }
        if failingStep == .preferences {
            #expect(visited == [.quit, .hooks, .loginItem, .helper, .preferences, .verify])
        } else {
            #expect(visited == [.quit, .hooks, .loginItem, .helper, .verify])
            #expect(report.results[.preferences] == .skipped("前序清理失败, 保留设置以便重试"))
        }
        #expect(report.results[.verify] == .succeeded)
        #expect(report.results[.trash] == .skipped("存在失败步骤, 保留 App 以便重试"))
    }

    @Test func failedQuitSkipsAllCleanup() async throws {
        var visited: [AppUninstall.Step] = []
        let report = try await AppUninstall.run(options: AppUninstallOptions(arguments: ["--uninstall"])) { step in
            visited.append(step)
            throw AppUninstallError("旧 App 拒绝退出")
        }
        #expect(visited == [.quit])
        #expect(report.hasFailures)
        #expect(report.results[.hooks] == .skipped("App 未完成退出或前置检查"))
        #expect(report.results[.verify] == .skipped("App 未完成退出或前置检查"))
    }

    @Test func multipleFailuresAreReportedWithoutStoppingIndependentSteps() async throws {
        let report = try await AppUninstall.run(options: AppUninstallOptions(arguments: ["--uninstall"])) { step in
            if [.hooks, .loginItem, .helper].contains(step) {
                throw AppUninstallError(step.rawValue)
            }
            return .succeeded
        }
        #expect(report.results[.hooks] == .failed("移除 CodexBar Hook"))
        #expect(report.results[.loginItem] == .failed("注销 CodexBar 启动项"))
        #expect(report.results[.helper] == .failed("注销 CodexBar Helper"))
        #expect(report.results[.verify] == .succeeded)
        #expect(report.summary.contains("成功 2, 失败 3, 跳过 1"))
    }

    @Test func appIsRemovedOnlyAfterVerification() async throws {
        var verified = false
        var removed = false
        var updates: [String] = []
        let report = try await AppUninstall.run(
            options: AppUninstallOptions(arguments: ["--uninstall"]),
            progress: { step, status in updates.append(step.progressMessage(status)) },
            perform: { step in
                if step == .verify {
                    verified = true
                }
                if step == .trash {
                    #expect(verified)
                    removed = true
                }
                return .succeeded
            }
        )
        #expect(removed)
        #expect(report.results[.preferences] == .succeeded)
        #expect(!report.hasFailures)
        #expect(updates.count == 14)
        #expect(updates.prefix(2) == ["[1/6] 退出 CodexBar App ... 执行中", "[1/6] 退出 CodexBar App ... 成功"])
        #expect(updates.contains("[6/6] 验证清理结果 ... 成功"))
        #expect(updates.suffix(2) == ["收尾 将 App 移到废纸篓 ... 执行中", "收尾 将 App 移到废纸篓 ... 成功"])
        #expect(report.summary == "清理结束: 成功 6, 失败 0, 跳过 0\nApp 已移到废纸篓")
    }

    @Test func unconfiguredComponentsAreSkippedWithoutPreventingRemoval() async throws {
        let report = try await AppUninstall.run(options: AppUninstallOptions(arguments: ["--uninstall"])) { step in
            if [.hooks, .loginItem, .helper].contains(step) {
                return .skipped("未启用")
            }
            return .succeeded
        }
        #expect(!report.hasFailures)
        #expect(report.results[.verify] == .succeeded)
        #expect(report.results[.trash] == .succeeded)
        #expect(report.summary.contains("成功 3, 失败 0, 跳过 3"))
    }

    @Test(arguments: ["--keep-app", "--help"])
    func nonRemovalOptionsRetainApp(option: String) async throws {
        var visited: [AppUninstall.Step] = []
        let report = try await AppUninstall.run(options: AppUninstallOptions(arguments: ["--uninstall", option])) { step in
            visited.append(step)
            return .succeeded
        }
        #expect(!visited.contains(.trash))
        #expect(option == "--help" ? visited.isEmpty : visited.contains(.verify))
        #expect(!report.hasFailures)
        if option == "--keep-app" {
            #expect(visited.contains(.preferences))
            #expect(report.results[.trash] == .skipped("已指定 --keep-app"))
            #expect(report.summary == "清理结束: 成功 6, 失败 0, 跳过 0\nApp 已保留")
        } else {
            #expect(report.results.isEmpty)
        }
    }

    @Test(arguments: [[], ["--keep-app"], ["--uninstall", "--unknown"], ["--uninstall", "--hook-event"], ["--uninstall", "--keep-app", "--keep-app"]])
    func rejectsInvalidArguments(arguments: [String]) {
        #expect(throws: AppUninstallError.self) { try AppUninstallOptions(arguments: arguments) }
    }

    @Test func cancellationPreventsCleanup() async throws {
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await AppUninstall.run(options: AppUninstallOptions(arguments: ["--uninstall"])) { _ in
                Issue.record("已取消命令不应执行清理")
                return .succeeded
            }
        }
        let report = try await task.value
        #expect(report.results[.quit] == .failed("操作已取消"))
        #expect(report.results[.trash] == .skipped("操作已取消"))
        #expect(report.hasFailures)
    }

    @Test func cancellationDuringCleanupSkipsRemainingSteps() async throws {
        var visited: [AppUninstall.Step] = []
        let report = try await AppUninstall.run(options: AppUninstallOptions(arguments: ["--uninstall"])) { step in
            visited.append(step)
            if step == .hooks {
                throw CancellationError()
            }
            return .succeeded
        }
        #expect(visited == [.quit, .hooks])
        #expect(report.results[.hooks] == .failed("操作已取消"))
        #expect(report.results[.helper] == .skipped("操作已取消"))
        #expect(report.summary.contains("成功 1, 失败 1, 跳过 4"))
    }

    @Test func failedProgressIncludesStepAndReason() {
        let message = AppUninstall.Step.hooks.progressMessage(.failed("Codex 不可用"))
        #expect(message == "[2/6] 移除 CodexBar Hook ... 失败 (Codex 不可用)")
    }

    @Test func removesPreferencesFileAndCacheOnlyForTargetDomain() throws {
        let preferences = try TestPreferences()
        let other = try TestPreferences()
        defer {
            preferences.remove()
            other.remove()
        }
        preferences.defaults.set("custom", forKey: "CodexCLI.source")
        preferences.defaults.set(true, forKey: "KeepAlive.isEnabled")
        other.defaults.set("preserved", forKey: "setting")
        #expect(CFPreferencesSynchronize(preferences.suite as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost))
        let url = AppUninstall.preferencesURL(domain: preferences.suite)
        #expect(FileManager.default.fileExists(atPath: url.path))

        #expect(try AppUninstall.removePreferences(domain: preferences.suite))
        try AppUninstall.verifyPreferencesRemoved(domain: preferences.suite)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(preferences.defaults.object(forKey: "CodexCLI.source") == nil)
        #expect(preferences.defaults.object(forKey: "KeepAlive.isEnabled") == nil)
        #expect(other.defaults.string(forKey: "setting") == "preserved")
        #expect(try !AppUninstall.removePreferences(domain: preferences.suite))
    }

    @Test func removesAnEmptyPreferencesPlist() throws {
        let preferences = try TestPreferences()
        let url = AppUninstall.preferencesURL(domain: preferences.suite)
        defer {
            preferences.remove()
            try? FileManager.default.removeItem(at: url)
        }
        try PropertyListSerialization.data(fromPropertyList: [String: String](), format: .xml, options: 0).write(to: url)
        #expect(try AppUninstall.removePreferences(domain: preferences.suite))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func verificationDetectsRemainingPreferences() throws {
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        preferences.defaults.set(true, forKey: "setting")
        #expect(throws: AppUninstallError.self) {
            try AppUninstall.verifyPreferencesRemoved(domain: preferences.suite)
        }
    }

    @Test(arguments: [SMAppService.Status.notRegistered, .notFound, .enabled, .requiresApproval])
    func loginItemIsRemovedOnlyWhenEnabled(status: SMAppService.Status) async throws {
        var unregistered = false
        let result = try await AppUninstall.removeLoginItem(status: status) { unregistered = true }
        #expect(unregistered == (status == .enabled))
        #expect(result == (status == .enabled ? .succeeded : .skipped("开机自动启动未启用")))
    }

    @Test(arguments: [SMAppService.Status.notRegistered, .notFound, .enabled, .requiresApproval])
    func registeredHelperIsRemovedIncludingPendingApproval(status: SMAppService.Status) async throws {
        var actions: [String] = []
        let result = try await AppUninstall.removeHelper(
            status: status,
            clearState: { actions.append("clear") },
            unregister: { actions.append("unregister") }
        )
        switch status {
        case .enabled:
            #expect(actions == ["clear", "unregister"])
            #expect(result == .succeeded)
        case .requiresApproval:
            #expect(actions == ["unregister"])
            #expect(result == .succeeded)
        default:
            #expect(actions.isEmpty)
            #expect(result == .skipped("Helper 未注册"))
        }
    }

    @Test func pendingApprovalDoesNotRequireAWorkingXPCConnection() async throws {
        var unregistered = false
        let result = try await AppUninstall.removeHelper(
            status: .requiresApproval,
            clearState: { throw AppUninstallError("XPC 不可用") },
            unregister: { unregistered = true }
        )
        #expect(unregistered)
        #expect(result == .succeeded)
    }

    @Test func activeHelperIsRetainedWhenStateCleanupFails() async throws {
        var unregistered = false
        await #expect(throws: AppUninstallError.self) {
            try await AppUninstall.removeHelper(
                status: .enabled,
                clearState: { throw AppUninstallError("唤醒计划未清理") },
                unregister: { unregistered = true }
            )
        }
        #expect(!unregistered)
    }

    @Test func cleanupLeaseExcludesAppLaunchAndOtherCleanup() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cleanup.lock")
        do {
            let normal = try AppUninstallLease.acquire(exclusive: false, url: url)
            try withExtendedLifetime(normal) {
                let otherNormal = try AppUninstallLease.acquire(exclusive: false, url: url)
                _ = withExtendedLifetime(otherNormal) {
                    #expect(throws: AppUninstallError.self) { try AppUninstallLease.acquire(exclusive: true, url: url) }
                }
            }
        }
        let cleanup = try AppUninstallLease.acquire(exclusive: true, url: url)
        withExtendedLifetime(cleanup) {
            #expect(throws: AppUninstallError.self) { try AppUninstallLease.acquire(exclusive: false, url: url) }
            #expect(throws: AppUninstallError.self) { try AppUninstallLease.acquire(exclusive: true, url: url) }
        }
    }

    @Test func cleanupLeaseDoesNotFollowSymlinks() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appending(path: "target")
        try Data("unchanged".utf8).write(to: target)
        let link = directory.appending(path: "cleanup.lock")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(throws: (any Error).self) { try AppUninstallLease.acquire(exclusive: true, url: link) }
        #expect(try String(contentsOf: target, encoding: .utf8) == "unchanged")
    }

    @Test(arguments: ["Stop", "FutureEvent"])
    func removesOnlyCurrentExecutableHooksAndCanRepeat(event: String) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "hooks.json")
        let executable = "/Applications/CodexBar.app/Contents/MacOS/CodexBar"
        let other = "'/Applications/CodexBar Debug.app/Contents/MacOS/CodexBar' --hook-event"
        let config: [String: Any] = [
            "unrelated": ["keep": true],
            "hooks": [event: [["hooks": [
                ["type": "command", "command": "'\(executable)' --hook-event"],
                ["type": "command", "command": other],
                ["type": "command", "command": "echo user-hook"]
            ]]]]
        ]
        try JSONSerialization.data(withJSONObject: config).write(to: url)
        let removed = try await UninstallHookCleanup().remove(hooksURL: url, executablePath: executable, client: MockUninstallHookClient(hooksURL: url))
        #expect(removed)
        let data = try Data(contentsOf: url)
        let result = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(try AdvancedModeSettings.removingHooksForUninstall(from: data, executablePath: executable) == nil)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains(other))
        #expect(text.contains("echo user-hook"))
        #expect((result["unrelated"] as? [String: Bool])?["keep"] == true)
        let removedAgain = try await UninstallHookCleanup().remove(hooksURL: url, executablePath: executable, client: MockUninstallHookClient(hooksURL: url))
        #expect(!removedAgain)
        try await UninstallHookCleanup().verifyRemoved(hooksURL: url, executablePath: executable)
        #expect(try Data(contentsOf: url) == data)
    }

    @Test func absentHookFileIsNotCreated() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "missing.json")
        let client = MockUninstallHookClient(hooksURL: url)
        let removed = try await UninstallHookCleanup().remove(hooksURL: url, executablePath: "/test/app", client: client)
        #expect(!removed)
        #expect(await client.lists == 0)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        try await UninstallHookCleanup().verifyRemoved(hooksURL: url, executablePath: "/test/app")
    }

    @Test func otherHooksDoNotRequireCodexForCleanup() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "hooks.json")
        let data = Data(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo user-hook"}]}]}}"#.utf8)
        try data.write(to: url)
        let client = MockUninstallHookClient(hooksURL: url)
        let removed = try await UninstallHookCleanup().remove(hooksURL: url, executablePath: "/test/app", client: client)
        #expect(!removed)
        #expect(await client.lists == 0)
        #expect(try Data(contentsOf: url) == data)
    }

    @Test(arguments: [false, true])
    func verificationRejectsRemainingHooksOrRecoveryRecord(recoveryPending: Bool) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "hooks.json")
        if recoveryPending {
            try Data("{}".utf8).write(to: HookConfigurationAccess.recoveryURL(for: url))
        } else {
            try Data(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"'/test/app' --hook-event"}]}]}}"#.utf8).write(to: url)
        }
        await #expect(throws: AppUninstallError.self) {
            try await UninstallHookCleanup().verifyRemoved(hooksURL: url, executablePath: "/test/app")
        }
    }

    @Test(arguments: ["{invalid", "{\"hooks\":123}"])
    func corruptHookFileIsPreserved(contents: String) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "hooks.json")
        let data = Data(contents.utf8)
        try data.write(to: url)
        await #expect(throws: (any Error).self) {
            try await UninstallHookCleanup().remove(hooksURL: url, executablePath: "/test/app", client: MockUninstallHookClient(hooksURL: url))
        }
        #expect(try Data(contentsOf: url) == data)
    }

    @Test func trustRemovalPreservesOtherRecordsAndChecksVersion() throws {
        let url = URL(fileURLWithPath: "/test/config.toml")
        let other: [String: Any] = ["trusted_hash": "user-hash", "enabled": false, "future": ["values": [1, 2, 3]]]
        let state: [String: Any] = ["owned": ["trusted_hash": "owned-hash"], "other": other]
        let response = try trustConfig(state: state)
        let layer = try response.userLayer(at: url)
        let record = try #require(layer.config.hooks?.state?["other"])
        let params = try response.writeParameters(state: ["other": record], configURL: url)
        #expect(params["expectedVersion"] as? String == "revision-1")
        #expect(params["filePath"] as? String == url.path)
        let edits = try #require(params["edits"] as? [[String: Any]])
        #expect(edits.count == 1)
        #expect(edits[0]["keyPath"] as? String == "hooks.state")
        #expect(edits[0]["mergeStrategy"] as? String == "replace")
        let remaining = try #require(edits[0]["value"] as? [String: Any])
        #expect(remaining["owned"] == nil)
        #expect((remaining["other"] as? NSDictionary) == other as NSDictionary)
        #expect(remaining.count == 1)
    }

    @Test(arguments: ["", "wrong-path", "disabled", "project"])
    func unverifiedConfigLayerCannotBeWritten(reason: String) throws {
        let response = try trustConfig(
            state: ["owned": ["trusted_hash": "hash"]],
            path: reason == "wrong-path" ? "/other/config.toml" : "/test/config.toml",
            version: reason.isEmpty ? "" : "revision-1",
            disabledReason: reason == "disabled" ? "disabled" : nil,
            type: reason == "project" ? "project" : "user"
        )
        #expect(throws: AppUninstallError.self) {
            try response.writeParameters(state: [:], configURL: URL(fileURLWithPath: "/test/config.toml"))
        }
    }

    @Test(arguments: ["valid", "missing-key", "errors", "warnings", "empty"])
    func trustDiscoveryRequiresOwnedHooksAndCompleteResponse(scenario: String) throws {
        let hook: [String: Any] = [
            "eventName": "Stop", "command": "'/test/app' --hook-event", "enabled": false,
            "sourcePath": "/test/hooks.json", "trustStatus": "untrusted",
            "key": scenario == "missing-key" ? "" : "owned"
        ]
        var otherPath = hook
        otherPath["sourcePath"] = "/another/hooks.json"
        otherPath["key"] = "other-path"
        var otherApp = hook
        otherApp["command"] = "'/other/app' --hook-event"
        otherApp["key"] = "other-app"
        let entry: [String: Any] = [
            "cwd": "/test", "hooks": scenario == "empty" ? [] : [hook, otherPath, otherApp],
            "warnings": scenario == "warnings" ? ["incomplete"] : [],
            "errors": scenario == "errors" ? [["path": "/test/hooks.json", "message": "invalid"]] : []
        ]
        let response = try JSONDecoder().decode(CodexHooksListResponse.self, from: JSONSerialization.data(withJSONObject: ["data": [entry]]))
        if scenario == "valid" {
            #expect(try AdvancedModeSettings.uninstallHookTrustKeys(from: response, executablePath: "/test/app", hooksURL: URL(fileURLWithPath: "/test/hooks.json")) == ["owned"])
        } else {
            #expect(throws: AppUninstallError.self) {
                try AdvancedModeSettings.uninstallHookTrustKeys(from: response, executablePath: "/test/app", hooksURL: URL(fileURLWithPath: "/test/hooks.json"))
            }
        }
    }

    private func trustConfig(
        state: [String: Any], path: String = "/test/config.toml", version: String = "revision-1",
        disabledReason: String? = nil, type: String = "user"
    ) throws -> UninstallHookTrustConfig {
        let layer: [String: Any] = [
            "name": ["type": type, "file": path], "version": version,
            "config": ["hooks": ["state": state]], "disabledReason": disabledReason as Any? ?? NSNull()
        ]
        return try JSONDecoder().decode(UninstallHookTrustConfig.self, from: JSONSerialization.data(withJSONObject: ["layers": [layer]]))
    }

    @Test(arguments: [SMAppService.Status.notRegistered, .notFound, .enabled, .requiresApproval])
    func helperRegistrationStates(status: SMAppService.Status) {
        #expect(AppUninstall.isUnregistered(status) == (status == .notRegistered || status == .notFound))
    }

    private func appBundle(
        in directory: URL, name: String = "CodexBar Debug.app", identifier: String = CodexBarHelperIPC.appBundleIdentifier
    ) throws -> URL {
        let appURL = directory.appending(path: name, directoryHint: .isDirectory)
        let executable = appURL.appending(path: "Contents/MacOS/CodexBar")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": identifier, "CFBundleExecutable": "CodexBar", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: appURL.appending(path: "Contents/Info.plist"))
        try Data("test executable".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return appURL
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "AppUninstallTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final nonisolated class StaleUninstallApplication: NSRunningApplication, @unchecked Sendable {
    private let processID: pid_t

    init(processID: pid_t) {
        self.processID = processID
        super.init()
    }

    override var processIdentifier: pid_t {
        processID
    }

    override var isTerminated: Bool {
        false
    }

    override func terminate() -> Bool {
        true
    }
}
