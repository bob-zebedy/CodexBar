import Foundation
import os

/// 小型刷新任务状态机, 由 MainActor ViewModel 持有和调用
final nonisolated class RefreshTaskCoordinator: Sendable {
    private struct State {
        var task: Task<Void, Never>?
        var generation = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    deinit {
        cancel()
    }

    @MainActor
    @discardableResult
    func start(_ operation: @escaping @MainActor @Sendable (_ generation: Int) async -> Void) -> Int {
        let generation = begin()
        store(Task { @MainActor in
            await operation(generation)
        })
        return generation
    }

    /// ViewModel 共用的刷新样板: 置位刷新标记 → 取数 → 仅当代际未过期时提交
    /// 过期刷新结果直接丢弃, 避免慢请求覆盖后启动的新状态
    @MainActor
    func run<Value>(
        setRefreshing: @escaping @MainActor @Sendable (Bool) -> Void,
        operation: @escaping @MainActor @Sendable () async -> Value,
        commit: @escaping @MainActor @Sendable (Value) -> Void
    ) {
        setRefreshing(true)
        start { [self] generation in
            defer {
                finish(generation) {
                    setRefreshing(false)
                }
            }

            let value = await operation()
            guard canCommit(generation) else {
                return
            }

            commit(value)
        }
    }

    private func begin() -> Int {
        let (task, generation) = state.withLock {
            let task = $0.task
            $0.task = nil
            $0.generation += 1
            return (task, $0.generation)
        }
        task?.cancel()
        return generation
    }

    private func store(_ task: Task<Void, Never>) {
        state.withLock {
            $0.task = task
        }
    }

    func canCommit(_ generation: Int) -> Bool {
        !Task.isCancelled && state.withLock {
            generation == $0.generation
        }
    }

    @discardableResult
    private func finish(_ generation: Int) -> Bool {
        state.withLock {
            guard generation == $0.generation else {
                return false
            }

            $0.task = nil
            return true
        }
    }

    @MainActor
    @discardableResult
    func finish(_ generation: Int, onCurrentGeneration: () -> Void) -> Bool {
        let didFinish = finish(generation)
        if didFinish {
            onCurrentGeneration()
        }
        return didFinish
    }

    func cancel() {
        let task = state.withLock {
            let task = $0.task
            $0.task = nil
            $0.generation += 1
            return task
        }
        task?.cancel()
    }
}
