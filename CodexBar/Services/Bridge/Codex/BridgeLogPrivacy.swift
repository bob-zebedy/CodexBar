import Foundation

/// 识别 Bridge 线程, 供其他连接隐藏日志中的消息内容, 业务仍处理原始消息
final nonisolated class BridgeLogPrivacy: @unchecked Sendable {
    static let shared = BridgeLogPrivacy()
    private static let limit = 8192
    private let lock = NSLock()
    private var threads = Set<String>()
    private var saturated = false
    private var restoring = false
    private var pendingChildren: [String: Set<String>] = [:]
    private var pendingCount = 0

    func beginRestoration() {
        lock.withLock { restoring = true }
    }

    func finishRestoration() {
        lock.withLock { restoring = false }
    }

    func register(_ id: String) {
        lock.withLock { registerSubtree(id) }
    }

    private func registerSubtree(_ id: String) {
        var pending = [id]
        while let next = pending.popLast(), !saturated {
            guard threads.insert(next).inserted else { continue }
            guard threads.count <= Self.limit else {
                protectAllThreads()
                return
            }
            if let children = pendingChildren.removeValue(forKey: next) {
                pendingCount -= children.count
                pending.append(contentsOf: children)
            }
        }
    }

    private func link(_ child: String, to parent: String) {
        guard !saturated, !threads.contains(child) else { return }
        if threads.contains(parent) {
            registerSubtree(child)
            return
        }
        if pendingChildren[parent, default: []].insert(child).inserted {
            pendingCount += 1
        }
    }

    private func trimPendingChildren() {
        guard pendingCount > Self.limit else { return }
        if restoring {
            protectAllThreads()
            return
        }
        // 先处理本页所有父子关系, 待确认关系太多时只丢弃超出的部分, 无需隐藏所有线程的日志正文
        while pendingCount > Self.limit, let parent = pendingChildren.keys.first {
            pendingChildren[parent]?.removeFirst()
            pendingCount -= 1
            if pendingChildren[parent]?.isEmpty == true {
                pendingChildren[parent] = nil
            }
        }
    }

    private func protectAllThreads() {
        saturated = true
        threads.removeAll()
        pendingChildren.removeAll()
        pendingCount = 0
    }

    func trackThreadsAndCheckRedaction(_ object: [String: Any]?, threadID: String? = nil, method: String? = nil) -> Bool {
        let params = object?["params"] as? [String: Any]
        let result = object?["result"] as? [String: Any]
        let thread = (params?["thread"] ?? result?["thread"]) as? [String: Any]
        let id = thread?["id"] as? String ?? params?["threadId"] as? String ?? threadID
        let page = result?["data"] as? [[String: Any]] ?? []
        var ids: [String] = []
        var roots: [String] = []
        var parents: [String: String] = [:]
        let method = method ?? object?["method"] as? String
        let threadPage = method == "thread/list"
        for entry in page + (thread.map { [$0] } ?? []) {
            guard let id = entry["id"] as? String else { continue }
            if threadPage || entry["source"] != nil || entry["threadSource"] != nil || entry["parentThreadId"] != nil {
                ids.append(id)
            }
            if entry["threadSource"] as? String == "codexbar_bridge" {
                roots.append(id)
            }
            if let parent = entry["parentThreadId"] as? String {
                parents[id] = parent
            } else if let source = entry["source"] as? [String: Any],
                      let data = try? JSONSerialization.data(withJSONObject: source) {
                parents[id] = (try? JSONDecoder().decode(WireActivityThreadSource.self, from: data))?.parentThreadID
            }
        }
        return lock.withLock {
            roots.forEach(registerSubtree)
            for (child, parent) in parents {
                link(child, to: parent)
            }
            trimPendingChildren()
            if restoring {
                return method?.hasPrefix("account/") != true || id != nil || !ids.isEmpty
            }
            return (id != nil || !ids.isEmpty) && (saturated || id.map(threads.contains) == true || ids.contains(where: threads.contains))
        }
    }
}
