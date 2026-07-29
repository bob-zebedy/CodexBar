import Darwin
import Foundation
import os
import Security

private let helperLog = Logger(
    subsystem: CodexBarHelperIPC.machServiceName,
    category: "helper"
)

private enum CodexBarHelperStorage {
    static let sentinelURL: URL = {
        guard let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .localDomainMask
        ).first else {
            // launchd 会立刻重新拉起来, 不留痕就成了查不出原因的崩溃循环
            helperLog.error("Helper 启动失败: reason=applicationSupportMissing")
            exit(EXIT_FAILURE)
        }
        return applicationSupportURL
            .appending(path: "CodexBar", directoryHint: .isDirectory)
            .appending(path: CodexBarHelperIPC.machServiceName + ".state")
    }()
}

private struct PmsetResult {
    let exitCode: Int32
    let output: String
}

private struct SleepRestoreResult {
    let exitCode: Int32
    let restoredSleepDisabled: Bool
}

/// 哨兵必须区分三态: 「不存在」和「读不出来」的处理方式完全相反
/// 把读取失败折叠成 nil 会让恢复流程认为无需恢复, 使 SleepDisabled=1 永久残留
private enum SentinelState {
    case absent
    case present(previouslyDisabled: Bool)
    case unreadable(Error)

    /// 读取失败也必须进入恢复流程: 记录损坏时无法排除「休眠正被我们禁用着」
    var needsRestore: Bool {
        switch self {
        case .absent:
            false
        case .present, .unreadable:
            true
        }
    }
}

private enum SleepRestoreTrigger: String {
    case appRequest
    case connectionWatchdog
    case helperStartup
    case sentinelCheck
    case helperTermination
}

// MARK: - pmset 调用

private enum PmsetRunner {
    static func setSleepDisabled(_ disabled: Bool) -> PmsetResult {
        run(arguments: ["-a", "disablesleep", disabled ? "1" : "0"])
    }

    static func currentSleepDisabled() -> (result: PmsetResult, value: Bool?) {
        let result = run(arguments: ["-g"])
        return (result, parseSleepDisabled(from: result.output))
    }

    private static func run(arguments: [String]) -> PmsetResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return PmsetResult(exitCode: -1, output: error.localizedDescription)
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return PmsetResult(
            exitCode: process.terminationStatus,
            output: String(data: data, encoding: .utf8) ?? ""
        )
    }

    private static func parseSleepDisabled(from output: String) -> Bool? {
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2, fields[0] == "SleepDisabled" else {
                continue
            }
            switch fields[1] {
            case "0":
                return false
            case "1":
                return true
            default:
                return nil
            }
        }
        // pmset 只在 disablesleep=1 时输出 SleepDisabled; 字段缺失表示默认值 0
        return false
    }
}

