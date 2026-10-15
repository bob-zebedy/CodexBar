import Foundation
import os

struct PowerHelperRuntimeStatus {
    let ownership: CodexBarSleepOwnershipState
    let activeClientCount: Int
    let sleepDisabled: Bool

    var externalObservationAction: ExternalObservationAction {
        if ownership == .owned, activeClientCount > 0, sleepDisabled {
            return .sourceBecameCodexBar
        }
        if !sleepDisabled, ownership != .restoring {
            return .reacquireLease
        }
        return .none
    }

    enum ExternalObservationAction {
        case none
        case sourceBecameCodexBar
        case reacquireLease
    }
}

@MainActor
final class PowerHelperStatusMonitor {
    enum WakeScheduleResult {
        case success
        case powerHelperFailure(Int32)
        case connectionFailure(Error)
        case timedOut
        case cancelled
    }

    var isRequestInFlight: Bool {
        requestContinuation != nil
    }

    private var requestGeneration: UInt64 = 0
    private var requestContinuation: CheckedContinuation<RequestResult, Never>?
    private var requestTimeoutTask: Task<Void, Never>?
    private var observationTask: Task<Void, Never>?

    func fetch(
        connection: NSXPCConnection,
        timeout: Duration,
        onConnectionFailure: @escaping (Error) -> Void,
        onTimeout: @escaping () -> Void
    ) async -> PowerHelperRuntimeStatus? {
        let result = await performRequest(
            connection: connection,
            operation: .status,
            timeout: timeout
        )
        switch result {
        case let .status(status):
            return status
        case let .connectionFailure(error):
            onConnectionFailure(error)
        case let .invalidResponse(exitCode, ownership, activeClientCount):
            let details = LogFields.joined(
                "exit=\(exitCode)",
                "ownership=\(ownership)",
                "clients=\(activeClientCount)"
            )
            AppLog.keepAlive.error(
                "Power Helper 运行状态无效: \(details, privacy: .public)"
            )
        case .timedOut:
            let wait = LogDuration.seconds(timeout)
            AppLog.keepAlive.error(
                "Power Helper 状态请求超时: timeout=\(wait, privacy: .public)"
            )
            onTimeout()
        case .updateReset, .wakeSchedule, .cancelled:
            break
        }
        return nil
    }

    func resetSleepAfterUpdate(
        connection: NSXPCConnection,
        updateIdentifier: String,
        timeout: Duration,
        onConnectionFailure: @escaping (Error) -> Void,
        onTimeout: @escaping () -> Void
    ) async -> Bool {
        let result = await performRequest(
            connection: connection,
            operation: .updateReset(updateIdentifier),
            timeout: timeout
        )
        switch result {
        case let .updateReset(exitCode):
            guard exitCode == 0 else {
                AppLog.keepAlive.error(
                    "Power Helper 更新后睡眠状态检查失败: exit=\(exitCode)"
                )
                return false
            }
            return true
        case let .connectionFailure(error):
            onConnectionFailure(error)
        case .timedOut:
            let wait = LogDuration.seconds(timeout)
            AppLog.keepAlive.error(
                "Power Helper 更新后睡眠状态检查超时: timeout=\(wait, privacy: .public)"
            )
            onTimeout()
        case .status, .wakeSchedule, .invalidResponse, .cancelled:
            break
        }
        return false
    }

    func setAutoResetWakeSchedule(
        connection: NSXPCConnection,
        unixTimestamp: TimeInterval,
        timeout: Duration
    ) async -> WakeScheduleResult {
        let result = await performRequest(
            connection: connection,
            operation: .wakeSchedule(unixTimestamp),
            timeout: timeout
        )
        switch result {
        case let .wakeSchedule(exitCode):
            return exitCode == 0 ? .success : .powerHelperFailure(exitCode)
        case let .connectionFailure(error):
            return .connectionFailure(error)
        case .timedOut:
            return .timedOut
        case .status, .updateReset, .invalidResponse, .cancelled:
            return .cancelled
        }
    }

