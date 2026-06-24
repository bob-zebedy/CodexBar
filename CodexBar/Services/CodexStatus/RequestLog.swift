import Combine
import Foundation
import os

/// JSON-RPC 交互日志: 带 id 的请求先记录为进行, 响应或错误到达后回填到同一条
/// `initialized` 这类无 id 请求没有响应可等, 单独记录为空响应
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

    static let summaryPreviewLength = 160
    static let expandedInlinePreviewLength = 260

    static func preview(_ text: String, limit: Int) -> String {
        guard limit > 0,
              let endIndex = text.index(text.startIndex, offsetBy: limit, limitedBy: text.endIndex),
              endIndex < text.endIndex else {
            return text
        }

        return String(text[..<endIndex]) + "..."
    }

    static func singleLinePreview(_ text: String, limit: Int) -> String {
        let firstLine = text.components(separatedBy: .newlines).first ?? ""
        let normalizedText = firstLine
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let displayText = preview(normalizedText, limit: limit)

        guard firstLine != text, !displayText.hasSuffix("...") else {
            return displayText
        }

        return displayText + "..."
    }
}

/// 常驻日志存储, 允许后台请求路径同步写入并立即拿到请求 token
final nonisolated class RequestLogStorage: Sendable {
    static let shared = RequestLogStorage()

    /// 环形上限避免长时间运行后日志无限增长
    private static let capacity = 500

    /// 最新在前, 既方便渲染也让刚发出的请求更快被回填
    private let storage = OSAllocatedUnfairLock(initialState: [RequestLogEntry]())

    var entries: [RequestLogEntry] {
        storage.withLock { $0 }
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
        storage.withLock {
            $0.removeAll()
        }

        notifyChange()
    }

    private func append(_ entry: RequestLogEntry) {
        storage.withLock {
            $0.insert(entry, at: 0)
            if $0.count > Self.capacity {
                $0.removeLast($0.count - Self.capacity)
            }
        }

        notifyChange()
    }

    private func update(_ id: UUID, _ mutate: @Sendable (inout RequestLogEntry) -> Void) {
        let didUpdate = storage.withLock {
            guard let index = $0.firstIndex(where: { $0.id == id }) else {
                return false
            }
            mutate(&$0[index])
            return true
        }

        guard didUpdate else {
            return
        }

        notifyChange()
    }

    private func notifyChange() {
        Task { @MainActor in
            RequestLogStore.shared.reloadFromStorage()
        }
    }

    /// 合法 JSON 重新序列化为稳定、未转义斜杠的日志文本; 非 JSON 错误消息保持原样
    private static func normalized(_ text: String) -> String {
        jsonNormalized(text) ?? text
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

/// SwiftUI 观察层只负责在主线程发布 storage 快照
@MainActor
final class RequestLogStore: ObservableObject {
    static let shared = RequestLogStore()

    @Published private(set) var entries: [RequestLogEntry]

    private let storage: RequestLogStorage

    init(storage: RequestLogStorage = .shared) {
        self.storage = storage
        entries = storage.entries
    }

    func clear() {
        storage.clear()
    }

    fileprivate func reloadFromStorage() {
        entries = storage.entries
    }
}
