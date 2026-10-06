import Foundation

/// JSON-RPC 交互日志: 带 id 的请求先记录为进行
/// 响应或错误到达后回填到同一条
/// 无需配对的消息单独记录, request 和 detail 分别保留发送与接收内容
nonisolated struct AppServerLogEntry: Identifiable, Equatable, Codable, Sendable {
    enum Source: String, Codable, Sendable {
        case request
        case sent
        case received
        case connection
        case local
    }

    enum Status: String, Codable, Sendable {
        case pending
        case success
        case failure
        case information
    }

    var position: Int64 = 0
    let id: UUID
    var connection: String?
    let requestedAt: Date
    var respondedAt: Date?
    let source: Source
    var status: Status
    let method: String?
    var request: String?
    var detail: String?
    var requestOriginalBytes: Int?
    var detailOriginalBytes: Int?

    func bounded(to limit: Int) -> Self {
        var result = self
        if let request, request.utf8.count > limit {
            result.requestOriginalBytes = requestOriginalBytes ?? request.utf8.count
            result.request = Self.truncated(request, limit: limit)
        }
        if let detail, detail.utf8.count > limit {
            result.detailOriginalBytes = detailOriginalBytes ?? detail.utf8.count
            result.detail = Self.truncated(detail, limit: limit)
        }
        return result
    }

    static func truncated(_ text: String, limit: Int) -> String {
        guard text.utf8.count > limit else { return text }
        let marker = "\n[Truncated, original: \(text.utf8.count) bytes]"
        var prefix = Array(text.utf8.prefix(max(0, limit - marker.utf8.count)))
        while String(bytes: prefix, encoding: .utf8) == nil {
            prefix.removeLast()
        }
        return (String(bytes: prefix, encoding: .utf8) ?? "") + marker
    }

    var isReceived: Bool {
        source == .received
    }

    var isConnectionEvent: Bool {
        source == .connection
    }

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
        let text = displayJSON(text) ?? text
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

    /// 展示时统一 JSON 格式, 已保存的原文仍用于复制与持久化
    private static func displayJSON(_ text: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

// 窗口只加载已浏览的历史, 新增记录和响应更新按数据库 revision 增量合并
