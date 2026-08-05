import Darwin
import Foundation
import os
import Security

private let helperLog = Logger(
    subsystem: CodexBarHelperIPC.machServiceName,
    category: "helper"
)

private enum LogFields {
    static func joined(_ fields: String...) -> String {
        fields.joined(separator: "; ")
    }
}

private enum CodexBarHelperStorage {
    static let ownershipURL: URL = {
        guard let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .localDomainMask
        ).first else {
            helperLog.error("Helper 启动失败: reason=applicationSupportMissing")
            exit(EXIT_FAILURE)
        }
        return applicationSupportURL
            .appending(path: "CodexBar", directoryHint: .isDirectory)
            .appending(path: "helper-state.json")
    }()
}

private struct PmsetResult {
    let exitCode: Int32
    let output: String
}

private struct SleepOperationResult {
    let exitCode: Int32
    let source: CodexBarSleepPreventionSource
    let sleepDisabled: Bool
}

private struct ClientLease {
    var generation: UInt64
    var isRequesting: Bool
    var connectionIdentifier: UUID?
}

private enum SleepOwnership: String, Codable {
    case idle
    case owned
    case restoring

    var needsRestore: Bool {
        self != .idle
    }

    var sharedState: CodexBarSleepOwnershipState {
        switch self {
        case .idle:
            .idle
        case .owned:
            .owned
        case .restoring:
            .restoring
        }
    }
}

private struct SleepOwnershipRecord: Codable {
    let schema: Int
    let state: SleepOwnership
    let transaction: UUID
    let identifier: String?
    let updated: Date
}

private enum OwnershipRecordState {
    case absent
    case present(SleepOwnershipRecord)
    case unreadable(Error)
}

private enum SleepRestoreTrigger: String {
    case appRequest
    case connectionWatchdog
    case helperStartup
    case ownershipCheck
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
        // pmset 只在 disablesleep=1 时输出 SleepDisabled, 字段缺失表示默认值 0
        return false
    }
}

private final class CodexBarHelperConnectionSession: NSObject, CodexBarHelperProtocol,
    @unchecked Sendable {
    let identifier = UUID()
    private weak var runtime: CodexBarHelperRuntime?

    init(runtime: CodexBarHelperRuntime) {
        self.runtime = runtime
    }

    func setSleepPreventionRequested(
        _ requested: Bool,
        clientSessionID: String,
        generation: UInt64,
        reply: @escaping @Sendable (Int32, Int, Bool) -> Void
    ) {
        guard let runtime else {
            reply(-1, CodexBarSleepPreventionSource.none.rawValue, false)
            return
        }
        runtime.setSleepPreventionRequested(
            requested,
            clientSessionID: clientSessionID,
            generation: generation,
            for: identifier,
            reply: reply
        )
    }

    func getSleepPreventionStatus(
        reply: @escaping @Sendable (Int32, Int, Int, Bool) -> Void
    ) {
        guard let runtime else {
            reply(-1, CodexBarSleepOwnershipState.idle.rawValue, 0, false)
            return
        }
        runtime.getSleepPreventionStatus(
            for: identifier,
            reply: reply
        )
    }

    func resetSleepAfterUpdate(
        _ updateIdentifier: String,
        reply: @escaping @Sendable (Int32) -> Void
    ) {
        guard let runtime else {
            reply(-1)
            return
        }
        runtime.resetSleepAfterUpdate(
            updateIdentifier,
            for: identifier,
            reply: reply
        )
    }
}

