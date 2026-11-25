import Foundation

/// 仅替换对话正文的字符串区间, 保留命令输出, 未知字段及数字的原始表示
nonisolated enum BridgeLogPayload {
    static let characterLimit = AppServerLogEntry.summaryPreviewLength

    static func text(_ data: Data, method: String) -> String {
        func original() -> String {
            String(data: data, encoding: .utf8) ?? ""
        }
        guard data.count > characterLimit else { return original() }
        var edits = Edits()
        switch method {
        case "turn/start", "turn/steer":
            let root = Value(data).fields
            edits.input(root["params"]?.fields["input"])
            edits.turn(root["result"]?.fields["turn"])
        case "thread/start", "thread/resume", "thread/started":
            let root = Value(data).fields
            edits.thread((root["result"] ?? root["params"])?.fields["thread"])
        case "turn/started", "turn/completed":
            edits.turn(Value(data).fields["params"]?.fields["turn"])
        case "thread/turns/list":
            for turn in Value(data).fields["result"]?.fields["data"]?.elements ?? [] {
                edits.turn(turn)
            }
        case "thread/items/list":
            for entry in Value(data).fields["result"]?.fields["data"]?.elements ?? [] {
                edits.item(entry.fields["item"] ?? entry)
            }
        case "item/started", "item/completed", "rawResponseItem/completed":
            edits.item(Value(data).fields["params"]?.fields["item"])
        case "item/tool/requestUserInput":
            let root = Value(data).fields
            for question in root["params"]?.fields["questions"]?.elements ?? [] {
                edits.shorten(question.fields["question"])
            }
            for answer in root["result"]?.fields["answers"]?.fields.values ?? [:].values {
                for text in answer.fields["answers"]?.elements ?? [] {
                    edits.shorten(text)
                }
            }
        case "mcpServer/elicitation/request":
            if let content = Value(data).fields["result"]?.fields["content"] {
                for answer in content.fields.values {
                    edits.shorten(answer)
                    for value in answer.elements {
                        edits.shorten(value)
                    }
                }
            }
        default: return original()
        }
        return edits.apply(to: data)
    }

    private struct Item: Hashable {
        let thread: String
        let turn: String
        let id: String
    }

    struct Stream {
        private var remaining: [Item: Int] = [:]

        mutating func text(_ data: Data, method: String, params: [String: Any]?) -> String {
            guard let thread = params?["threadId"] as? String else { return BridgeLogPayload.text(data, method: method) }
            if method == "turn/completed", let turn = (params?["turn"] as? [String: Any])?["id"] as? String {
                remaining = remaining.filter { $0.key.thread != thread || $0.key.turn != turn }
            } else if let turn = params?["turnId"] as? String {
                if method == "item/completed", let id = (params?["item"] as? [String: Any])?["id"] as? String {
                    remaining.removeValue(forKey: Item(thread: thread, turn: turn, id: id))
                } else if method == "item/agentMessage/delta", let id = params?["itemId"] as? String, let delta = params?["delta"] as? String {
                    let key = Item(thread: thread, turn: turn, id: id)
                    let available = remaining[key] ?? (remaining.count < 512 ? characterLimit : 0)
                    let prefix = delta.prefix(available)
                    if remaining[key] != nil || remaining.count < 512 {
                        remaining[key] = available - prefix.count
                    }
                    guard prefix.endIndex != delta.endIndex else { return String(data: data, encoding: .utf8) ?? "" }
                    var edits = Edits()
                    edits.shorten(Value(data).fields["params"]?.fields["delta"], limit: available)
                    return edits.apply(to: data)
                }
            }
            return BridgeLogPayload.text(data, method: method)
        }
    }

    private struct Edits {
        var replacements: [(Range<Int>, Data)] = []

        func apply(to data: Data) -> String {
            guard !replacements.isEmpty else { return String(data: data, encoding: .utf8) ?? "" }
            var result = Data()
            var start = data.startIndex
            for (range, replacement) in replacements.sorted(by: { $0.0.lowerBound < $1.0.lowerBound }) {
                result.append(data[start ..< data.startIndex + range.lowerBound])
                result.append(replacement)
                start = data.startIndex + range.upperBound
            }
            result.append(data[start...])
            return String(data: result, encoding: .utf8) ?? ""
        }

        mutating func shorten(_ value: Value?, limit: Int = characterLimit) {
            guard let value, value.bytes.count > limit + 2, let text = value.string else { return }
            let prefix = text.prefix(limit)
            guard prefix.endIndex != text.endIndex else { return }
            let encoder = JSONEncoder()
            encoder.outputFormatting = .withoutEscapingSlashes
            if let replacement = try? encoder.encode(String(prefix) + "…") {
                replacements.append((value.bytes.indices, replacement))
            }
        }

        mutating func input(_ content: Value?) {
            for part in content?.elements ?? [] {
                let fields = part.fields
                if fields["type"]?.string == "text" {
                    shorten(fields["text"])
                }
            }
        }

        mutating func thread(_ thread: Value?) {
            guard let fields = thread?.fields else { return }
            shorten(fields["preview"])
            for entry in fields["turns"]?.elements ?? [] {
                turn(entry)
            }
        }

        mutating func turn(_ turn: Value?) {
            for entry in turn?.fields["items"]?.elements ?? [] {
                item(entry)
            }
        }

        mutating func item(_ item: Value?) {
            guard let fields = item?.fields else { return }
            switch fields["type"]?.string {
            case "userMessage": input(fields["content"])
            case "agentMessage":
                shorten(fields["text"])
                for question in fields["questions"]?.elements ?? [] {
                    shorten(question.fields["title"])
                }
            case "agent_message", "message":
                guard fields["type"]?.string == "agent_message" || ["assistant", "user"].contains(fields["role"]?.string ?? "") else { return }
                for part in fields["content"]?.elements ?? [] {
                    let content = part.fields
                    if ["input_text", "output_text"].contains(content["type"]?.string ?? "") {
                        shorten(content["text"])
                    }
                }
            default: break
            }
        }
    }

    /// 在已经过协议层解析的 JSON 中定位值, 只有选中的字符串需要解码和重新编码
    private struct Value {
        let bytes: ArraySlice<UInt8>

        init(_ data: Data) {
            bytes = Array(data)[...].drop(while: Self.whitespace)
        }

        init(bytes: ArraySlice<UInt8>) {
            self.bytes = bytes
        }

        var string: String? {
            guard bytes.first == 34, bytes.last == 34 else { return nil }
            let content = bytes.dropFirst().dropLast()
            if content.contains(92) {
                return try? JSONDecoder().decode(String.self, from: Data(bytes))
            }
            return String(bytes: content, encoding: .utf8)
        }

        var fields: [String: Value] {
            guard bytes.first == 123 else { return [:] }
            var fields: [String: Value] = [:]
            var rest = bytes.dropFirst()
            while let key = Self.take(from: &rest)?.string, let value = Self.take(from: &rest) {
                fields[key] = value
            }
            return fields
        }

        var elements: [Value] {
            guard bytes.first == 91 else { return [] }
            var elements: [Value] = []
            var rest = bytes.dropFirst()
            while let value = Self.take(from: &rest) {
                elements.append(value)
            }
            return elements
        }

        static func whitespace(_ byte: UInt8) -> Bool {
            byte == 32 || byte == 9 || byte == 10 || byte == 13
        }

        private static func take(from rest: inout ArraySlice<UInt8>) -> Value? {
            rest = rest.drop { whitespace($0) || $0 == 58 || $0 == 44 }
            guard let first = rest.first, first != 125, first != 93 else { return nil }
            var end = rest.startIndex
            var depth = 0
            repeat {
                let byte = rest[end]
                end += 1
                switch byte {
                case 34:
                    while end < rest.endIndex {
                        let character = rest[end]
                        end += 1
                        if character == 34 {
                            break
                        }
                        if character == 92, end < rest.endIndex {
                            end += 1
                        }
                    }
                case 123, 91: depth += 1
                case 125, 93: depth -= 1
                default:
                    if depth == 0 {
                        while end < rest.endIndex, !whitespace(rest[end]), ![44, 93, 125].contains(rest[end]) {
                            end += 1
                        }
                    }
                }
            } while depth > 0 && end < rest.endIndex
            let value = Value(bytes: rest[..<end])
            rest = rest[end...]
            return value
        }
    }
}
