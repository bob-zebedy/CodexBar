import Combine
import Foundation

@MainActor
final class CodexServiceStatusMonitor: ObservableObject {
    enum State: Equatable {
        case checking
        case available(CodexServiceStatus)
        case unavailable
    }

    @Published private(set) var state: State = .checking
    private let fetch: @Sendable () async throws -> CodexServiceStatus
    private var isEnabled = false
    private var refreshTask: Task<Void, Never>?

    convenience init() {
        let service = CodexServiceStatusService()
        self.init(fetch: { try await service.fetch() })
    }

    init(fetch: @escaping @Sendable () async throws -> CodexServiceStatus) {
        self.fetch = fetch
    }

    deinit {
        refreshTask?.cancel()
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if !enabled {
            refreshTask?.cancel()
            refreshTask = nil
        }
    }

    func refresh() async {
        guard isEnabled, !Task.isCancelled else { return }
        if refreshTask == nil {
            state = .checking
            refreshTask = Task { [weak self, fetch] in
                let result: State
                do {
                    result = try await .available(fetch())
                } catch {
                    result = .unavailable
                }
                // 关闭分区后取消的旧请求不能覆盖重新启用后的结果
                guard !Task.isCancelled, let self else { return }
                state = result
                refreshTask = nil
            }
        }
        await refreshTask?.value
    }
}
