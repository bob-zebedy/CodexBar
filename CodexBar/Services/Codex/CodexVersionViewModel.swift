import Combine
import Foundation

/// 设置页的安装版本状态, 对刷新请求节流并通过协调器丢弃过期结果
@MainActor
final class CodexVersionViewModel: ObservableObject {
    @Published private(set) var snapshot = CodexVersionSnapshot.empty
    @Published private(set) var isRefreshing = false

    /// onAppear 和 didBecomeActive 常连发
    /// 版本检测需要节流以避免频繁启动子进程
    private static let refreshThrottle: TimeInterval = 60

    private let service: CodexVersionService
    private let refreshCoordinator = RefreshTaskCoordinator()

    init(service: CodexVersionService = CodexVersionService()) {
        self.service = service
    }

    deinit {
        refreshCoordinator.cancel()
    }

    func refresh(force: Bool = false) {
        guard !isRefreshing,
              force || Date().timeIntervalSince(snapshot.refreshedAt) > Self.refreshThrottle else {
            return
        }

        refreshCoordinator.run(
            setRefreshing: { [weak self] in self?.isRefreshing = $0 },
            operation: { [service = self.service] in await service.fetchSnapshot() },
            commit: { [weak self] snapshot in self?.snapshot = snapshot }
        )
    }
}
