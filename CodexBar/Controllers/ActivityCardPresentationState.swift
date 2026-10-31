import Combine
import Foundation

/// 生命周期由菜单控制器持有, 两种面板宿主共享同一份内存选择
@MainActor
final class ActivityCardPresentationState: ObservableObject {
    @Published private(set) var selection = ActivityCardSelection()
    private var subscription: AnyCancellable?
    private var returnTask: Task<Void, Never>?
    private var scheduledDeadline: Date?
    private var gestureOwner: UUID?

    init(activityMonitor: ActivityMonitor) {
        selection.update(snapshot: activityMonitor.snapshot, isHealthy: activityMonitor.isActivitySourceHealthy, now: Date())
        // 发布事务结束后再读取健康状态, 避免恢复时把旧的空快照当作完整结果
        subscription = activityMonitor.presentationPublisher
            .sink { [weak self, weak activityMonitor] update in
                guard let activityMonitor else { return }
                self?.change { $0.update(snapshot: update.snapshot, isHealthy: activityMonitor.isActivitySourceHealthy, now: Date()) }
            }
    }

    deinit {
        returnTask?.cancel()
    }

    func setVisible(_ visible: Bool) {
        if !visible {
            gestureOwner = nil
        }
        change { $0.setVisible(visible, now: Date()) }
    }

    func swipe(_ step: Int) {
        change { $0.swipe(step, now: Date()) }
    }

    func selectAfterSwipe(_ id: String, owner: UUID) {
        guard gestureOwner == owner else { return }
        change { $0.selectAfterSwipe(id, now: Date()) }
    }

    func togglePin() {
        change { $0.togglePin(now: Date()) }
    }

    func setGestureActive(_ active: Bool, owner: UUID) {
        if active {
            guard selection.isVisible else { return }
            gestureOwner = owner
        } else {
            // 关闭的宿主可能晚于新宿主完成清理, 只能释放自己持有的手势
            guard gestureOwner == owner else { return }
            gestureOwner = nil
        }
        change { $0.setGestureActive(active, now: Date()) }
    }

    private func change(_ operation: (inout ActivityCardSelection) -> Void) {
        var updated = selection
        operation(&updated)
        if updated != selection {
            selection = updated
        }
        scheduleReturn()
    }

    private func scheduleReturn() {
        let deadline = selection.returnDeadline
        guard deadline != scheduledDeadline else { return }
        returnTask?.cancel()
        returnTask = nil
        scheduledDeadline = deadline
        guard let deadline else { return }
        returnTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
            guard let self, !Task.isCancelled else { return }
            scheduledDeadline = nil
            returnTask = nil
            change { $0.reconcile(at: Date()) }
        }
    }
}
