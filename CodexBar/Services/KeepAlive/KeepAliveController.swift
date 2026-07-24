import AppKit
import Combine
import CryptoKit
import Foundation
import IOKit
import ServiceManagement

@MainActor
final class KeepAliveController: ObservableObject {
    @Published private(set) var isEnabled: Bool
    @Published private(set) var maximumDuration: MaximumDuration
    @Published private(set) var helperStatus = HelperStatus.notRegistered
    @Published private(set) var isPreventingSleep = false
    @Published private(set) var hasReachedMaximumDuration = false
    @Published private(set) var errorMessage: String?

    private let activityMonitor: CodexActivityMonitor
    private let codexHookSettings: CodexHookSettings
    private let defaults: UserDefaults
    private let systemSleepService = SystemSleepService()
    private var hasRunningTasks = false
    /// 保留仍活跃且已经进入过运行态的任务, 避免普通快照刷新被误判成新任务
    private var startedRunningTaskIDs = Set<UUID>()
    /// 记录上一份快照中的等待任务, 用于识别等待批准后恢复运行的状态转换
    private var waitingTaskIDs = Set<UUID>()
    private var connection: NSXPCConnection?
    private var appliedSleepDisabled: Bool?
    private var requestInFlight = false
    private var requestGeneration: UInt64 = 0
    private var retryTask: Task<Void, Never>?
    private var maximumDurationTask: Task<Void, Never>?
    private var maximumDurationStartedAt: Date?
    private var helperRegistrationTask: Task<Void, Never>?
    private var isRefreshingHelper = false
    private var cancellables = Set<AnyCancellable>()
    private var isStarted = false

    init(
        activityMonitor: CodexActivityMonitor,
        codexHookSettings: CodexHookSettings,
        defaults: UserDefaults = .standard
    ) {
        self.activityMonitor = activityMonitor
        self.codexHookSettings = codexHookSettings
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        maximumDuration = (defaults.object(forKey: Self.maximumDurationKey) as? Int)
            .flatMap(MaximumDuration.init(rawValue:)) ?? .twelveHours
    }

    func start() {
        guard !isStarted else {
            return
        }
        isStarted = true

        codexHookSettings.$isEnabled
            .removeDuplicates()
            .sink { [weak self] isHookEnabled in
                guard !isHookEnabled else {
                    return
                }
                self?.setEnabled(false)
            }
            .store(in: &cancellables)

        activityMonitor.$snapshot
            .sink { [weak self] snapshot in
                self?.handleActivitySnapshot(snapshot)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)

        refreshRegistrationAndSleepState()
    }

    func stop() {
        guard isStarted else {
            return
        }
        isStarted = false
        cancellables.removeAll()
        cancelRetryTask()
        cancelHelperRegistrationTask()
        startedRunningTaskIDs.removeAll()
        waitingTaskIDs.removeAll()
        resetMaximumDurationState()

        if connection != nil {
            applySleepDisabled(false)
        }
        _ = systemSleepService.endPreventingIdleSleep()
        invalidateConnection()
    }

    func refresh() {
        refreshRegistrationAndSleepState()
    }

    private func refreshRegistrationAndSleepState() {
        refreshHelperStatus()
        if isEnabled || helperStatus.isRegisteredOrAwaitingApproval {
            ensureHelperRegistration(opensSystemSettings: false)
        }
        reconcileSleepState()
    }

    func setEnabled(_ enabled: Bool) {
        guard !enabled || codexHookSettings.isEnabled else {
            return
        }
        guard enabled != isEnabled else {
            return
        }

        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        errorMessage = nil

        if enabled {
            ensureHelperRegistration(opensSystemSettings: true)
        } else {
            resetMaximumDurationState()
        }
        reconcileSleepState()
    }

