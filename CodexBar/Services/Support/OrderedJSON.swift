import Foundation

/// 写入 JSONL 时固定字段顺序, 便于人工排查和 diff
nonisolated enum OrderedJSON {
    static func lineData(_ fields: [String]) -> Data {
        let json = "{\(fields.joined(separator: ","))}"
        return Data(json.utf8) + Data([0x0A])
    }

    static func field(_ name: String, _ value: (some Encodable)?) throws -> String {
        try "\"\(name)\":\(Self.value(value))"
    }

    static func value(_ value: (some Encodable)?) throws -> String {
        guard let value else {
            return "null"
        }

        return try Self.value(value)
    }

    static func value(_ value: some Encodable) throws -> String {
        let data = try JSONLines.stableEncoder.encode(value)
        guard let text = String(bytes: data, encoding: .utf8) else {
            throw EncodingError.invalidValue(
                value,
                .init(codingPath: [], debugDescription: "Encoded history JSON was not UTF-8")
            )
        }
        return text
    }

    static func presentCountFields(_ values: [(String, Int?)]) throws -> [String] {
        try values.compactMap { name, value in
            guard let value else {
                return nil
            }
            return try field(name, value)
        }
    }
}
