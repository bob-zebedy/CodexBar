import Combine
import Foundation

@MainActor
final class CodexProxySettings: ObservableObject {
    enum TestResult: Equatable {
        case success
        case validation(CodexProxyConfiguration.ValidationIssue)
        case authenticationRequired
        case loginRequired
        case timeout
        case codexUnavailable
        case failed
        case loadFailed
        case saveFailed
        case clearFailed

        var title: String {
            switch self {
            case .success: String(localized: "proxy.test.connected")
            case let .validation(issue): issue.title
            case .authenticationRequired: String(localized: "proxy.test.proxy-authentication-failed")
            case .loginRequired: String(localized: "proxy.test.codex-login-required")
            case .timeout: String(localized: "proxy.test.timed-out")
            case .codexUnavailable: String(localized: "proxy.test.codex-unavailable")
            case .failed: String(localized: "proxy.test.connection-failed")
            case .loadFailed: String(localized: "proxy.feedback.load-failed")
            case .saveFailed: String(localized: "proxy.feedback.save-failed")
            case .clearFailed: String(localized: "proxy.feedback.clear-failed")
            }
        }

        static func failure(for error: Error) -> Self {
            guard let error = error as? CodexStatusError else { return .failed }
            if error.isAuthenticationRequired {
                return .loginRequired
            }
            switch error {
            case .serverTimeout:
                return .timeout
            case .executableNotFound, .sourceUnavailable, .unsupportedVersion, .unsupportedMethod:
                return .codexUnavailable
            case let .serverError(message):
                let message = message.lowercased()
                if message.contains("proxy authentication required") {
                    return .authenticationRequired
                }
                if message.contains("401 unauthorized") {
                    return .loginRequired
                }
                if message.contains("timed out") || message.contains("timeout") {
                    return .timeout
                }
                return .failed
            default:
                return .failed
            }
        }
    }

    @Published private(set) var configuration: CodexProxyConfiguration?
    @Published private(set) var hasStoredConfiguration: Bool
    @Published var draft = CodexProxyConfiguration()
    @Published var password = ""
    @Published private(set) var isSaving = false
    @Published private(set) var testResult: TestResult?
    @Published private(set) var showsValidationErrors = false

    private let service: CodexStatusService
    private let defaults: UserDefaults
    @Published private var testTask: Task<Void, Never>?

    var isTesting: Bool {
        testTask != nil
    }

    init(service: CodexStatusService, defaults: UserDefaults = .standard) {
        self.service = service
        self.defaults = defaults
        hasStoredConfiguration = CodexProxyStore.containsConfiguration(in: defaults)
        configuration = try? CodexProxyStore.load(from: defaults)?.configuration
    }

    var invalidFields: Set<CodexProxyConfiguration.InputField> {
        Set(validationIssues.map(\.field))
    }

    var validationIssues: [CodexProxyConfiguration.ValidationIssue] {
        showsValidationErrors ? draft.validationIssues : []
    }

    var feedback: TestResult? {
        if let issue = validationIssues.first {
            return .validation(issue)
        }
        return testResult
    }

    func loadDraft(showValidationErrors: Bool = false) {
        showsValidationErrors = showValidationErrors
        cancelTest()
        password = ""
        hasStoredConfiguration = CodexProxyStore.containsConfiguration(in: defaults)
        do {
            let stored = try CodexProxyStore.load(from: defaults)
            configuration = stored?.configuration
            draft = configuration ?? CodexProxyConfiguration()
            password = stored?.password ?? ""
        } catch {
            configuration = nil
            draft = CodexProxyConfiguration()
            testResult = .loadFailed
        }
    }

    func draftChanged() {
        cancelTest()
    }

    func closeDraft() {
        showsValidationErrors = false
        cancelTest()
        password = ""
    }

    func cancelTest() {
        testTask?.cancel()
        testTask = nil
        testResult = nil
    }

    func testConnection(source: CodexCLISourceSelection) {
        cancelTest()
        showsValidationErrors = true
        guard validationIssues.isEmpty else { return }
        let configuration = draft
        let password = password
        testTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let worker = Task.detached {
                try CodexProxyConnectionTester.test(configuration: configuration, password: password, source: source)
            }
            do {
                try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard let self, !Task.isCancelled else { return }
                testResult = .success
            } catch {
                guard let self, !Task.isCancelled else { return }
                testResult = TestResult.failure(for: error)
            }
            guard let self, !Task.isCancelled else { return }
            testTask = nil
        }
    }

    func setEnabled(_ enabled: Bool, onCompletion: @escaping (Bool) -> Void) {
        guard !isSaving else { return }
        showsValidationErrors = false
        do {
            guard let stored = try CodexProxyStore.load(from: defaults) else {
                onCompletion(false)
                return
            }
            var configuration = stored.configuration
            if enabled, !configuration.validationIssues.isEmpty {
                loadDraft(showValidationErrors: true)
                onCompletion(false)
                return
            }
            configuration.isEnabled = enabled
            // 在创建异步任务前提交显示状态并锁定开关, 连续点击不会重复排队
            isSaving = true
            self.configuration = configuration
            Task {
                let succeeded: Bool
                do {
                    try await service.applyProxy(configuration, password: stored.password)
                    hasStoredConfiguration = true
                    draft.isEnabled = enabled
                    succeeded = true
                } catch {
                    self.configuration = stored.configuration
                    succeeded = false
                }
                isSaving = false
                onCompletion(succeeded)
            }
        } catch {
            onCompletion(false)
        }
    }

    func save(clear: Bool = false) async -> Bool {
        guard !isSaving else { return false }
        cancelTest()
        if !clear {
            showsValidationErrors = true
            guard validationIssues.isEmpty else { return false }
        } else {
            showsValidationErrors = false
        }
        isSaving = true
        defer { isSaving = false }
        do {
            let configuration = clear ? nil : try draft.validated()
            try await service.applyProxy(configuration, password: password)
            self.configuration = configuration
            hasStoredConfiguration = configuration != nil
            if clear {
                draft = CodexProxyConfiguration()
                password = ""
            }
            return true
        } catch {
            testResult = clear ? .clearFailed : .saveFailed
            return false
        }
    }
}