    func setMaximumDuration(_ duration: MaximumDuration) {
        guard duration != maximumDuration else {
            return
        }

        maximumDuration = duration
        defaults.set(duration.rawValue, forKey: Self.maximumDurationKey)

        guard let maximumDurationStartedAt else {
            return
        }

        if let deadline = maximumDurationDeadline(from: maximumDurationStartedAt),
           Date() >= deadline {
            reachMaximumDuration()
            return
        }

        hasReachedMaximumDuration = false
        scheduleMaximumDurationTask()
        reconcileSleepState()
    }

    private func handleActivitySnapshot(_ snapshot: CodexActivitySnapshot) {
        let runningTaskIDs = Set(snapshot.runningTasks.map(\.id))
        let currentWaitingTaskIDs = Set(snapshot.waitingTasks.map(\.id))
        let activeTaskIDs = runningTaskIDs.union(currentWaitingTaskIDs)

        startedRunningTaskIDs.formIntersection(activeTaskIDs)
        let newRunningTaskIDs = runningTaskIDs.subtracting(startedRunningTaskIDs)
        let resumedRunningTaskIDs = runningTaskIDs
            .intersection(waitingTaskIDs)
            .subtracting(currentWaitingTaskIDs)
        startedRunningTaskIDs.formUnion(runningTaskIDs)
        waitingTaskIDs = currentWaitingTaskIDs

        hasRunningTasks = !runningTaskIDs.isEmpty
        if activeTaskIDs.isEmpty {
            resetMaximumDurationState()
        } else if !newRunningTaskIDs.isEmpty || !resumedRunningTaskIDs.isEmpty {
            restartMaximumDurationPeriod()
        }
        reconcileSleepState()
    }

    private func restartMaximumDurationPeriod() {
        guard isEnabled else {
            return
        }

        maximumDurationStartedAt = Date()
        hasReachedMaximumDuration = false
        if helperStatus == .enabled, !isRefreshingHelper {
            scheduleMaximumDurationTask()
        }
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func ensureHelperRegistration(opensSystemSettings: Bool) {
        let service = Self.helperService
        refreshHelperStatus()

        switch helperStatus {
        case .enabled, .requiresApproval:
            if helperRegistrationNeedsRefresh {
                refreshRegisteredHelper(opensSystemSettings: opensSystemSettings)
            } else if helperStatus == .requiresApproval, opensSystemSettings {
                openSystemSettings()
            }
            return
        case .notRegistered, .notFound:
            guard Self.helperAssetsArePresent else {
                errorMessage = "服务异常, 请重新安装 CodexBar"
                return
            }
        }

        do {
            try service.register()
        } catch {
            refreshHelperStatus()
            if !helperStatus.isRegisteredOrAwaitingApproval {
                errorMessage = "注册服务失败: \(error.localizedDescription)"
            }
        }

        refreshHelperStatus()
        recordHelperRegistrationIfCurrent()
        if helperStatus == .requiresApproval, opensSystemSettings {
            openSystemSettings()
        }
    }

    private func refreshRegisteredHelper(opensSystemSettings: Bool) {
        guard helperRegistrationTask == nil,
              Self.helperAssetsArePresent else {
            return
        }

        isRefreshingHelper = true
        cancelRetryTask()
        invalidateConnection()
        errorMessage = nil

        let service = Self.helperService
        helperRegistrationTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            var registrationError: Error?
            do {
                try Task.checkCancellation()
                try await service.unregister()
                try Task.checkCancellation()
                try await registerRefreshedHelper(service)
            } catch is CancellationError {
                return
            } catch {
                registrationError = error
            }

            guard isStarted, !Task.isCancelled else {
                return
            }

            refreshHelperStatus()
            if helperStatus.isRegisteredOrAwaitingApproval {
                recordHelperRegistrationIfCurrent()
            } else if let registrationError {
                errorMessage = "更新服务失败: \(registrationError.localizedDescription)"
            }

            isRefreshingHelper = false
            helperRegistrationTask = nil
            if helperStatus == .requiresApproval, opensSystemSettings {
                openSystemSettings()
            }
            reconcileSleepState(force: true)
        }
    }

