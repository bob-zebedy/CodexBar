import Foundation

nonisolated struct BridgeCursor: Codable {
    let epoch: UUID
    let task: String
    let turn: String
    var sequence: Int
    var offset: Int = 0

    var encoded: BridgeJSON {
        .string((try? StorageJSON.stableEncoder.encode(self).base64EncodedString()) ?? "")
    }

    var receipt: BridgeJSON {
        ["taskId": .string(task), "turnId": .string(turn), "cursor": encoded]
    }

    static func decode(_ value: String) throws -> Self {
        guard let data = Data(base64Encoded: value), let cursor = try? JSONDecoder().decode(Self.self, from: data),
              cursor.sequence >= 0, cursor.offset >= 0 else { throw BridgeFailure("invalid_cursor") }
        return cursor
    }
}

nonisolated struct BridgeListCursor: Codable {
    let configurationID: UUID
    let project: String?
    let status: String?
    let updated: Date
    let id: String

    private enum CodingKeys: String, CodingKey {
        case configurationID = "owner"
        case project, status, updated, id
    }

    func encoded() throws -> BridgeJSON {
        try .string(JSONEncoder().encode(self).base64EncodedString())
    }

    static func decode(_ value: String) throws -> Self {
        guard let data = Data(base64Encoded: value), let cursor = try? JSONDecoder().decode(Self.self, from: data) else {
            throw BridgeFailure("invalid_cursor")
        }
        return cursor
    }
}

nonisolated struct BridgeTurnEvents {
    static let capacity = 192
    let task: String
    var epoch = UUID()
    var updated = Date()
    nonisolated struct Delta {
        let kind: String
        let item: BridgeJSON
        let text: String
        let since: Date
    }

    nonisolated struct CapturedAnswer: Equatable {
        let isExplicit: Bool
        /// 已选中但超过大小上限的答复仅保留来源, 避免回退到更早的消息
        let text: String?
    }

    var delta: Delta?
    var sequence = 0
    var events: [BridgeJSON] = []
    private(set) var answer: CapturedAnswer?
    private(set) var answerRevision = 0
    var historyUnavailable = false
    var terminalHistoryRead = false
    var needsHistory = true
    var historyScan: BridgeHistoryScan?
    var liveReplies: [String: Set<Int>] = [:]
    var hasDeferredQuestions = false
    var historyRetry: BridgeHistoryRetry?
    var failureMessage: String?

    mutating func captureAnswer(_ item: BridgeJSON, newestFirst: Bool = false) {
        if Self.selectAnswer(item, newestFirst: newestFirst, into: &answer) {
            answerRevision += 1
        }
    }

    @discardableResult
    static func selectAnswer(_ item: BridgeJSON, newestFirst: Bool, into answer: inout CapturedAnswer?) -> Bool {
        guard item["type"] == "agentMessage", item["delivery"] != "async" || item["questions"].elements.isEmpty,
              let text = item["text"].text, !text.isEmpty else { return false }
        let explicit = item["phase"] == "final_answer"
        guard explicit || (item["phase"] == .null && answer?.isExplicit != true),
              !newestFirst || answer?.isExplicit != explicit else { return false }
        answer = CapturedAnswer(isExplicit: explicit, text: text.utf8.count <= 2 * 1024 * 1024 ? text : nil)
        return true
    }

    mutating func finishHistoryAnswer(_ candidate: CapturedAnswer?, since revision: Int) {
        guard let candidate, answer != candidate, candidate.isExplicit || answer?.isExplicit != true,
              answerRevision == revision || (candidate.isExplicit && answer?.isExplicit != true) else { return }
        if answer != nil {
            epoch = UUID()
        }
        answer = candidate
    }

    mutating func append(_ event: BridgeJSON) {
        updated = Date()
        sequence += 1
        events.append(event)
        if events.count > Self.capacity {
            events.removeFirst()
        }
    }

    func page(from cursor: inout BridgeCursor) -> ([BridgeJSON], Bool) {
        let start = sequence - events.count
        let offset = cursor.sequence - start
        guard (0 ... events.count).contains(offset) else { return ([], false) }
        let page = Array(events.dropFirst(offset).prefix(16))
        cursor.sequence += page.count
        return (page, cursor.sequence < sequence)
    }

    func result(from cursor: inout BridgeCursor) -> (BridgeJSON, Bool) {
        guard let finalText = answer?.text else { return (.null, false) }
        let bytes = finalText.utf8
        guard cursor.offset <= bytes.count else { return (.null, false) }
        let start = bytes.index(bytes.startIndex, offsetBy: cursor.offset)
        var end = bytes.index(start, offsetBy: min(16384, bytes.distance(from: start, to: bytes.endIndex)))
        while end < bytes.endIndex, bytes[end] & 0xC0 == 0x80 {
            bytes.formIndex(before: &end)
        }
        guard let section = String(bytes: bytes[start ..< end], encoding: .utf8) else { return (.null, false) }
        cursor.offset += bytes.distance(from: start, to: end)
        return (.string(section), end < bytes.endIndex)
    }
}
