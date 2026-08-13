import Foundation
import os

/// 只负责同步自动重置的唤醒时间, 与防睡眠租约使用独立 XPC 连接
@MainActor
final class AutoResetWakeScheduler {
    private enum AppliedSchedule: Equatable {
        case unknown
        case cleared
        case scheduled(Date)

        init(wakeDate: Date?) {
            if let wakeDate {
                self = .scheduled(wakeDate)
            } else {
                self = .cleared
            }
        }

        var hasWakeDate: Bool {
            if case .scheduled = self {
                return true
            }
            return false
        }
    }

    private enum PreparationState {
        case none
        case termination
        case helperInterruption
    }

    var onErrorMessageChanged: ((String?) -> Void)?

    private let runtimeStatusMonitor = HelperRuntimeStatusMonitor()
    private var isRequested = false
    private var isHelperReady = false
    private var desiredWakeDate: Date?
    private var appliedSchedule = AppliedSchedule.unknown
    private var syncTask: Task<Void, Never>?
    private var syncTaskID: UUID?
    private var needsReconcile = false
    private var preparationState = PreparationState.none
    private var connection: NSXPCConnection?
    private var errorMessage: String? {
        didSet {
            guard errorMessage != oldValue else {
                return
            }
            onErrorMessageChanged?(errorMessage)
        }
    }

    func setRequested(_ requested: Bool) {
        guard requested != isRequested else {
            reconcile()
            return
        }

        isRequested = requested
        errorMessage = nil
        if !requested {
            desiredWakeDate = nil
        }
        restartSyncForDesiredStateChange()
    }

    func setWakeDate(_ date: Date?) {
        let normalizedDate = date.flatMap { value in
            value.timeIntervalSinceNow > Self.minimumWakeLeadTime ? value : nil
        }
        guard normalizedDate != desiredWakeDate else {
            return
        }

        desiredWakeDate = normalizedDate
        errorMessage = nil
        restartSyncForDesiredStateChange()
    }

    func setHelperReady(_ ready: Bool) {
        guard ready != isHelperReady else {
            if ready {
                reconcile()
            }
            return
        }

        isHelperReady = ready
        guard ready else {
            errorMessage = nil
            suspend()
            return
        }
        reconcile()
    }

    func stop() {
        isRequested = false
        isHelperReady = false
        preparationState = .none
        desiredWakeDate = nil
        errorMessage = nil
        suspend()
    }

    func prepareForTermination(helperSupportsWakeScheduling: Bool) async -> Bool {
        guard preparationState == .none else {
            return false
        }

        preparationState = .termination
        cancelSyncTask()
        guard helperSupportsWakeScheduling || connection != nil else {
            return !appliedSchedule.hasWakeDate
        }
        return await cancelOwnedSchedule(reason: "termination")
    }

    func resumeAfterTerminationCancellation() {
        guard preparationState == .termination else {
            return
        }

        preparationState = .none
        reconcile()
    }

    func beginHelperInterruptionPreparation() -> Bool {
        guard preparationState == .none else {
            return false
        }

        preparationState = .helperInterruption
        cancelSyncTask()
        return true
    }

    func cancelBeforeHelperInterruption() async -> Bool {
        guard preparationState == .helperInterruption else {
            return false
        }
        guard connection != nil || appliedSchedule.hasWakeDate else {
            return true
        }
        return await cancelOwnedSchedule(reason: "helperUpdate")
    }

    func resumeAfterHelperInterruption() {
        guard preparationState == .helperInterruption else {
            return
        }

        preparationState = .none
        reconcile()
    }

    private func restartSyncForDesiredStateChange() {
        cancelSyncTask()
        reconcile()
    }

    private func suspend() {
        cancelSyncTask()
        invalidateConnection()
        appliedSchedule = .unknown
    }

    private func cancelSyncTask() {
        syncTask?.cancel()
        runtimeStatusMonitor.cancelRequest()
        syncTask = nil
        syncTaskID = nil
        needsReconcile = false
    }