    private func registerRefreshedHelper(_ service: SMAppService) async throws {
        await Task.yield()

        var retryDelays = Self.helperRegistrationRetryDelays.makeIterator()
        while true {
            do {
                try service.register()
                return
            } catch {
                guard Self.isTransientHelperRegistrationError(error),
                      let retryDelay = retryDelays.next() else {
                    throw error
                }
                try await Task.sleep(for: retryDelay)
            }
        }
    }

    private static func isTransientHelperRegistrationError(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == SMAppServiceErrorDomain
            && error.code == operationNotPermittedErrorCode
    }

    private func refreshHelperStatus() {
        helperStatus = HelperStatus(Self.helperService.status)
        if helperStatus == .enabled {
            errorMessage = nil
        } else if helperStatus != .requiresApproval {
            _ = systemSleepService.endPreventingIdleSleep()
            isPreventingSleep = false
            resetMaximumDurationState()
        }
    }

    private func reconcileSleepState(force: Bool = false) {
        let wantsSleepDisabled = shouldDisableSleep

        guard wantsSleepDisabled else {
            cancelRetryTask()
            if connection != nil, appliedSleepDisabled != false || isPreventingSleep {
                applySleepDisabled(false)
            } else {
                _ = systemSleepService.endPreventingIdleSleep()
            }
            return
        }

        if force {
            appliedSleepDisabled = nil
        }
        applySleepDisabled(true)
    }

    private func applySleepDisabled(_ disabled: Bool) {
        guard appliedSleepDisabled != disabled else {
            return
        }

        if disabled {
            let result = systemSleepService.beginPreventingIdleSleep()
            guard result == kIOReturnSuccess else {
                errorMessage = "阻止空闲休眠失败 (\(result))"
                scheduleRetryIfNeeded(for: true)
                return
            }
        }

        let connection = connection ?? makeConnection()
        appliedSleepDisabled = disabled
        requestInFlight = true
        requestGeneration &+= 1
        let generation = requestGeneration

        let errorHandler: (Error) -> Void = { [weak self] error in
            Task { @MainActor in
                guard let self, generation == self.requestGeneration else {
                    return
                }
                self.handleConnectionFailure(error)
            }
        }
        guard let helper = connection.remoteObjectProxyWithErrorHandler(errorHandler)
            as? CodexBarHelperProtocol else {
            handleConnectionFailure(KeepAliveError.invalidHelperProxy)
            return
        }

        helper.setSleepDisabled(disabled) { [weak self] exitCode, sleepDisabledAfterOperation in
            Task { @MainActor in
                guard let self, generation == self.requestGeneration else {
                    return
                }
                self.requestInFlight = false
                guard exitCode == 0 else {
                    if disabled {
                        _ = self.systemSleepService.endPreventingIdleSleep()
                    }
                    self.invalidateConnection()
                    self.errorMessage = "切换休眠状态失败 (\(exitCode))"
                    self.scheduleRetryIfNeeded(for: disabled)
                    return
                }

                self.cancelRetryTask()
                self.isPreventingSleep = disabled
                self.errorMessage = nil
                if disabled {
                    self.beginMaximumDurationCountdownIfNeeded()
                } else {
                    self.finishSleepRestore(
                        sleepDisabledAfterOperation: sleepDisabledAfterOperation
                    )
                }
            }
        }
    }

    private func beginMaximumDurationCountdownIfNeeded() {
        if maximumDurationStartedAt == nil {
            maximumDurationStartedAt = Date()
            hasReachedMaximumDuration = false
        }
        scheduleMaximumDurationTask()
    }

