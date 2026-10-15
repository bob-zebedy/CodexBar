import Darwin
import Foundation
import IOKit
import IOKit.pwr_mgt
import os
import Security
import Synchronization

private let powerHelperLog = Logger(
    subsystem: CodexBarPowerHelperIPC.serviceIdentifier,
    category: "power-helper"
)

enum LogFields {
    static func joined(_ fields: String...) -> String {
        fields.joined(separator: "; ")
    }
}

private enum CodexBarPowerHelperStorage {
    static let ownershipURL: URL = {
        guard let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .localDomainMask
        ).first else {
            powerHelperLog.error("Power Helper 启动失败: reason=applicationSupportMissing")
            exit(EXIT_FAILURE)
        }
        return applicationSupportURL
            .appending(path: "CodexBar", directoryHint: .isDirectory)
            .appending(path: "power-helper-state.json")
    }()
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

private enum SleepRestoreTrigger: String {
    case appRequest
    case connectionWatchdog
    case powerHelperStartup
    case ownershipCheck
    case powerHelperTermination
}

private enum WakeScheduleCleanupTrigger: String {
    case appRequest
    case connectionClosed
    case powerHelperStartup
    case ownershipCheck
    case powerHelperTermination
}

private final class PowerHelperSession: NSObject, CodexBarPowerHelperProtocol,
    @unchecked Sendable {
    let identifier = UUID()
    private weak var runtime: PowerHelperRuntime?

    init(runtime: PowerHelperRuntime) {
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

    func setAutoResetWakeSchedule(
        _ unixTimestamp: TimeInterval,
        reply: @escaping @Sendable (Int32) -> Void
    ) {
        guard let runtime else {
            reply(-1)
            return
        }
        runtime.setAutoResetWakeSchedule(
            unixTimestamp,
            for: identifier,
            reply: reply
        )
    }
}

final class PowerHelperRuntime: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private struct Watchdog {
        let token: UUID
        let workItem: DispatchWorkItem
    }

    private let queue = DispatchQueue(label: CodexBarPowerHelperIPC.serviceIdentifier + ".state")
    private let ownershipStore: any OwnershipStoring
    private let sleepOperations: PowerHelperSleepOperations
    private var ownership = SleepOwnership.idle
    private var transactionID = UUID()
    private var lastCompletedUpdateIdentifier: String?
    private var connections = Set<UUID>()
    private var clients = [UUID: ClientLease]()
    private var watchdogs = [UUID: Watchdog]()
    private var lastKnownSleepDisabled: Bool?
    private var ownershipTimer: DispatchSourceTimer?
    private var scheduledOwnershipCheckInterval: TimeInterval?
    private var autoResetWakeConnectionIdentifier: UUID?
    private var isAutoResetWakeCleanupPending = false
    private var signalSources = [DispatchSourceSignal]()
    private var listener: NSXPCListener?

    init(ownershipStore: (any OwnershipStoring)? = nil, sleepOperations: PowerHelperSleepOperations = .system) {
        self.ownershipStore = ownershipStore ?? OwnershipStore(url: CodexBarPowerHelperStorage.ownershipURL)
        self.sleepOperations = sleepOperations
        super.init()
    }

    func run() {
        guard geteuid() == 0 else {
            powerHelperLog.error("Power Helper 启动失败: reason=notRoot")
            exit(EXIT_FAILURE)
        }

        do {
            try ownershipStore.ensureOwnershipDirectory()
        } catch {
            let directoryPath = ownershipStore.url.deletingLastPathComponent().path
            let details = LogFields.joined(
                "reason=ownershipDirectory",
                "path=\(directoryPath)",
                "detail=\(error.localizedDescription)"
            )
            powerHelperLog.error("Power Helper 启动失败: \(details, privacy: .public)")
            exit(EXIT_FAILURE)
        }

        recoverOwnershipAtStartup()
        recoverAutoResetWakeScheduleAtStartup()
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
            powerHelperLog.error("Power Helper 启动失败: \(details, privacy: .public)")
            exit(EXIT_FAILURE)
        }

        let listener = NSXPCListener(machServiceName: CodexBarPowerHelperIPC.serviceIdentifier)
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

            let exitCode = reconcileSleepAfterUpdate()
            guard exitCode == 0 else {
                reply(exitCode)
                return
            }

            let previousUpdateIdentifier = lastCompletedUpdateIdentifier
            lastCompletedUpdateIdentifier = updateIdentifier
            do {
                // 更新完成不代表系统必须允许睡眠, 有效租约和外部设置仍然保留
                try persistOwnership(ownership)
            } catch {
                lastCompletedUpdateIdentifier = previousUpdateIdentifier
                logOwnershipWriteFailure(error)
                reply(-1)
                return
            }

            powerHelperLog.notice("Power Helper 更新后已完成睡眠状态检查")
            reply(0)
        }
    }

    private func reconcileSleepAfterUpdate() -> Int32 {
        if ownership.needsRestore || activeClientCount > 0 {
            return reconcileReleasedSleep(source: currentSource(), trigger: .appRequest).exitCode
        }
        let current = readCurrentSleepDisabled()
        guard current.result.exitCode == 0, current.value != nil else {
            logPmsetReadFailure(current.result)
            return normalizedFailureCode(current.result.exitCode)
        }
        return 0
    }

    fileprivate func setAutoResetWakeSchedule(
        _ unixTimestamp: TimeInterval,
        for identifier: UUID,
        reply: @escaping @Sendable (Int32) -> Void
    ) {
        queue.async { [self] in
            guard connections.contains(identifier),
                  unixTimestamp.isFinite,
                  unixTimestamp >= 0 else {
                reply(kIOReturnBadArgument)
                return
            }

            let date: Date?
            if unixTimestamp == 0 {
                date = nil
            } else {
                let requestedDate = Date(timeIntervalSince1970: unixTimestamp)
                guard requestedDate > Date() else {
                    reply(kIOReturnBadArgument)
                    return
                }
                date = requestedDate
            }

            if date == nil {
                autoResetWakeConnectionIdentifier = nil
            } else {
                autoResetWakeConnectionIdentifier = identifier
            }

            let result: IOReturn = if date == nil {
                cancelAutoResetWakeSchedule(trigger: .appRequest)
            } else {
                AutoResetWakeScheduler.replaceSchedule(with: date)
            }
            guard result == kIOReturnSuccess else {
                if date != nil {
                    scheduleOwnershipTimerIfNeeded()
                }
                let details = LogFields.joined(
                    "action=\(date == nil ? "cancel" : "schedule")",
                    "code=\(result)"
                )
                powerHelperLog.error("自动重置唤醒计划更新失败: \(details, privacy: .public)")
                reply(result)
                return
            }

            if date != nil {
                isAutoResetWakeCleanupPending = false
                scheduleOwnershipTimerIfNeeded()
            }
            if let date {
                let epoch = Int(date.timeIntervalSince1970)
                powerHelperLog.notice("自动重置唤醒计划已设置: epoch=\(epoch)")
            }
            reply(kIOReturnSuccess)
        }
    }

    func listener(
        _: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        let session = PowerHelperSession(runtime: self)
        let identifier = session.identifier
        newConnection.exportedInterface = NSXPCInterface(
            with: CodexBarPowerHelperProtocol.self
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

            cancelAutoResetWakeSchedule(ifOwnedBy: identifier)
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

    private func cancelAutoResetWakeSchedule(ifOwnedBy identifier: UUID) {
        guard autoResetWakeConnectionIdentifier == identifier else {
            return
        }

        autoResetWakeConnectionIdentifier = nil
        _ = cancelAutoResetWakeSchedule(trigger: .connectionClosed)
    }

    @discardableResult
    private func cancelAutoResetWakeSchedule(
        trigger: WakeScheduleCleanupTrigger
    ) -> IOReturn {
        defer { scheduleOwnershipTimerIfNeeded() }
        let result = AutoResetWakeScheduler.replaceSchedule(with: nil)
        guard result == kIOReturnSuccess else {
            isAutoResetWakeCleanupPending = true
            let details = LogFields.joined(
                "reason=\(trigger.rawValue)",
                "code=\(result)",
                "remaining=\(AutoResetWakeScheduler.ownedEventCount)"
            )
            powerHelperLog.error("自动重置唤醒计划取消失败: \(details, privacy: .public)")
            return result
        }

        isAutoResetWakeCleanupPending = false
        powerHelperLog.notice(
            "自动重置唤醒计划已取消: reason=\(trigger.rawValue, privacy: .public)"
        )
        return kIOReturnSuccess
    }

    private func scheduleWatchdog(for clientIdentifier: UUID, generation: UInt64) {
        guard watchdogs[clientIdentifier] == nil else {
            return
        }

        let token = UUID()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, watchdogs[clientIdentifier]?.token == token else {
                return
            }
            watchdogs[clientIdentifier] = nil
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
        watchdogs[clientIdentifier] = Watchdog(token: token, workItem: workItem)
        queue.asyncAfter(
            deadline: .now() + CodexBarPowerHelperIPC.watchdogGraceSeconds,
            execute: workItem
        )
    }

    private func cancelWatchdog(for clientIdentifier: UUID) {
        watchdogs.removeValue(forKey: clientIdentifier)?.workItem.cancel()
    }

    // MARK: - 所有权与睡眠切换

    private func reconcileRequestedSleep(logsExternalState: Bool) -> SleepOperationResult {
        if ownership == .restoring {
            let recovery = restoreOwnedSleep(trigger: .appRequest)
            guard recovery.exitCode == 0 else {
                return recovery
            }
        }

        let wasOwned = ownership == .owned
        if wasOwned, !validateOrRepairOwnedRecord() {
            return recoverFromOwnedRecordFailure()
        }

        let current = readCurrentSleepDisabled()
        guard current.result.exitCode == 0, let sleepDisabled = current.value else {
            logPmsetReadFailure(current.result)
            return SleepOperationResult(
                exitCode: normalizedFailureCode(current.result.exitCode),
                source: wasOwned ? .codexBar : .none,
                sleepDisabled: false
            )
        }

        guard !sleepDisabled else {
            if !wasOwned, logsExternalState {
                powerHelperLog.notice("系统睡眠已由其他来源关闭")
            }
            return SleepOperationResult(exitCode: 0, source: wasOwned ? .codexBar : .external, sleepDisabled: true)
        }

        if !wasOwned {
            do {
                try persistOwnership(.owned)
            } catch {
                logOwnershipWriteFailure(error)
                return SleepOperationResult(exitCode: -1, source: .none, sleepDisabled: false)
            }
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

        if !wasOwned {
            powerHelperLog.notice("系统睡眠已由 CodexBar 关闭")
        }
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
            // 未取得所有权时不写 pmset, 返回最近一次实测值
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
            powerHelperLog.error("系统睡眠恢复失败: \(details, privacy: .public)")
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
        powerHelperLog.notice("系统睡眠已恢复: \(details, privacy: .public)")
        return SleepOperationResult(exitCode: 0, source: .codexBar, sleepDisabled: false)
    }

    private func setAndVerifySleepDisabled(
        _ disabled: Bool
    ) -> (exitCode: Int32, value: Bool?) {
        let writeResult = sleepOperations.write(disabled)
        guard writeResult.exitCode == 0 else {
            let details = LogFields.joined(
                "target=\(disabled ? 1 : 0)",
                "exit=\(writeResult.exitCode)",
                "detail=\(writeResult.output)"
            )
            powerHelperLog.error("pmset 写入失败: \(details, privacy: .public)")
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
            powerHelperLog.error("pmset 写入校验失败: \(details, privacy: .public)")
            return (-1, value)
        }
        return (0, value)
    }

    private func readCurrentSleepDisabled() -> (result: PmsetResult, value: Bool?) {
        let current = sleepOperations.read()
        if current.result.exitCode == 0, let value = current.value {
            lastKnownSleepDisabled = value
        }
        return current
    }

    private func validateOrRepairOwnedRecord() -> Bool {
        guard ownership == .owned else {
            return false
        }

        if case let .present(record) = ownershipStore.ownershipRecordState(),
           record.state == .owned,
           record.transaction == transactionID {
            return true
        }

        powerHelperLog.error("睡眠所有权记录与运行状态不一致: action=repair")
        do {
            try persistOwnership(.owned)
            powerHelperLog.notice("睡眠所有权记录已修复")
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
        powerHelperLog.error("pmset 读取失败: \(details, privacy: .public)")
    }

    // MARK: - 异常恢复

    func recoverOwnershipAtStartup() {
        let state = ownershipStore.ownershipRecordState()
        switch state {
        case .absent:
            do {
                try persistOwnership(.idle)
                powerHelperLog.notice("Power Helper 已启动: ownership=idle")
            } catch {
                logOwnershipWriteFailure(error)
                exit(EXIT_FAILURE)
            }
        case let .present(record):
            ownership = record.state
            transactionID = record.transaction
            lastCompletedUpdateIdentifier = record.identifier
            powerHelperLog.notice(
                "Power Helper 已启动: ownership=\(record.state.rawValue, privacy: .public)"
            )
            if record.state.needsRestore {
                _ = restoreOwnedSleep(trigger: .powerHelperStartup)
            }
        case let .unreadable(error):
            // 损坏记录无法证明所有权, 启动时按最安全的默认值 0 收敛
            let details = LogFields.joined(
                "detail=\(error.localizedDescription)",
                "action=forceRestore"
            )
            powerHelperLog.error("睡眠所有权记录无效: \(details, privacy: .public)")
            ownership = .restoring
            _ = restoreOwnedSleep(trigger: .powerHelperStartup)
        }

        if lastKnownSleepDisabled == nil {
            let current = readCurrentSleepDisabled()
            if current.result.exitCode != 0 || current.value == nil {
                logPmsetReadFailure(current.result)
            }
        }
    }

    private func recoverAutoResetWakeScheduleAtStartup() {
        let initialEventCount = AutoResetWakeScheduler.ownedEventCount
        guard initialEventCount > 0 else {
            return
        }

        var lastResult = IOReturn(kIOReturnError)
        for delay in Self.wakeCleanupStartupRetryDelays {
            if delay > 0 {
                Thread.sleep(forTimeInterval: delay)
            }
            lastResult = AutoResetWakeScheduler.replaceSchedule(with: nil)
            if lastResult == kIOReturnSuccess {
                powerHelperLog.notice(
                    "自动重置遗留唤醒计划已清理: reason=powerHelperStartup count=\(initialEventCount)"
                )
                return
            }
        }

        isAutoResetWakeCleanupPending = true
        let details = LogFields.joined(
            "reason=\(WakeScheduleCleanupTrigger.powerHelperStartup.rawValue)",
            "code=\(lastResult)",
            "remaining=\(AutoResetWakeScheduler.ownedEventCount)"
        )
        powerHelperLog.error("自动重置遗留唤醒计划清理失败: \(details, privacy: .public)")
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
            if isAutoResetWakeCleanupPending,
               autoResetWakeConnectionIdentifier == nil {
                _ = cancelAutoResetWakeSchedule(trigger: .ownershipCheck)
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

        let interval: TimeInterval = if isAutoResetWakeCleanupPending {
            CodexBarPowerHelperIPC.ownedCheckIntervalSeconds
        } else if activeClientCount == 0 {
            CodexBarPowerHelperIPC.recoveryCheckIntervalSeconds
        } else if ownership.needsRestore {
            CodexBarPowerHelperIPC.ownedCheckIntervalSeconds
        } else {
            CodexBarPowerHelperIPC.externalCheckIntervalSeconds
        }
        guard force || interval != scheduledOwnershipCheckInterval else {
            return
        }

        scheduledOwnershipCheckInterval = interval
        ownershipTimer.schedule(
            deadline: .now() + interval,
            repeating: interval,
            leeway: .seconds(Int(CodexBarPowerHelperIPC.checkLeewaySeconds))
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
                    _ = restoreOwnedSleep(trigger: .powerHelperTermination)
                }
                autoResetWakeConnectionIdentifier = nil
                _ = cancelAutoResetWakeSchedule(trigger: .powerHelperTermination)
                exit(EXIT_SUCCESS)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private static let wakeCleanupStartupRetryDelays: [TimeInterval] = [0, 0.25, 1]

    // MARK: - 所有权记录

    private func persistOwnership(_ state: SleepOwnership) throws {
        try ownershipStore.ensureOwnershipDirectory()
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
        try ownershipStore.writeOwnershipDataDurably(data)
        guard case let .present(savedRecord) = ownershipStore.ownershipRecordState(),
              savedRecord.state == state,
              savedRecord.transaction == transactionID,
              savedRecord.identifier == lastCompletedUpdateIdentifier else {
            throw PowerHelperError.invalidOwnershipRecord("写入后校验失败")
        }
        ownership = state
    }

    private func logOwnershipWriteFailure(_ error: Error) {
        let path = ownershipStore.url.path
        let details = LogFields.joined(
            "path=\(path)",
            "detail=\(error.localizedDescription)"
        )
        powerHelperLog.error("睡眠所有权记录写入失败: \(details, privacy: .public)")
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
            throw PowerHelperError.codeSigningValidationFailed(
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
            throw PowerHelperError.codeSigningValidationFailed(
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
            throw PowerHelperError.codeSigningValidationFailed(
                "读取签名信息失败: \(details)"
            )
        }

        let values = signingInformation as NSDictionary
        guard let teamIdentifier = values[kSecCodeInfoTeamIdentifier] as? String else {
            throw PowerHelperError.codeSigningValidationFailed("Team ID 缺失")
        }
        guard let powerHelperIdentifier = values[kSecCodeInfoIdentifier] as? String else {
            throw PowerHelperError.codeSigningValidationFailed("Power Helper 标识符缺失")
        }

        guard powerHelperIdentifier == CodexBarPowerHelperIPC.serviceIdentifier else {
            let details = LogFields.joined(
                "actual=\(powerHelperIdentifier)",
                "expected=\(CodexBarPowerHelperIPC.serviceIdentifier)"
            )
            throw PowerHelperError.codeSigningValidationFailed(
                "Power Helper 标识符错误: \(details)"
            )
        }

        let clientIdentifier = CodexBarPowerHelperIPC.clientAppBundleIdentifier
        let identifierCharacters = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: ".-")
        )
        guard !teamIdentifier.isEmpty else {
            throw PowerHelperError.codeSigningValidationFailed("Team ID 为空")
        }
        guard teamIdentifier.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains) else {
            throw PowerHelperError.codeSigningValidationFailed(
                "Team ID 格式错误: \(teamIdentifier)"
            )
        }
        guard !clientIdentifier.isEmpty else {
            throw PowerHelperError.codeSigningValidationFailed("客户端标识符为空")
        }
        guard clientIdentifier.unicodeScalars.allSatisfy(identifierCharacters.contains) else {
            throw PowerHelperError.codeSigningValidationFailed(
                "客户端标识符格式错误: \(clientIdentifier)"
            )
        }

        return "anchor apple generic"
            + " and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
            + " and identifier \"\(clientIdentifier)\""
    }
}