    private func reconcile() {
        guard preparationState == .none else {
            return
        }
        guard isHelperReady else {
            return
        }
        guard syncTask == nil else {
            needsReconcile = true
            return
        }
        guard appliedSchedule != AppliedSchedule(wakeDate: desiredWakeDate) else {
            closeIdleConnectionIfNeeded()
            return
        }

        let taskID = UUID()
        syncTaskID = taskID
        needsReconcile = false
        syncTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            await synchronizeSchedule()
            finishSyncTask(taskID: taskID)
        }
    }

    private func cancelOwnedSchedule(reason: String) async -> Bool {
        for delay in KeepAliveHelperConfiguration.wakeCancellationRetryDelays {
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled else {
                return false
            }

            let result = await runtimeStatusMonitor.setAutoResetWakeSchedule(
                connection: connection ?? makeConnection(),
                unixTimestamp: 0,
                timeout: KeepAliveHelperConfiguration.requestTimeout
            )
            guard !Task.isCancelled else {
                return false
            }

            switch result {
            case .success:
                appliedSchedule = .cleared
                errorMessage = nil
                invalidateConnection()
                AppLog.keepAlive.notice(
                    "自动重置唤醒计划已确认取消: reason=\(reason, privacy: .public)"
                )
                return true

            case let .helperFailure(code):
                AppLog.keepAlive.error(
                    "自动重置唤醒计划取消失败: reason=\(reason, privacy: .public) code=\(code)"
                )

            case let .connectionFailure(error):
                AppLog.keepAlive.error(
                    "自动重置唤醒计划取消连接失败: reason=\(reason, privacy: .public) detail=\(error.localizedDescription, privacy: .public)"
                )
                invalidateConnection()

            case .timedOut:
                AppLog.keepAlive.error(
                    "自动重置唤醒计划取消超时: reason=\(reason, privacy: .public)"
                )
                invalidateConnection()

            case .cancelled:
                break
            }
        }

        appliedSchedule = .unknown
        errorMessage = KeepAliveLocalizedMessage.autoResetWakeScheduleFailed
        invalidateConnection()
        return false
    }

    private func synchronizeSchedule() async {
        var retryIndex = 0
        while !Task.isCancelled, isHelperReady {
            guard appliedSchedule != AppliedSchedule(wakeDate: desiredWakeDate) else {
                return
            }

            let requestedDate = desiredWakeDate
            let result = await runtimeStatusMonitor.setAutoResetWakeSchedule(
                connection: connection ?? makeConnection(),
                unixTimestamp: requestedDate?.timeIntervalSince1970 ?? 0,
                timeout: KeepAliveHelperConfiguration.requestTimeout
            )
            guard !Task.isCancelled, isHelperReady else {
                return
            }

            switch result {
            case .success:
                appliedSchedule = AppliedSchedule(wakeDate: requestedDate)
                errorMessage = nil
                let epoch = requestedDate.map { Int($0.timeIntervalSince1970) } ?? 0
                AppLog.keepAlive.notice("自动重置唤醒计划已同步: epoch=\(epoch)")
                retryIndex = 0
                continue

            case .cancelled:
                continue

            case let .helperFailure(code):
                AppLog.keepAlive.error("自动重置唤醒计划同步失败: code=\(code)")

            case let .connectionFailure(error):
                AppLog.keepAlive.error(
                    "自动重置唤醒服务连接失败: detail=\(error.localizedDescription, privacy: .public)"
                )
                invalidateConnection()

            case .timedOut:
                AppLog.keepAlive.error("自动重置唤醒服务请求超时")
                invalidateConnection()
            }

            appliedSchedule = .unknown
            errorMessage = KeepAliveLocalizedMessage.autoResetWakeScheduleFailed
            guard retryIndex < KeepAliveHelperConfiguration.wakeScheduleRetryDelays.count else {
                return
            }

            let delay = KeepAliveHelperConfiguration.wakeScheduleRetryDelays[retryIndex]
            retryIndex += 1
            try? await Task.sleep(for: delay)
        }
    }

    private func finishSyncTask(taskID: UUID) {
        guard syncTaskID == taskID else {
            return
        }

        syncTask = nil
        syncTaskID = nil
        if needsReconcile {
            needsReconcile = false
            reconcile()
        } else {
            closeIdleConnectionIfNeeded()
        }
    }

    private func closeIdleConnectionIfNeeded() {
        guard desiredWakeDate == nil,
              appliedSchedule == .cleared,
              connection != nil else {
            return
        }
        invalidateConnection()
        AppLog.keepAlive.notice("自动重置唤醒服务已断开: reason=idle")
    }

    private func makeConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(
            machServiceName: CodexBarHelperIPC.machServiceName,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(with: CodexBarHelperProtocol.self)
        connection.invalidationHandler = { [weak self, weak connection] in
            Task { @MainActor in
                self?.handleConnectionLoss(connection, reason: "invalidated")
            }
        }
        connection.interruptionHandler = { [weak self, weak connection] in
            Task { @MainActor in
                self?.handleConnectionLoss(connection, reason: "interrupted")
            }
        }
        connection.resume()
        self.connection = connection
        AppLog.keepAlive.notice("自动重置唤醒服务已连接")
        return connection
    }

    private func handleConnectionLoss(_ connection: NSXPCConnection?, reason: String) {
        guard let connection, self.connection === connection else {
            return
        }

        connection.invalidationHandler = nil
        connection.interruptionHandler = nil
        connection.invalidate()
        self.connection = nil
        runtimeStatusMonitor.cancelRequest()
        appliedSchedule = .unknown
        AppLog.keepAlive.notice(
            "自动重置唤醒服务已断开: reason=\(reason, privacy: .public)"
        )
        reconcile()
    }

    private func invalidateConnection() {
        let connection = connection
        self.connection = nil
        connection?.invalidationHandler = nil
        connection?.interruptionHandler = nil
        connection?.invalidate()
    }

    private static let minimumWakeLeadTime: TimeInterval = 5
}
