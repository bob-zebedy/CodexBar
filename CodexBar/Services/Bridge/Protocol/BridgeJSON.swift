import Foundation

nonisolated enum BridgeJSON: Codable, Hashable, Sendable, ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    case object([String: Self])
    case array([Self])
    case string(String)
    case integer(Int)
    case number(Double)
    case bool(Bool)
    case null

    init(stringLiteral value: String) {
        self = .string(value)
    }

    init(arrayLiteral elements: Self...) {
        self = .array(elements)
    }

    init(dictionaryLiteral elements: (String, Self)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }

    init(from decoder: Decoder) throws {
        let field = try decoder.singleValueContainer()
        if field.decodeNil() {
            self = .null
        } else if let value = try? field.decode(String.self) {
            self = .string(value)
        } else if let value = try? field.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? field.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? field.decode(Double.self) {
            self = .number(value)
        } else if let value = try? field.decode([Self].self) {
            self = .array(value)
        } else {
            self = try .object(field.decode([String: Self].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var field = encoder.singleValueContainer()
        switch self {
        case let .object(value): try field.encode(value)
        case let .array(value): try field.encode(value)
        case let .string(value): try field.encode(value)
        case let .integer(value): try field.encode(value)
        case let .number(value): try field.encode(value)
        case let .bool(value): try field.encode(value)
        case .null: try field.encodeNil()
        }
    }

    var fields: [String: Self]? {
        if case let .object(value) = self {
            value
        } else {
            nil
        }
    }

    var elements: [Self] {
        if case let .array(value) = self {
            value
        } else {
            []
        }
    }

    var text: String? {
        if case let .string(value) = self {
            value
        } else {
            nil
        }
    }

    var int: Int? {
        if case let .integer(value) = self {
            value
        } else {
            nil
        }
    }

    subscript(_ key: String) -> Self {
        fields?[key] ?? .null
    }

    func required(_ key: String, maxBytes: Int = 512) throws -> String {
        guard let value = self[key].text, !value.isEmpty, value.utf8.count <= maxBytes else { throw BridgeFailure("invalid_argument", key) }
        return value
    }

    func data() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    func jsonText() throws -> String {
        guard let value = try String(data: data(), encoding: .utf8) else { throw BridgeFailure("invalid_json") }
        return value
    }

    var rpcID: Self? {
        switch self {
        case .string, .integer: self
        default: nil
        }
    }
}

nonisolated struct BridgeFailure: LocalizedError {
    let code: String
    let detail: String

    init(_ code: String, _ detail: String = "") {
        self.code = code
        self.detail = detail
    }

    var errorDescription: String? {
        detail.isEmpty ? code : "\(code): \(detail)"
    }

    var result: BridgeJSON {
        ["error": .string(code), "message": .string(detail.isEmpty ? code : detail)]
    }
}
