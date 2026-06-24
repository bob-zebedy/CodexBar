import Combine
import Foundation

// JSON-RPC 交互日志: 带 id 的请求先记录为进行, 响应或错误到达后回填到同一条
// `initialized` 这类无 id 请求没有响应可等, 单独记录为空响应
nonisolated struct RequestLogEntry: Identifiable, Equatable {
    enum Kind {
        case pending
        case response
        case failure
        case emptyResponse
    }

    let id: UUID
    let requestedAt: Date
    var respondedAt: Date?
    var kind: Kind
    let method: String?
    let request: String?
    var detail: String?
}

// 常驻日志存储, 写入来自后台队列, storage 用锁保护, SwiftUI 通知切回主线程发送
nonisolated final class RequestLogStore: ObservableObject, @unchecked Sendable {
    static let shared = RequestLogStore()

    // nonisolated 存储不能用 @Published 包装可变数组, 这里手动发送变更
    let objectWillChange = ObservableObjectPublisher()

    // 环形上限避免长时间运行后日志无限增长
    private static let capacity = 500
    private static let maxDetailLength = 4000

    private let lock = NSLock()
    // 最新在前, 既方便渲染也让刚发出的请求更快被回填
    private var storage: [RequestLogEntry] = []

    var entries: [RequestLogEntry] {
        withLock { storage }
    }

    private init() {}

    func beginRequest(method: String, payload: String) -> UUID {
        let id = UUID()
        append(
            RequestLogEntry(
                id: id,
                requestedAt: Date(),
                respondedAt: nil,
                kind: .pending,
                method: method,
                request: Self.normalized(payload),
                detail: nil
            )
        )
        return id
    }

    func finishRequest(_ id: UUID, response: String) {
        update(id) { entry in
            entry.kind = .response
            entry.detail = Self.normalized(response)
            entry.respondedAt = Date()
        }
    }

    func failRequest(_ id: UUID, message: String) {
        update(id) { entry in
            entry.kind = .failure
            entry.detail = Self.normalized(message)
            entry.respondedAt = Date()
        }
    }

    func recordRequestWithEmptyResponse(method: String, payload: String) {
        append(
            RequestLogEntry(
                id: UUID(),
                requestedAt: Date(),
                respondedAt: nil,
                kind: .emptyResponse,
                method: method,
                request: Self.normalized(payload),
                detail: ""
            )
        )
    }

    func recordFailure(method: String? = nil, message: String) {
        append(
            RequestLogEntry(
                id: UUID(),
                requestedAt: Date(),
                respondedAt: nil,
                kind: .failure,
                method: method,
                request: nil,
                detail: Self.normalized(message)
            )
        )
    }

    func clear() {
        withLock {
            storage.removeAll()
        }

        notifyChange()
    }

    private func append(_ entry: RequestLogEntry) {
        withLock {
            storage.insert(entry, at: 0)
            if storage.count > Self.capacity {
                storage.removeLast(storage.count - Self.capacity)
            }
        }

        notifyChange()
    }

    private func update(_ id: UUID, _ mutate: (inout RequestLogEntry) -> Void) {
        let didUpdate = withLock {
            guard let index = storage.firstIndex(where: { $0.id == id }) else {
                return false
            }
            mutate(&storage[index])
            return true
        }

        guard didUpdate else {
            return
        }

        notifyChange()
    }

    private func withLock<T>(_ work: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return work()
    }

    private func notifyChange() {
        if Thread.isMainThread {
            objectWillChange.send()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.objectWillChange.send()
            }
        }
    }

    // 合法 JSON 重新序列化为稳定、未转义斜杠的日志文本; 非 JSON 错误消息保持原样
    private static func normalized(_ text: String) -> String {
        let readableText = jsonNormalized(text) ?? text
        guard readableText.count > maxDetailLength else {
            return readableText
        }

        return String(readableText.prefix(maxDetailLength)) + "…"
    }

    private static func jsonNormalized(_ text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object),
              let output = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys, .withoutEscapingSlashes]
              ) else {
            return nil
        }

        return String(bytes: output, encoding: .utf8)
    }
}