    func startObservation(
        interval: Duration,
        action: @escaping @MainActor () async -> Void
    ) {
        guard observationTask == nil else {
            return
        }

        observationTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else {
                    break
                }
                await action()
            }
        }
    }

    func cancelObservation() {
        observationTask?.cancel()
        observationTask = nil
    }

    func cancelRequest() {
        guard isRequestInFlight else {
            return
        }
        requestGeneration &+= 1
        finishRequest(.cancelled, generation: requestGeneration)
    }

    private func performRequest(
        connection: NSXPCConnection,
        operation: RequestOperation,
        timeout: Duration
    ) async -> RequestResult {
        guard !isRequestInFlight else {
            return .cancelled
        }

        return await withCheckedContinuation { continuation in
            requestGeneration &+= 1
            let generation = requestGeneration
            requestContinuation = continuation

            requestTimeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else {
                    return
                }
                self?.finishRequest(.timedOut, generation: generation)
            }

            let errorHandler: (Error) -> Void = { [weak self] error in
                Task { @MainActor in
                    self?.finishRequest(
                        .connectionFailure(error),
                        generation: generation
                    )
                }
            }
            guard let powerHelper = connection.remoteObjectProxyWithErrorHandler(errorHandler)
                as? CodexBarPowerHelperProtocol else {
                finishRequest(.connectionFailure(RequestError.invalidProxy), generation: generation)
                return
            }

            send(operation, to: powerHelper, generation: generation)
        }
    }

    private func send(
        _ operation: RequestOperation,
        to powerHelper: CodexBarPowerHelperProtocol,
        generation: UInt64
    ) {
        switch operation {
        case .status:
            let reply: @Sendable (Int32, Int, Int, Bool) -> Void = { [weak self] exitCode, ownershipRawValue, activeClientCount, sleepDisabled in
                Task { @MainActor in
                    guard exitCode == 0,
                          let ownership = CodexBarSleepOwnershipState(
                              rawValue: ownershipRawValue
                          ),
                          activeClientCount >= 0 else {
                        self?.finishRequest(
                            .invalidResponse(
                                exitCode: exitCode,
                                ownership: ownershipRawValue,
                                activeClientCount: activeClientCount
                            ),
                            generation: generation
                        )
                        return
                    }
                    self?.finishRequest(
                        .status(
                            PowerHelperRuntimeStatus(
                                ownership: ownership,
                                activeClientCount: activeClientCount,
                                sleepDisabled: sleepDisabled
                            )
                        ),
                        generation: generation
                    )
                }
            }
            powerHelper.getSleepPreventionStatus(reply: reply)
        case let .updateReset(updateIdentifier):
            let reply: @Sendable (Int32) -> Void = { [weak self] exitCode in
                Task { @MainActor in
                    self?.finishRequest(
                        .updateReset(exitCode: exitCode),
                        generation: generation
                    )
                }
            }
            powerHelper.resetSleepAfterUpdate(updateIdentifier, reply: reply)
        case let .wakeSchedule(unixTimestamp):
            let reply: @Sendable (Int32) -> Void = { [weak self] exitCode in
                Task { @MainActor in
                    self?.finishRequest(
                        .wakeSchedule(exitCode: exitCode),
                        generation: generation
                    )
                }
            }
            powerHelper.setAutoResetWakeSchedule(unixTimestamp, reply: reply)
        }
    }

    private func finishRequest(_ result: RequestResult, generation: UInt64) {
        guard generation == requestGeneration, let continuation = requestContinuation else {
            return
        }

        requestTimeoutTask?.cancel()
        requestTimeoutTask = nil
        requestContinuation = nil
        continuation.resume(returning: result)
    }

    private enum RequestResult {
        case status(PowerHelperRuntimeStatus)
        case updateReset(exitCode: Int32)
        case wakeSchedule(exitCode: Int32)
        case connectionFailure(Error)
        case invalidResponse(exitCode: Int32, ownership: Int, activeClientCount: Int)
        case timedOut
        case cancelled
    }

    private enum RequestOperation {
        case status
        case updateReset(String)
        case wakeSchedule(TimeInterval)
    }

    private enum RequestError: LocalizedError {
        case invalidProxy

        var errorDescription: String? {
            "服务接口无效"
        }
    }
}