    private func scheduleMaximumDurationTask() {
        cancelMaximumDurationTask()

        guard isStarted,
              let maximumDurationStartedAt,
              !hasReachedMaximumDuration else {
            return
        }

        guard let deadline = maximumDurationDeadline(from: maximumDurationStartedAt) else {
            return
        }

        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else {
            reachMaximumDuration()
            return
        }

        maximumDurationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled, let self else {
                return
            }
            maximumDurationTask = nil
            reachMaximumDuration()
        }
    }

    private func reachMaximumDuration() {
        guard maximumDurationStartedAt != nil,
              !hasReachedMaximumDuration else {
            return
        }

        cancelMaximumDurationTask()
        hasReachedMaximumDuration = true
        reconcileSleepState()
    }

    private func finishSleepRestore(sleepDisabledAfterOperation: Bool) {
        let idleSleepResult = systemSleepService.endPreventingIdleSleep()
        if idleSleepResult != kIOReturnSuccess {
            errorMessage = "恢复空闲休眠策略失败 (\(idleSleepResult))"
        }

        let shouldRequestSystemSleep = !sleepDisabledAfterOperation
            && SystemSleepService.currentStatus()?.shouldSleepForLidClosure == true

        guard shouldRequestSystemSleep else {
            return
        }

        let result = SystemSleepService.requestSystemSleep()
        if result != kIOReturnSuccess {
            errorMessage = "请求系统休眠失败 (\(result))"
        }
    }

    private func resetMaximumDurationState() {
        cancelMaximumDurationTask()
        maximumDurationStartedAt = nil
        hasReachedMaximumDuration = false
    }

    private func cancelMaximumDurationTask() {
        maximumDurationTask?.cancel()
        maximumDurationTask = nil
    }

    private func maximumDurationDeadline(from startedAt: Date) -> Date? {
        maximumDuration.timeInterval.map(startedAt.addingTimeInterval)
    }

    private func makeConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(
            machServiceName: CodexBarHelperIPC.machServiceName,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(
            with: CodexBarHelperProtocol.self
        )
        connection.invalidationHandler = { [weak self, weak connection] in
            Task { @MainActor in
                guard let self, self.connection === connection else {
                    return
                }
                let shouldRetry = self.requestInFlight || self.isPreventingSleep
                let desiredSleepDisabled = self.shouldDisableSleep
                self.connection = nil
                self.appliedSleepDisabled = nil
                self.requestInFlight = false
                self.isPreventingSleep = false
                if shouldRetry {
                    self.scheduleRetryIfNeeded(for: desiredSleepDisabled)
                }
            }
        }
        connection.interruptionHandler = { [weak self] in
            Task { @MainActor in
                self?.handleConnectionFailure(KeepAliveError.connectionInterrupted)
            }
        }
        connection.resume()
        self.connection = connection
        return connection
    }

    private func handleConnectionFailure(_ error: Error) {
        let shouldRetry = requestInFlight || isPreventingSleep
        let desiredSleepDisabled = shouldDisableSleep
        invalidateConnection()
        errorMessage = "连接服务失败: \(error.localizedDescription)"
        if shouldRetry {
            scheduleRetryIfNeeded(for: desiredSleepDisabled)
        }
    }

    private func invalidateConnection() {
        requestGeneration &+= 1
        let connection = connection
        self.connection = nil
        connection?.invalidationHandler = nil
        connection?.interruptionHandler = nil
        connection?.invalidate()
        appliedSleepDisabled = nil
        requestInFlight = false
        isPreventingSleep = false
    }

    private func cancelRetryTask() {
        retryTask?.cancel()
        retryTask = nil
    }

    private func cancelHelperRegistrationTask() {
        helperRegistrationTask?.cancel()
        helperRegistrationTask = nil
        isRefreshingHelper = false
    }

    private func scheduleRetryIfNeeded(for disabled: Bool) {
        guard isStarted,
              helperStatus == .enabled,
              disabled == shouldDisableSleep,
              retryTask == nil else {
            return
        }

        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else {
                return
            }
            retryTask = nil
            guard disabled == shouldDisableSleep else {
                reconcileSleepState()
                return
            }
            appliedSleepDisabled = nil
            applySleepDisabled(disabled)
        }
    }

    private var shouldDisableSleep: Bool {
        isStarted
            && isEnabled
            && hasRunningTasks
            && helperStatus == .enabled
            && !isRefreshingHelper
            && !hasReachedMaximumDuration
    }

    private static let enabledKey = "KeepAlive.isEnabled"
    private static let maximumDurationKey = "KeepAlive.maximumContinuousDurationSeconds"
    private static let helperRegistrationFingerprintKey =
        "KeepAlive.helperRegistrationFingerprint"
    private static let helperRegistrationRetryDelays: [Duration] = [
        .milliseconds(500),
        .seconds(1),
        .seconds(2)
    ]
    private static let operationNotPermittedErrorCode = 1

    private static var helperService: SMAppService {
        SMAppService.daemon(plistName: CodexBarHelperIPC.daemonPlistName)
    }

    private static var helperAssetsArePresent: Bool {
        FileManager.default.fileExists(atPath: daemonPlistURL.path)
            && FileManager.default.isExecutableFile(atPath: helperExecutableURL.path)
    }

    private var helperRegistrationNeedsRefresh: Bool {
        guard let fingerprint = Self.helperRegistrationFingerprint else {
            return false
        }
        return defaults.string(forKey: Self.helperRegistrationFingerprintKey) != fingerprint
    }

    private func recordHelperRegistrationIfCurrent() {
        guard helperStatus.isRegisteredOrAwaitingApproval,
              let fingerprint = Self.helperRegistrationFingerprint else {
            return
        }
        defaults.set(fingerprint, forKey: Self.helperRegistrationFingerprintKey)
    }

    private static var helperRegistrationFingerprint: String? {
        guard let helperData = try? Data(contentsOf: helperExecutableURL, options: .mappedIfSafe),
              let daemonPlistData = try? Data(contentsOf: daemonPlistURL, options: .mappedIfSafe) else {
            return nil
        }

        var hasher = SHA256()
        for (name, data) in [
            (helperExecutableURL.lastPathComponent, helperData),
            (daemonPlistURL.lastPathComponent, daemonPlistData)
        ] {
            hasher.update(data: Data("\(name)\n\(data.count)\n".utf8))
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static var appContentsURL: URL {
        Bundle.main.bundleURL.appending(path: "Contents", directoryHint: .isDirectory)
    }

    private static var helperExecutableURL: URL {
        appContentsURL
            .appending(path: "Resources", directoryHint: .isDirectory)
            .appending(path: "CodexBarHelper")
    }

    private static var daemonPlistURL: URL {
        appContentsURL
            .appending(path: "Library/LaunchDaemons", directoryHint: .isDirectory)
            .appending(path: CodexBarHelperIPC.daemonPlistName)
    }
}

extension KeepAliveController {
    enum MaximumDuration: Int, CaseIterable, Identifiable {
        case oneHour = 3600
        case twoHours = 7200
        case fourHours = 14400
        case eightHours = 28800
        case twelveHours = 43200
        case twentyFourHours = 86400
        case unlimited = -1

        var id: Int {
            rawValue
        }

        var title: String {
            switch self {
            case .oneHour:
                "1 小时"
            case .twoHours:
                "2 小时"
            case .fourHours:
                "4 小时"
            case .eightHours:
                "8 小时"
            case .twelveHours:
                "12 小时"
            case .twentyFourHours:
                "24 小时"
            case .unlimited:
                "无限制"
            }
        }

        var timeInterval: TimeInterval? {
            self == .unlimited ? nil : TimeInterval(rawValue)
        }
    }

    enum HelperStatus: Equatable {
        case notRegistered
        case enabled
        case requiresApproval
        case notFound

        var isRegisteredOrAwaitingApproval: Bool {
            self == .enabled || self == .requiresApproval
        }

        init(_ status: SMAppService.Status) {
            switch status {
            case .notRegistered:
                self = .notRegistered
            case .enabled:
                self = .enabled
            case .requiresApproval:
                self = .requiresApproval
            case .notFound:
                self = .notFound
            @unknown default:
                self = .notFound
            }
        }
    }
}

private enum KeepAliveError: LocalizedError {
    case invalidHelperProxy
    case connectionInterrupted

    var errorDescription: String? {
        switch self {
        case .invalidHelperProxy:
            "服务接口无效"
        case .connectionInterrupted:
            "服务连接中断"
        }
    }
}
