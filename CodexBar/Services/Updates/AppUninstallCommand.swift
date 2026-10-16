import AppKit
import Darwin
import Foundation
import IOKit.pwr_mgt
import ServiceManagement

@MainActor
final class AppUninstallCommand {
    private let appURL = Bundle.main.bundleURL.resolvingSymlinksInPath()
    private var executableURL: URL?
    private var executableIdentity: [String]?
    private var lease: AppUninstallLease?
    private let helper = SMAppService.daemon(plistName: CodexBarHelperIPC.daemonPlistName)
    private let monitor = HelperRuntimeStatusMonitor()
    private var report = AppUninstall.Report()
    private var runningStep: AppUninstall.Step?
    private let updatesInPlace = isatty(STDOUT_FILENO) != 0 && ProcessInfo.processInfo.environment["TERM"] != "dumb"

    static func start() {
        let options: AppUninstallOptions
        do {
            options = try AppUninstallOptions(arguments: Array(CommandLine.arguments.dropFirst()))
        } catch {
            fail(error)
        }
        if options.showsHelp {
            print("""
            usage: CodexBar --uninstall [--keep-app]

            依次退出 CodexBar App, 移除 CodexBar Hook, 注销 CodexBar 启动项, 注销 CodexBar Helper, 移除 CodexBar 配置, 验证卸载结果
            未配置的项目会跳过, 退出失败则不执行后续清理, 其他失败不阻断独立步骤
            Helper 已注册但尚未授权时也会注销, 执行过程显示各步骤进度和结果
            前序清理成功后删除当前 App 的设置 plist 和偏好缓存, 保留历史数据
            所有清理和验证成功后将当前 App 移到废纸篓
            --keep-app  完成清理后保留 App, 仍会清理设置
            --help      显示帮助, 不执行清理
            请直接运行 App 包中的 Contents/MacOS/CodexBar, 不要使用 sudo
            """)
            exit(EXIT_SUCCESS)
        }

        // 独立命令不构造 SwiftUI App 或 AppDelegate, 系统回调仍需要主运行循环
        let command = AppUninstallCommand()
        Task { @MainActor in
            let report = await AppUninstall.run(options: options, progress: command.showProgress) { step in
                try await command.perform(step)
            }
            finish(report)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(120))
            command.finishAfterTimeout()
        }
        RunLoop.main.run()
    }

    private func showProgress(_ step: AppUninstall.Step, _ status: AppUninstall.Status) {
        if status == .running {
            runningStep = step
        } else {
            runningStep = nil
            report.results[step] = status
        }
        writeProgress(step, status)
    }

    private func showProgressDetail(_ detail: String) {
        guard let runningStep else { return }
        writeProgress(runningStep, .running, detail: detail)
    }

    private func writeProgress(_ step: AppUninstall.Step, _ status: AppUninstall.Status, detail: String? = nil) {
        let message = step.progressMessage(status, detail: detail)
        if updatesInPlace {
            let ending = status == .running ? "" : "\n"
            FileHandle.standardOutput.write(Data(("\r\u{1B}[2K" + message + ending).utf8))
        } else {
            Self.write(message)
        }
    }

    private func finishAfterTimeout() -> Never {
        let active = runningStep
        for step in AppUninstall.Step.allCases where report.results[step] == nil {
            showProgress(step, step == active ? .failed("清理超时") : .skipped("清理超时, 未执行"))
        }
        Self.finish(report)
    }

    private static func write(_ message: String) {
        FileHandle.standardOutput.write(Data((message + "\n").utf8))
    }

    private static func finish(_ report: AppUninstall.Report) -> Never {
        write(report.summary)
        exit(report.hasFailures ? EXIT_FAILURE : EXIT_SUCCESS)
    }

    private static func fail(_ error: Error) -> Never {
        FileHandle.standardError.write(Data("清理失败: \(error.localizedDescription)\n".utf8))
        exit(EXIT_FAILURE)
    }

    private func perform(_ step: AppUninstall.Step) async throws -> AppUninstall.Status {
        switch step {
        case .quit:
            try await prepareForCleanup()
        case .hooks:
            guard let executableURL else { throw AppUninstallError("缺少当前 App 可执行路径") }
            let hooksURL = AdvancedModeSettings.defaultHooksURL()
            let client = UninstallCodexClient(selection: CodexCLISourceSelection.load(from: .standard))
            do {
                let removed = try await UninstallHookCleanup().remove(hooksURL: hooksURL, executablePath: executableURL.path, client: client)
                await client.close()
                return removed ? .succeeded : .skipped("未发现当前 App 的 Hook")
            } catch {
                await client.close()
                throw error
            }
        case .loginItem:
            return try await AppUninstall.removeLoginItem(status: SMAppService.mainApp.status) {
                try await self.unregister(SMAppService.mainApp)
            }
        case .helper:
            let status = helper.status
            if status == .requiresApproval {
                showProgressDetail("未授权, 直接注销")
            }
            return try await AppUninstall.removeHelper(
                status: status, clearState: clearHelperState,
                unregister: {
                    self.showProgressDetail("注销系统服务")
                    try await self.unregister(self.helper)
                }
            )
        case .preferences:
            try await verifyTarget()
            let removed = try await Task.detached {
                try AppUninstall.removePreferences(domain: CodexBarHelperIPC.appBundleIdentifier)
            }.value
            return removed ? .succeeded : .skipped("未发现 App 设置")
        case .verify:
            try await verifyCleanup()
        case .trash:
            try await verifyTarget()
            let result = try await NSWorkspace.shared.recycle([appURL])
            guard result[appURL] != nil else { throw AppUninstallError("系统未确认 App 已移到废纸篓") }
        }
        return .succeeded
    }

    private func prepareForCleanup() async throws {
        guard getuid() != 0 else { throw AppUninstallError("请以当前登录用户运行, 不要使用 sudo") }
        let appURL = appURL
        let executable = try await Task.detached {
            let executable = try AppUninstall.validatedExecutableURL(appURL: appURL)
            guard try appURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly == false else {
                throw AppUninstallError("当前 App 位于只读卷或无法确认卷状态, 请从可写位置运行命令")
            }
            switch KeepAliveHelperConfiguration.validatePackage(appURL: appURL, machServiceName: CodexBarHelperIPC.machServiceName) {
            case .missing:
                throw AppUninstallError("当前 App 缺少 Helper 可执行文件或服务配置")
            case .invalid:
                throw AppUninstallError("当前 App 或 Helper 的签名或服务配置无效")
            case nil:
                break
            }
            return executable
        }.value
        executableURL = executable
        executableIdentity = try await fileIdentity(executable)
        try await Self.quitApplications(otherApplications())
        lease = try AppUninstallLease.acquire(exclusive: true)
        try await verifyTarget()
    }

    static func quitApplications(_ applications: [NSRunningApplication], timeout: Duration = .seconds(30)) async throws {
        // 退出后 AppKit 属性可能失效, 请求退出前固定要等待的进程标识
        let processIDs = applications.map(\.processIdentifier)
        for (app, processID) in zip(applications, processIDs) where isProcessRunning(processID) {
            guard app.terminate() || !isProcessRunning(processID) else {
                throw AppUninstallError("App 拒绝退出, 请手动退出后重试")
            }
        }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while processIDs.contains(where: isProcessRunning) {
            guard ContinuousClock.now < deadline else { throw AppUninstallError("等待旧 App 退出超时, 未强制结束进程") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private static func isProcessRunning(_ processID: pid_t) -> Bool {
        guard processID > 0 else { return true }
        // AppKit 状态可能滞后, 已退出但尚未被父进程回收的进程也不应阻挡清理
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        errno = 0
        let count = proc_pidinfo(processID, PROC_PIDTBSDINFO, 0, &info, size)
        if count == size {
            return info.pbi_status != SZOMB
        }
        return count != 0 || errno != ESRCH
    }

    private func verifyCleanup() async throws {
        try await verifyTarget()
        guard let executableURL else { throw AppUninstallError("缺少当前 App 可执行路径") }
        var failures: [String] = []
        do {
            try await UninstallHookCleanup().verifyRemoved(hooksURL: AdvancedModeSettings.defaultHooksURL(), executablePath: executableURL.path)
        } catch {
            failures.append(error.localizedDescription)
        }
        switch SMAppService.mainApp.status {
        case .enabled: failures.append("开机自动启动仍启用")
        case .notRegistered, .notFound, .requiresApproval: break
        @unknown default: failures.append("无法确认开机启动项状态")
        }
        if !AppUninstall.isUnregistered(helper.status) {
            failures.append("Helper 仍注册")
        }
        if Self.hasWakeSchedule() {
            failures.append("自动重置唤醒计划仍存在")
        }
        do {
            try await verifyHelperStopped()
        } catch {
            failures.append(error.localizedDescription)
        }
        if !report.hasFailures {
            do {
                try await Task.detached {
                    try AppUninstall.verifyPreferencesRemoved(domain: CodexBarHelperIPC.appBundleIdentifier)
                }.value
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        guard failures.isEmpty else { throw AppUninstallError(failures.joined(separator: "; ")) }
    }

    private func otherApplications() throws -> [NSRunningApplication] {
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: CodexBarHelperIPC.appBundleIdentifier)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated && Self.isProcessRunning($0.processIdentifier) }
        guard applications.allSatisfy({ $0.bundleURL?.resolvingSymlinksInPath() == appURL }) else {
            throw AppUninstallError("另一个路径的 CodexBar 正在运行, 请先退出它再重试")
        }
        return applications
    }

    private func verifyTarget() async throws {
        guard try otherApplications().isEmpty,
              let executableURL, let executableIdentity,
              try await fileIdentity(executableURL) == executableIdentity else {
            throw AppUninstallError("App 被重新启动或安装内容发生变化, 已停止清理")
        }
    }

    private func fileIdentity(_ url: URL) async throws -> [String] {
        try await Task.detached {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return [
                String(describing: attributes[.systemNumber]), String(describing: attributes[.systemFileNumber]),
                String(describing: attributes[.size]), String(describing: attributes[.modificationDate])
            ]
        }.value
    }

    private func unregister(_ service: SMAppService) async throws {
        if AppUninstall.isUnregistered(service.status) {
            return
        }
        guard service.status == .enabled || service.status == .requiresApproval else {
            throw AppUninstallError("无法确认系统服务的注册状态")
        }
        try await service.unregister()
        guard AppUninstall.isUnregistered(service.status) else { throw AppUninstallError("系统未确认服务已注销") }
    }

    private func clearHelperState() async throws {
        guard helper.status == .enabled else { throw AppUninstallError("Helper 状态不可用") }
        let connection = NSXPCConnection(machServiceName: CodexBarHelperIPC.machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: CodexBarHelperProtocol.self)
        connection.resume()
        defer {
            monitor.cancelRequest()
            connection.invalidate()
        }
        if Self.hasWakeSchedule() {
            showProgressDetail("取消自动重置唤醒计划")
            guard case .success = await monitor.setAutoResetWakeSchedule(connection: connection, unixTimestamp: 0, timeout: .seconds(10)),
                  !Self.hasWakeSchedule() else { throw AppUninstallError("无法取消并验证自动重置唤醒计划") }
        }

        // 等旧连接的租约释放, 只核对 Helper 所有权, 不覆盖其他程序设置的防睡眠状态
        showProgressDetail("确认旧连接已释放防睡眠状态")
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while true {
            guard let status = await monitor.fetch(connection: connection, timeout: .seconds(10), onConnectionFailure: { _ in }, onTimeout: {}) else {
                throw AppUninstallError("无法确认 Helper 已释放防睡眠状态")
            }
            if status.ownership == .idle, status.activeClientCount == 0 {
                return
            }
            guard ContinuousClock.now < deadline else { throw AppUninstallError("Helper 仍持有防睡眠状态, 请稍后重试") }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    private static func hasWakeSchedule() -> Bool {
        guard let events = IOPMCopyScheduledPowerEvents()?.takeRetainedValue() else { return false }
        return (events as NSArray).contains { value in
            guard let event = value as? NSDictionary else { return false }
            return event[kIOPMPowerEventAppNameKey] as? String == CodexBarHelperIPC.machServiceName + ".auto-reset"
        }
    }

    private func verifyHelperStopped() async throws {
        let stopped = try await Task.detached {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["print", "system/\(CodexBarHelperIPC.machServiceName)"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = output
            try process.run()
            let deadline = Date().addingTimeInterval(3)
            while process.isRunning, Date() < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            guard !process.isRunning else {
                _ = ProcessTermination.terminate(process, gracefulTimeout: 0.2, killTimeout: 0.2)
                throw AppUninstallError("系统服务查询超时")
            }
            let error = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return process.terminationStatus == 113 && error.contains("Could not find service \"\(CodexBarHelperIPC.machServiceName)\"")
        }.value
        guard stopped else { throw AppUninstallError("未确认 Helper 已从系统服务中移除, App 已保留") }
    }
}