private final class CodexBarHelperRuntime: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: CodexBarHelperIPC.machServiceName + ".state")
    private let ownershipURL = CodexBarHelperStorage.ownershipURL
    private var ownership = SleepOwnership.idle
    private var transactionID = UUID()
    private var lastCompletedUpdateIdentifier: String?
    private var connections = Set<UUID>()
    private var clients = [UUID: ClientLease]()
    private var watchdogs = [UUID: DispatchWorkItem]()
    private var watchdogTokens = [UUID: UUID]()
    private var lastKnownSleepDisabled: Bool?
    private var ownershipTimer: DispatchSourceTimer?
    private var scheduledOwnershipCheckInterval: TimeInterval?
    private var signalSources = [DispatchSourceSignal]()
    private var listener: NSXPCListener?

    func run() {
        guard geteuid() == 0 else {
            helperLog.error("Helper 启动失败: reason=notRoot")
            exit(EXIT_FAILURE)
        }

        do {
            try ensureOwnershipDirectory()
        } catch {
            let directoryPath = ownershipURL.deletingLastPathComponent().path
            let details = LogFields.joined(
                "reason=ownershipDirectory",
                "path=\(directoryPath)",
                "detail=\(error.localizedDescription)"
            )
            helperLog.error("Helper 启动失败: \(details, privacy: .public)")
            exit(EXIT_FAILURE)
        }

        recoverOwnershipAtStartup()
        installOwnershipTimer()
        installSignalHandlers()

        let clientCodeSigningRequirement: String
        do {
            clientCodeSigningRequirement = try Self.makeClientCodeSigningRequirement()
        } catch {
            let details = LogFields.joined(
                "reason=listener",
                "detail=\(error.localizedDescription)"
            )
            helperLog.error("Helper 启动失败: \(details, privacy: .public)")
            exit(EXIT_FAILURE)
        }

        let listener = NSXPCListener(machServiceName: CodexBarHelperIPC.machServiceName)
        listener.setConnectionCodeSigningRequirement(clientCodeSigningRequirement)
        listener.delegate = self
        listener.resume()
        self.listener = listener
    }

    // MARK: - XPC 接口

    fileprivate func setSleepPreventionRequested(
        _ requested: Bool,
        clientSessionID: String,
        generation: UInt64,
        for identifier: UUID,
        reply: @escaping @Sendable (Int32, Int, Bool) -> Void
    ) {
        queue.async { [self] in
            guard connections.contains(identifier),
                  let clientIdentifier = UUID(uuidString: clientSessionID) else {
                reply(-1, CodexBarSleepPreventionSource.none.rawValue, false)
                return
            }

            if let currentLease = clients[clientIdentifier] {
                guard generation >= currentLease.generation else {
                    let result = currentOperationResult()
                    reply(result.exitCode, result.source.rawValue, result.sleepDisabled)
                    return
                }
                guard generation != currentLease.generation
                    || requested == currentLease.isRequesting else {
                    reply(-1, currentSource().rawValue, lastKnownSleepDisabled ?? false)
                    return
                }
            }

            cancelWatchdog(for: clientIdentifier)
            let source = currentSource()
            clients[clientIdentifier] = ClientLease(
                generation: generation,
                isRequesting: requested,
                connectionIdentifier: identifier
            )

            let result: SleepOperationResult
            if requested {
                let isNewRequest = source == .none
                result = reconcileRequestedSleep(logsExternalState: isNewRequest)
            } else {
                result = reconcileReleasedSleep(source: source, trigger: .appRequest)
            }
            scheduleOwnershipTimerIfNeeded()
            reply(result.exitCode, result.source.rawValue, result.sleepDisabled)
        }
    }

    fileprivate func getSleepPreventionStatus(
        for identifier: UUID,
        reply: @escaping @Sendable (Int32, Int, Int, Bool) -> Void
    ) {
        queue.async { [self] in
            guard connections.contains(identifier),
                  let lastKnownSleepDisabled else {
                reply(-1, ownership.sharedState.rawValue, activeClientCount, false)
                return
            }
            reply(
                0,
                ownership.sharedState.rawValue,
                activeClientCount,
                lastKnownSleepDisabled
            )
        }
    }

    fileprivate func resetSleepAfterUpdate(
        _ updateIdentifier: String,
        for identifier: UUID,
        reply: @escaping @Sendable (Int32) -> Void
    ) {
        queue.async { [self] in
            guard connections.contains(identifier),
                  Self.isValidUpdateIdentifier(updateIdentifier) else {
                reply(-1)
                return
            }
            guard lastCompletedUpdateIdentifier != updateIdentifier else {
                reply(0)
                return
            }

            let result = setAndVerifySleepDisabled(false)
            guard result.exitCode == 0 else {
                reply(result.exitCode)
                return
            }

            let previousUpdateIdentifier = lastCompletedUpdateIdentifier
            lastCompletedUpdateIdentifier = updateIdentifier
            do {
                try persistOwnership(.idle)
            } catch {
                lastCompletedUpdateIdentifier = previousUpdateIdentifier
                logOwnershipWriteFailure(error)
                reply(-1)
                return
            }

            helperLog.notice("Helper 更新后睡眠状态已重置")
            reply(0)
        }
    }

    func listener(
        _: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        let session = CodexBarHelperConnectionSession(runtime: self)
        let identifier = session.identifier
        newConnection.exportedInterface = NSXPCInterface(
            with: CodexBarHelperProtocol.self
        )
        newConnection.exportedObject = session

        let connectionDropped: () -> Void = { [weak self] in
            self?.connectionDropped(identifier)
        }
        newConnection.invalidationHandler = connectionDropped
        newConnection.interruptionHandler = connectionDropped

        queue.sync {
            _ = connections.insert(identifier)
        }
        newConnection.resume()
        return true
    }

    private func connectionDropped(_ identifier: UUID) {
        queue.async { [self] in
            guard connections.remove(identifier) != nil else {
                return
            }

            let droppedClients = clients.compactMap { clientIdentifier, lease in
                lease.connectionIdentifier == identifier ? clientIdentifier : nil
            }
            for clientIdentifier in droppedClients {
                guard var lease = clients[clientIdentifier] else {
                    continue
                }
                guard lease.isRequesting else {
                    clients[clientIdentifier] = nil
                    continue
                }

                lease.connectionIdentifier = nil
                clients[clientIdentifier] = lease
                scheduleWatchdog(for: clientIdentifier, generation: lease.generation)
            }
            scheduleOwnershipTimerIfNeeded()
        }
    }

    private func scheduleWatchdog(for clientIdentifier: UUID, generation: UInt64) {
        guard watchdogs[clientIdentifier] == nil else {
            return
        }

        let token = UUID()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, watchdogTokens[clientIdentifier] == token else {
                return
            }
            watchdogs[clientIdentifier] = nil
            watchdogTokens[clientIdentifier] = nil
            guard let lease = clients[clientIdentifier],
                  lease.generation == generation,
                  lease.isRequesting,
                  lease.connectionIdentifier == nil else {
                return
            }

            let source = currentSource()
            clients[clientIdentifier] = nil
            _ = reconcileReleasedSleep(source: source, trigger: .connectionWatchdog)
            scheduleOwnershipTimerIfNeeded()
        }
        watchdogs[clientIdentifier] = workItem
        watchdogTokens[clientIdentifier] = token
        queue.asyncAfter(
            deadline: .now() + CodexBarHelperIPC.watchdogGraceSeconds,
            execute: workItem
        )
    }

    private func cancelWatchdog(for clientIdentifier: UUID) {
        watchdogs.removeValue(forKey: clientIdentifier)?.cancel()
        watchdogTokens[clientIdentifier] = nil
    }

    // MARK: - 所有权与睡眠切换

    private func reconcileRequestedSleep(logsExternalState: Bool) -> SleepOperationResult {
        if ownership == .restoring {
            let recovery = restoreOwnedSleep(trigger: .appRequest)
            guard recovery.exitCode == 0 else {
                return recovery
            }
        }

        if ownership == .owned {
            guard validateOrRepairOwnedRecord() else {
                return recoverFromOwnedRecordFailure()
            }

            let current = readCurrentSleepDisabled()
            guard current.result.exitCode == 0, let sleepDisabled = current.value else {
                logPmsetReadFailure(current.result)
                return SleepOperationResult(
                    exitCode: normalizedFailureCode(current.result.exitCode),
                    source: .codexBar,
                    sleepDisabled: false
                )
            }

            if !sleepDisabled {
                let result = setAndVerifySleepDisabled(true)
                guard result.exitCode == 0 else {
                    return SleepOperationResult(
                        exitCode: result.exitCode,
                        source: .codexBar,
                        sleepDisabled: result.value ?? false
                    )
                }
                guard validateOrRepairOwnedRecord() else {
                    return recoverFromOwnedRecordFailure()
                }
            }
            return SleepOperationResult(exitCode: 0, source: .codexBar, sleepDisabled: true)
        }

        let current = readCurrentSleepDisabled()
        guard current.result.exitCode == 0, let sleepDisabled = current.value else {
            logPmsetReadFailure(current.result)
            return SleepOperationResult(
                exitCode: normalizedFailureCode(current.result.exitCode),
                source: .none,
                sleepDisabled: false
            )
        }

        guard !sleepDisabled else {
            if logsExternalState {
                helperLog.notice("系统睡眠已由其他来源关闭")
            }
            return SleepOperationResult(exitCode: 0, source: .external, sleepDisabled: true)
        }

        do {
            try persistOwnership(.owned)
        } catch {
            logOwnershipWriteFailure(error)
            return SleepOperationResult(exitCode: -1, source: .none, sleepDisabled: false)
        }

        let result = setAndVerifySleepDisabled(true)
        guard result.exitCode == 0 else {
            return SleepOperationResult(
                exitCode: result.exitCode,
                source: .codexBar,
                sleepDisabled: result.value ?? false
            )
        }
        guard validateOrRepairOwnedRecord() else {
            return recoverFromOwnedRecordFailure()
        }

        helperLog.notice("系统睡眠已由 CodexBar 关闭")
        return SleepOperationResult(exitCode: 0, source: .codexBar, sleepDisabled: true)
    }

    private func reconcileReleasedSleep(
        source: CodexBarSleepPreventionSource,
        trigger: SleepRestoreTrigger
    ) -> SleepOperationResult {
        guard activeClientCount == 0 else {
            return reconcileRequestedSleep(logsExternalState: false)
        }

        guard ownership.needsRestore else {
            // 未取得所有权时不写 pmset, 保留最近一次实测值供 App 判断是否需要补发系统睡眠
            return SleepOperationResult(
                exitCode: 0,
                source: source,
                sleepDisabled: lastKnownSleepDisabled ?? (source == .external)
            )
        }
        return restoreOwnedSleep(trigger: trigger)
    }

    @discardableResult
    private func restoreOwnedSleep(trigger: SleepRestoreTrigger) -> SleepOperationResult {
        do {
            try persistOwnership(.restoring)
        } catch {
            // 写恢复中标记失败也必须继续尝试写回 0, 否则记录故障本身会把机器永久卡在 1
            logOwnershipWriteFailure(error)
        }

        let result = setAndVerifySleepDisabled(false)
        guard result.exitCode == 0 else {
            let details = LogFields.joined(
                "trigger=\(trigger.rawValue)",
                "exit=\(result.exitCode)"
            )
            helperLog.error("系统睡眠恢复失败: \(details, privacy: .public)")
            return SleepOperationResult(
                exitCode: result.exitCode,
                source: .codexBar,
                sleepDisabled: result.value ?? true
            )
        }

        do {
            try persistOwnership(.idle)
        } catch {
            logOwnershipWriteFailure(error)
            return SleepOperationResult(exitCode: -1, source: .codexBar, sleepDisabled: false)
        }

        let details = LogFields.joined(
            "trigger=\(trigger.rawValue)",
            "sleepDisabled=0"
        )
        helperLog.notice("系统睡眠已恢复: \(details, privacy: .public)")
        return SleepOperationResult(exitCode: 0, source: .codexBar, sleepDisabled: false)
    }

    private func setAndVerifySleepDisabled(
        _ disabled: Bool
    ) -> (exitCode: Int32, value: Bool?) {
        let writeResult = PmsetRunner.setSleepDisabled(disabled)
        guard writeResult.exitCode == 0 else {
            let details = LogFields.joined(
                "target=\(disabled ? 1 : 0)",
                "exit=\(writeResult.exitCode)",
                "detail=\(writeResult.output)"
            )
            helperLog.error("pmset 写入失败: \(details, privacy: .public)")
            return (writeResult.exitCode, nil)
        }

        let readResult = readCurrentSleepDisabled()
        guard readResult.result.exitCode == 0, let value = readResult.value else {
            logPmsetReadFailure(readResult.result)
            return (normalizedFailureCode(readResult.result.exitCode), nil)
        }
        guard value == disabled else {
            let details = LogFields.joined(
                "target=\(disabled ? 1 : 0)",
                "actual=\(value ? 1 : 0)"
            )
            helperLog.error("pmset 写入校验失败: \(details, privacy: .public)")
            return (-1, value)
        }
        return (0, value)
    }

    private func readCurrentSleepDisabled() -> (result: PmsetResult, value: Bool?) {
        let current = PmsetRunner.currentSleepDisabled()
        if current.result.exitCode == 0, let value = current.value {
            lastKnownSleepDisabled = value
        }
        return current
    }

    private func validateOrRepairOwnedRecord() -> Bool {
        guard ownership == .owned else {
            return false
        }

        if case let .present(record) = ownershipRecordState(),
           record.state == .owned,
           record.transaction == transactionID {
            return true
        }

        helperLog.error("睡眠所有权记录与运行状态不一致: action=repair")
        do {
            try persistOwnership(.owned)
            helperLog.notice("睡眠所有权记录已修复")
            return true
        } catch {
            logOwnershipWriteFailure(error)
            return false
        }
    }

    private func recoverFromOwnedRecordFailure() -> SleepOperationResult {
        let recovery = restoreOwnedSleep(trigger: .ownershipCheck)
        return SleepOperationResult(
            exitCode: recovery.exitCode == 0 ? -1 : recovery.exitCode,
            source: .codexBar,
            sleepDisabled: recovery.sleepDisabled
        )
    }

    private func currentSource() -> CodexBarSleepPreventionSource {
        if ownership.needsRestore {
            return .codexBar
        }
        return activeClientCount == 0 ? .none : .external
    }

    private func currentOperationResult() -> SleepOperationResult {
        guard let lastKnownSleepDisabled else {
            return SleepOperationResult(exitCode: -1, source: currentSource(), sleepDisabled: false)
        }
        return SleepOperationResult(
            exitCode: 0,
            source: currentSource(),
            sleepDisabled: lastKnownSleepDisabled
        )
    }

    private var activeClientCount: Int {
        clients.values.lazy.filter(\.isRequesting).count
    }

    private func normalizedFailureCode(_ exitCode: Int32) -> Int32 {
        exitCode == 0 ? -1 : exitCode
    }

    private func logPmsetReadFailure(_ result: PmsetResult) {
        let details = LogFields.joined(
            "exit=\(result.exitCode)",
            "detail=\(result.output)"
        )
        helperLog.error("pmset 读取失败: \(details, privacy: .public)")
    }

    // MARK: - 异常恢复

    private func recoverOwnershipAtStartup() {
        let state = ownershipRecordState()
        switch state {
        case .absent:
            do {
                try persistOwnership(.idle)
                helperLog.notice("Helper 已启动: ownership=idle")
            } catch {
                logOwnershipWriteFailure(error)
                exit(EXIT_FAILURE)
            }
        case let .present(record):
            ownership = record.state
            transactionID = record.transaction
            lastCompletedUpdateIdentifier = record.identifier
            helperLog.notice(
                "Helper 已启动: ownership=\(record.state.rawValue, privacy: .public)"
            )
            if record.state.needsRestore {
                _ = restoreOwnedSleep(trigger: .helperStartup)
            }
        case let .unreadable(error):
            // 损坏记录无法证明所有权, 启动时按最安全的默认值 0 收敛
            let details = LogFields.joined(
                "detail=\(error.localizedDescription)",
                "action=forceRestore"
            )
            helperLog.error("睡眠所有权记录无效: \(details, privacy: .public)")
            ownership = .restoring
            _ = restoreOwnedSleep(trigger: .helperStartup)
        }

        if lastKnownSleepDisabled == nil {
            let current = readCurrentSleepDisabled()
            if current.result.exitCode != 0 || current.value == nil {
                logPmsetReadFailure(current.result)
            }
        }
    }

    private func installOwnershipTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [weak self] in
            guard let self else {
                return
            }
            if activeClientCount > 0 {
                _ = reconcileRequestedSleep(logsExternalState: false)
            } else if ownership.needsRestore, watchdogs.isEmpty {
                _ = restoreOwnedSleep(trigger: .ownershipCheck)
            }
            scheduleOwnershipTimerIfNeeded()
        }
        ownershipTimer = timer
        scheduleOwnershipTimerIfNeeded(force: true)
        timer.resume()
    }

    private func scheduleOwnershipTimerIfNeeded(force: Bool = false) {
        guard let ownershipTimer else {
            return
        }

        let interval: TimeInterval = if activeClientCount == 0 {
            CodexBarHelperIPC.recoveryCheckIntervalSeconds
        } else if ownership.needsRestore {
            CodexBarHelperIPC.ownedCheckIntervalSeconds
        } else {
            CodexBarHelperIPC.externalCheckIntervalSeconds
        }
        guard force || interval != scheduledOwnershipCheckInterval else {
            return
        }

        scheduledOwnershipCheckInterval = interval
        ownershipTimer.schedule(
            deadline: .now() + interval,
            repeating: interval,
            leeway: .seconds(Int(CodexBarHelperIPC.checkLeewaySeconds))
        )
    }

    private func installSignalHandlers() {
        for signalNumber in [SIGTERM, SIGINT] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: queue)
            source.setEventHandler { [weak self] in
                guard let self else {
                    exit(EXIT_SUCCESS)
                }
                if ownership.needsRestore {
                    _ = restoreOwnedSleep(trigger: .helperTermination)
                }
                exit(EXIT_SUCCESS)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: - 所有权记录

    private func ensureOwnershipDirectory() throws {
        let directoryURL = ownershipURL.deletingLastPathComponent()
        var info = stat()
        if lstat(directoryURL.path, &info) == 0 {
            try validateOwnershipDirectory(info)
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

    private func validateOwnershipDirectory(_ info: stat) throws {
        guard info.st_mode & S_IFMT == S_IFDIR else {
            let details = LogFields.joined(
                "actual=\(fileTypeName(info.st_mode))",
                "expected=directory"
            )
            throw CodexBarHelperError.insecureOwnershipDirectory(
                "目录类型错误: \(details)"
            )
        }
        guard info.st_uid == 0 else {
            let details = LogFields.joined(
                "actual=\(info.st_uid)",
                "expected=0"
            )
            throw CodexBarHelperError.insecureOwnershipDirectory(
                "所有者错误: \(details)"
            )
        }
        guard info.st_mode & 0o022 == 0 else {
            let details = LogFields.joined(
                "actual=\(permissionString(info.st_mode))",
                "forbidden=0022"
            )
            throw CodexBarHelperError.insecureOwnershipDirectory(
                "目录权限错误: \(details)"
            )
        }
    }

    private func persistOwnership(_ state: SleepOwnership) throws {
        try ensureOwnershipDirectory()
        if state == .owned, ownership == .idle {
            transactionID = UUID()
        }
        let record = SleepOwnershipRecord(
            schema: 1,
            state: state,
            transaction: transactionID,
            identifier: lastCompletedUpdateIdentifier,
            updated: Date()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)
        try writeOwnershipDataDurably(data)
        guard case let .present(savedRecord) = ownershipRecordState(),
              savedRecord.state == state,
              savedRecord.transaction == transactionID,
              savedRecord.identifier == lastCompletedUpdateIdentifier else {
            throw CodexBarHelperError.invalidOwnershipRecord("写入后校验失败")
        }
        ownership = state
    }

    private func writeOwnershipDataDurably(_ data: Data) throws {
        let directoryURL = ownershipURL.deletingLastPathComponent()
        let temporaryURL = directoryURL.appending(
            path: ".helper-state.\(UUID().uuidString).tmp"
        )
        var descriptor = open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw ownershipWriteError(operation: "open")
        }

        var shouldRemoveTemporaryFile = true
        defer {
            if descriptor >= 0 {
                _ = Darwin.close(descriptor)
            }
            if shouldRemoveTemporaryFile {
                _ = unlink(temporaryURL.path)
            }
        }

        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return
            }

            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if written < 0, errno == EINTR {
                    continue
                }
                guard written > 0 else {
                    throw ownershipWriteError(operation: "write")
                }
                offset += written
            }
        }

        guard fchown(descriptor, 0, 0) == 0 else {
            throw ownershipWriteError(operation: "fchown")
        }
        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw ownershipWriteError(operation: "fchmod")
        }
        try synchronizeOwnershipFile(descriptor)

        let closeResult = Darwin.close(descriptor)
        descriptor = -1
        guard closeResult == 0 else {
            throw ownershipWriteError(operation: "close")
        }
        guard rename(temporaryURL.path, ownershipURL.path) == 0 else {
            throw ownershipWriteError(operation: "rename")
        }
        shouldRemoveTemporaryFile = false
        try synchronizeOwnershipDirectory(directoryURL)
    }

    private func synchronizeOwnershipFile(_ descriptor: Int32) throws {
        if fcntl(descriptor, F_FULLFSYNC) == 0 {
            return
        }
        guard fsync(descriptor) == 0 else {
            throw ownershipWriteError(operation: "fsync")
        }
    }

    private func synchronizeOwnershipDirectory(_ directoryURL: URL) throws {
        let descriptor = open(directoryURL.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw ownershipWriteError(operation: "openDirectory")
        }
        defer {
            _ = Darwin.close(descriptor)
        }

        guard fsync(descriptor) == 0 else {
            let errorCode = errno
            // 部分文件系统不支持对目录执行 fsync, 文件本身已经完成 F_FULLFSYNC
            if errorCode == EINVAL || errorCode == ENOTSUP {
                return
            }
            throw ownershipWriteError(operation: "fsyncDirectory", code: errorCode)
        }
    }

    private func ownershipWriteError(
        operation: String,
        code: Int32 = errno
    ) -> CodexBarHelperError {
        .ownershipWriteFailed(operation: operation, code: code)
    }

    private func ownershipRecordState() -> OwnershipRecordState {
        do {
            guard let record = try readOwnershipRecord() else {
                return .absent
            }
            return .present(record)
        } catch {
            return .unreadable(error)
        }
    }

    private func readOwnershipRecord() throws -> SleepOwnershipRecord? {
        var info = stat()
        guard lstat(ownershipURL.path, &info) == 0 else {
            if errno == ENOENT {
                return nil
            }
            throw CodexBarHelperError.invalidOwnershipRecord(
                "读取属性失败: errno=\(errno)"
            )
        }
        guard info.st_mode & S_IFMT == S_IFREG else {
            let details = LogFields.joined(
                "actual=\(fileTypeName(info.st_mode))",
                "expected=file"
            )
            throw CodexBarHelperError.invalidOwnershipRecord(
                "文件类型错误: \(details)"
            )
        }
        guard info.st_uid == 0 else {
            let details = LogFields.joined(
                "actual=\(info.st_uid)",
                "expected=0"
            )
            throw CodexBarHelperError.invalidOwnershipRecord(
                "所有者错误: \(details)"
            )
        }
        guard info.st_mode & 0o022 == 0 else {
            let details = LogFields.joined(
                "actual=\(permissionString(info.st_mode))",
                "forbidden=0022"
            )
            throw CodexBarHelperError.invalidOwnershipRecord(
                "文件权限错误: \(details)"
            )
        }

        let data: Data
        do {
            data = try Data(contentsOf: ownershipURL)
        } catch {
            throw CodexBarHelperError.invalidOwnershipRecord(
                "读取内容失败: detail=\(error.localizedDescription)"
            )
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record: SleepOwnershipRecord
        do {
            record = try decoder.decode(SleepOwnershipRecord.self, from: data)
        } catch {
            throw CodexBarHelperError.invalidOwnershipRecord(
                "解码失败: detail=\(error.localizedDescription)"
            )
        }
        guard record.schema == 1 else {
            let details = LogFields.joined(
                "actual=\(record.schema)",
                "expected=1"
            )
            throw CodexBarHelperError.invalidOwnershipRecord(
                "版本错误: \(details)"
            )
        }
        return record
    }

    private func logOwnershipWriteFailure(_ error: Error) {
        let path = ownershipURL.path
        let details = LogFields.joined(
            "path=\(path)",
            "detail=\(error.localizedDescription)"
        )
        helperLog.error("睡眠所有权记录写入失败: \(details, privacy: .public)")
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

    private static func isValidUpdateIdentifier(_ identifier: String) -> Bool {
        let bytes = identifier.utf8
        return bytes.count == 64 && bytes.allSatisfy { byte in
            (48 ... 57).contains(byte) || (97 ... 102).contains(byte)
        }
    }

    private static func makeClientCodeSigningRequirement() throws -> String {
        var runningCode: SecCode?
        var status = SecCodeCopySelf(SecCSFlags(), &runningCode)
        guard status == errSecSuccess, let runningCode else {
            let details = LogFields.joined(
                "Operation=SecCodeCopySelf",
                "Status=\(status)"
            )
            throw CodexBarHelperError.codeSigningValidationFailed(
                "读取运行签名失败: \(details)"
            )
        }

        var staticCode: SecStaticCode?
        status = SecCodeCopyStaticCode(runningCode, SecCSFlags(), &staticCode)
        guard status == errSecSuccess, let staticCode else {
            let details = LogFields.joined(
                "Operation=SecCodeCopyStaticCode",
                "Status=\(status)"
            )
            throw CodexBarHelperError.codeSigningValidationFailed(
                "读取静态签名失败: \(details)"
            )
        }

        var signingInformation: CFDictionary?
        status = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInformation
        )
        guard status == errSecSuccess, let signingInformation else {
            let details = LogFields.joined(
                "Operation=SecCodeCopySigningInformation",
                "Status=\(status)"
            )
            throw CodexBarHelperError.codeSigningValidationFailed(
                "读取签名信息失败: \(details)"
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
            let details = LogFields.joined(
                "actual=\(helperIdentifier)",
                "expected=*\(helperSuffix)"
            )
            throw CodexBarHelperError.codeSigningValidationFailed(
                "Helper 标识符错误: \(details)"
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
    case insecureOwnershipDirectory(String)
    case invalidOwnershipRecord(String)
    case ownershipWriteFailed(operation: String, code: Int32)
    case codeSigningValidationFailed(String)

    var errorDescription: String? {
        switch self {
        case let .insecureOwnershipDirectory(detail):
            "睡眠设置目录无效: \(detail)"
        case let .invalidOwnershipRecord(detail):
            "睡眠所有权记录无效: \(detail)"
        case let .ownershipWriteFailed(operation, code):
            "睡眠所有权记录写入失败: operation=\(operation); errno=\(code)"
        case let .codeSigningValidationFailed(reason):
            "签名校验失败: \(reason)"
        }
    }
}

private let runtime = CodexBarHelperRuntime()
runtime.run()
dispatchMain()