private final class CodexBarHelperRuntime: NSObject, NSXPCListenerDelegate, CodexBarHelperProtocol,
    @unchecked Sendable {
    private let queue = DispatchQueue(label: CodexBarHelperIPC.machServiceName + ".state")
    private let sentinelURL = CodexBarHelperStorage.sentinelURL
    private var connections = Set<ObjectIdentifier>()
    private var watchdog: DispatchWorkItem?
    private var sentinelTimer: DispatchSourceTimer?
    private var signalSources = [DispatchSourceSignal]()
    private var listener: NSXPCListener?

    func run() {
        guard geteuid() == 0 else {
            helperLog.error("Helper 启动失败: reason=notRoot")
            exit(EXIT_FAILURE)
        }

        do {
            try ensureSentinelDirectory()
        } catch {
            let sentinelDirectoryPath = sentinelURL.deletingLastPathComponent().path
            helperLog.error(
                "Helper 启动失败: reason=sentinelDirectory; path=\(sentinelDirectoryPath, privacy: .public); detail=\(error.localizedDescription, privacy: .public)"
            )
            exit(EXIT_FAILURE)
        }

        // 启动时哨兵还在说明上次异常退出, 这条是判断有没有残留过的起点
        // 读一次就够, 恢复判断也用这同一份结果
        let startupSentinel = sentinelState()
        let sentinelName = switch startupSentinel {
        case .absent: "absent"
        case .present: "present"
        case .unreadable: "unreadable"
        }
        helperLog.notice("Helper 已启动: sentinel=\(sentinelName, privacy: .public)")

        // 读取失败也必须进入恢复流程: 记录损坏时无法排除「休眠正被我们禁用着」
        if startupSentinel.needsRestore {
            _ = restoreSleep(trigger: .helperStartup)
        }

        installSentinelTimer()
        installSignalHandlers()

        let clientCodeSigningRequirement: String
        do {
            clientCodeSigningRequirement = try Self.makeClientCodeSigningRequirement()
        } catch {
            helperLog.error(
                "Helper 启动失败: reason=listener; detail=\(error.localizedDescription, privacy: .public)"
            )
            exit(EXIT_FAILURE)
        }

        let listener = NSXPCListener(machServiceName: CodexBarHelperIPC.machServiceName)
        listener.setConnectionCodeSigningRequirement(clientCodeSigningRequirement)
        listener.delegate = self
        listener.resume()
        self.listener = listener
    }

    // MARK: - XPC 接口

    func setSleepDisabled(
        _ disabled: Bool,
        reply: @escaping @Sendable (Int32, Bool) -> Void
    ) {
        queue.async { [self] in
            if disabled {
                reply(disableSleep(), true)
            } else {
                let result = restoreSleep(trigger: .appRequest)
                reply(result.exitCode, result.restoredSleepDisabled)
            }
        }
    }

    func listener(
        _: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        let identifier = ObjectIdentifier(newConnection)
        newConnection.exportedInterface = NSXPCInterface(
            with: CodexBarHelperProtocol.self
        )
        newConnection.exportedObject = self

        let connectionDropped: () -> Void = { [weak self] in
            self?.connectionDropped(identifier)
        }
        newConnection.invalidationHandler = connectionDropped
        newConnection.interruptionHandler = connectionDropped

        queue.sync {
            connections.insert(identifier)
            watchdog?.cancel()
            watchdog = nil
        }
        newConnection.resume()
        return true
    }

    private func connectionDropped(_ identifier: ObjectIdentifier) {
        queue.async { [self] in
            guard connections.remove(identifier) != nil,
                  connections.isEmpty,
                  sentinelNeedsRestore() else {
                return
            }

            watchdog?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else {
                    return
                }
                watchdog = nil
                guard connections.isEmpty, sentinelNeedsRestore() else {
                    return
                }
                _ = restoreSleep(trigger: .connectionWatchdog)
            }
            watchdog = workItem
            queue.asyncAfter(
                deadline: .now() + CodexBarHelperIPC.watchdogGraceSeconds,
                execute: workItem
            )
        }
    }

    // MARK: - 休眠切换与恢复

    private func disableSleep() -> Int32 {
        var didCreateSentinel = false
        // 哨兵记的是接管前系统原本的 SleepDisabled, 恢复要还原到它而不是无脑写 0
        var sentinelValue = "-"
        switch sentinelState() {
        case let .present(previouslyDisabled):
            sentinelValue = previouslyDisabled ? "1" : "0"
        case let .unreadable(error):
            // 不能用当前的 SleepDisabled 覆写损坏的记录: 当前值可能正是我们自己禁用的结果
            // 那会把「原本允许休眠」错记成「原本已禁用」让后续恢复永久跳过
            let sentinelPath = sentinelURL.path
            helperLog.error(
                "休眠哨兵损坏: path=\(sentinelPath, privacy: .public); detail=\(error.localizedDescription, privacy: .public)"
            )
            return -1
        case .absent:
            let current = PmsetRunner.currentSleepDisabled()
            guard current.result.exitCode == 0, let wasDisabled = current.value else {
                helperLog.error(
                    "pmset 读取失败: exit=\(current.result.exitCode); detail=\(current.result.output, privacy: .public)"
                )
                return current.result.exitCode == 0 ? -1 : current.result.exitCode
            }

            do {
                try writeSentinel(previouslyDisabled: wasDisabled)
                didCreateSentinel = true
                sentinelValue = wasDisabled ? "1" : "0"
            } catch {
                let sentinelPath = sentinelURL.path
                helperLog.error(
                    "休眠哨兵写入失败: path=\(sentinelPath, privacy: .public); detail=\(error.localizedDescription, privacy: .public)"
                )
                return -1
            }
        }

        let result = PmsetRunner.setSleepDisabled(true)
        guard result.exitCode == 0 else {
            if didCreateSentinel {
                try? FileManager.default.removeItem(at: sentinelURL)
            }
            helperLog.error(
                "系统休眠关闭失败: exit=\(result.exitCode); detail=\(result.output, privacy: .public)"
            )
            return result.exitCode
        }

        helperLog.notice("系统休眠已关闭: sentinel=\(sentinelValue, privacy: .public)")
        return 0
    }

    @discardableResult
    private func restoreSleep(trigger: SleepRestoreTrigger) -> SleepRestoreResult {
        let previouslyDisabled: Bool
        switch sentinelState() {
        case .absent:
            // 没接管过就没有要恢复的东西, 这个值只是占位, 不代表系统真实状态
            // 必须保持 true: App 用它抑制补发合盖休眠, 换成实测值会让从未接管的这一轮把机器按睡
            return SleepRestoreResult(exitCode: 0, restoredSleepDisabled: true)
        case let .present(value):
            previouslyDisabled = value
        case let .unreadable(error):
            // 读不出原值时按系统默认的「允许休眠」恢复
            // 宁可多恢复一次(pmset 幂等), 也不能把 SleepDisabled=1 永久留给用户
            helperLog.error(
                "休眠哨兵读取失败: trigger=\(trigger.rawValue, privacy: .public); detail=\(error.localizedDescription, privacy: .public); action=forceRestore"
            )
            previouslyDisabled = false
        }

        let previousValue = previouslyDisabled ? 1 : 0
        let result = PmsetRunner.setSleepDisabled(previouslyDisabled)
        guard result.exitCode == 0 else {
            helperLog.error(
                "系统休眠恢复失败: trigger=\(trigger.rawValue, privacy: .public); sleepDisabled=\(previousValue); exit=\(result.exitCode); detail=\(result.output, privacy: .public)"
            )
            return SleepRestoreResult(
                exitCode: result.exitCode,
                restoredSleepDisabled: true
            )
        }

        try? FileManager.default.removeItem(at: sentinelURL)
        helperLog.notice(
            "系统休眠已恢复: trigger=\(trigger.rawValue, privacy: .public); sleepDisabled=\(previousValue)"
        )
        return SleepRestoreResult(
            exitCode: 0,
            restoredSleepDisabled: previouslyDisabled
        )
    }

    private func installSentinelTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + CodexBarHelperIPC.sentinelCheckIntervalSeconds,
            repeating: CodexBarHelperIPC.sentinelCheckIntervalSeconds,
            leeway: .seconds(5)
        )
        timer.setEventHandler { [weak self] in
            guard let self,
                  connections.isEmpty,
                  watchdog == nil,
                  sentinelNeedsRestore() else {
                return
            }
            _ = restoreSleep(trigger: .sentinelCheck)
        }
        timer.resume()
        sentinelTimer = timer
    }

    private func installSignalHandlers() {
        for signalNumber in [SIGTERM, SIGINT] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: queue)
            source.setEventHandler { [weak self] in
                guard let self else {
                    exit(EXIT_SUCCESS)
                }
                // 和另外三个触发源一样先判断: 空闲态退出没有东西要恢复, 不必再 fork 一次 pmset
                if sentinelNeedsRestore() {
                    _ = restoreSleep(trigger: .helperTermination)
                }
                exit(EXIT_SUCCESS)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: - 恢复哨兵

    private func ensureSentinelDirectory() throws {
        let directoryURL = sentinelURL.deletingLastPathComponent()
        var info = stat()
        if lstat(directoryURL.path, &info) == 0 {
            try validateSentinelDirectory(info)
            return
        }

        guard errno == ENOENT else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: false
        )
        try FileManager.default.setAttributes(
            [.ownerAccountID: 0, .groupOwnerAccountID: 0, .posixPermissions: 0o755],
            ofItemAtPath: directoryURL.path
        )
    }

    private func validateSentinelDirectory(_ info: stat) throws {
        guard info.st_mode & S_IFMT == S_IFDIR else {
            throw CodexBarHelperError.insecureSentinelDirectory(
                "目录类型错误: actual=\(fileTypeName(info.st_mode)); expected=directory"
            )
        }
        guard info.st_uid == 0 else {
            throw CodexBarHelperError.insecureSentinelDirectory(
                "所有者错误: actual=\(info.st_uid); expected=0"
            )
        }
        guard info.st_mode & 0o022 == 0 else {
            throw CodexBarHelperError.insecureSentinelDirectory(
                "目录权限错误: actual=\(permissionString(info.st_mode)); forbidden=0022"
            )
        }
    }

    private func writeSentinel(previouslyDisabled: Bool) throws {
        try Data(previouslyDisabled ? "1".utf8 : "0".utf8).write(
            to: sentinelURL,
            options: .atomic
        )
        try FileManager.default.setAttributes(
            [.ownerAccountID: 0, .groupOwnerAccountID: 0, .posixPermissions: 0o600],
            ofItemAtPath: sentinelURL.path
        )
        guard try readSentinelPreviousState() != nil else {
            throw CodexBarHelperError.invalidSentinel("记录不存在")
        }
    }

    private func sentinelState() -> SentinelState {
        do {
            guard let previouslyDisabled = try readSentinelPreviousState() else {
                return .absent
            }
            return .present(previouslyDisabled: previouslyDisabled)
        } catch {
            return .unreadable(error)
        }
    }

    private func sentinelNeedsRestore() -> Bool {
        sentinelState().needsRestore
    }

    private func readSentinelPreviousState() throws -> Bool? {
        var info = stat()
        guard lstat(sentinelURL.path, &info) == 0 else {
            if errno == ENOENT {
                return nil
            }
            throw CodexBarHelperError.invalidSentinel(
                "读取属性失败: errno=\(errno)"
            )
        }
        guard info.st_mode & S_IFMT == S_IFREG else {
            throw CodexBarHelperError.invalidSentinel(
                "文件类型错误: actual=\(fileTypeName(info.st_mode)); expected=file"
            )
        }
        guard info.st_uid == 0 else {
            throw CodexBarHelperError.invalidSentinel(
                "所有者错误: actual=\(info.st_uid); expected=0"
            )
        }
        guard info.st_mode & 0o022 == 0 else {
            throw CodexBarHelperError.invalidSentinel(
                "文件权限错误: actual=\(permissionString(info.st_mode)); forbidden=0022"
            )
        }

        let data: Data
        do {
            data = try Data(contentsOf: sentinelURL)
        } catch {
            throw CodexBarHelperError.invalidSentinel(
                "读取内容失败: detail=\(error.localizedDescription)"
            )
        }
        guard let value = String(data: data, encoding: .utf8) else {
            throw CodexBarHelperError.invalidSentinel(
                "文件编码错误: actual=unknown; expected=UTF-8"
            )
        }

        switch value {
        case "0":
            return false
        case "1":
            return true
        default:
            throw CodexBarHelperError.invalidSentinel(
                "文件内容错误: actual=\(data.count); expected=0|1"
            )
        }
    }

    private func fileTypeName(_ mode: mode_t) -> String {
        let type = mode & S_IFMT
        if type == S_IFREG {
            return "file"
        }
        if type == S_IFDIR {
            return "directory"
        }
        if type == S_IFLNK {
            return "symlink"
        }
        return String(format: "0x%X", Int32(type))
    }

    private func permissionString(_ mode: mode_t) -> String {
        String(format: "%04o", Int32(mode & 0o7777))
    }

    private static func makeClientCodeSigningRequirement() throws -> String {
        var runningCode: SecCode?
        var status = SecCodeCopySelf(SecCSFlags(), &runningCode)
        guard status == errSecSuccess, let runningCode else {
            throw CodexBarHelperError.codeSigningValidationFailed(
                "读取运行签名失败: Operation=SecCodeCopySelf; Status=\(status)"
            )
        }

        var staticCode: SecStaticCode?
        status = SecCodeCopyStaticCode(runningCode, SecCSFlags(), &staticCode)
        guard status == errSecSuccess, let staticCode else {
            throw CodexBarHelperError.codeSigningValidationFailed(
                "读取静态签名失败: Operation=SecCodeCopyStaticCode; Status=\(status)"
            )
        }

        var signingInformation: CFDictionary?
        status = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInformation
        )
        guard status == errSecSuccess, let signingInformation else {
            throw CodexBarHelperError.codeSigningValidationFailed(
                "读取签名信息失败: Operation=SecCodeCopySigningInformation; Status=\(status)"
            )
        }

        let values = signingInformation as NSDictionary
        guard let teamIdentifier = values[kSecCodeInfoTeamIdentifier] as? String else {
            throw CodexBarHelperError.codeSigningValidationFailed("Team ID 缺失")
        }
        guard let helperIdentifier = values[kSecCodeInfoIdentifier] as? String else {
            throw CodexBarHelperError.codeSigningValidationFailed("Helper 标识符缺失")
        }

        let helperSuffix = CodexBarHelperIPC.helperBundleIdentifierSuffix
        guard helperIdentifier.hasSuffix(helperSuffix) else {
            throw CodexBarHelperError.codeSigningValidationFailed(
                "Helper 标识符错误: actual=\(helperIdentifier); expected=*\(helperSuffix)"
            )
        }

        let clientIdentifier = String(helperIdentifier.dropLast(helperSuffix.count))
        let identifierCharacters = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: ".-")
        )
        guard !teamIdentifier.isEmpty else {
            throw CodexBarHelperError.codeSigningValidationFailed("Team ID 为空")
        }
        guard teamIdentifier.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains) else {
            throw CodexBarHelperError.codeSigningValidationFailed(
                "Team ID 格式错误: \(teamIdentifier)"
            )
        }
        guard !clientIdentifier.isEmpty else {
            throw CodexBarHelperError.codeSigningValidationFailed("客户端标识符为空")
        }
        guard clientIdentifier.unicodeScalars.allSatisfy(identifierCharacters.contains) else {
            throw CodexBarHelperError.codeSigningValidationFailed(
                "客户端标识符格式错误: \(clientIdentifier)"
            )
        }

        return "anchor apple generic"
            + " and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
            + " and identifier \"\(clientIdentifier)\""
    }
}

private enum CodexBarHelperError: LocalizedError {
    case insecureSentinelDirectory(String)
    case invalidSentinel(String)
    case codeSigningValidationFailed(String)

    var errorDescription: String? {
        switch self {
        case let .insecureSentinelDirectory(detail):
            "休眠设置目录无效: \(detail)"
        case let .invalidSentinel(detail):
            "休眠设置记录无效: \(detail)"
        case let .codeSigningValidationFailed(reason):
            "签名校验失败: \(reason)"
        }
    }
}

private let runtime = CodexBarHelperRuntime()
runtime.run()
dispatchMain()
