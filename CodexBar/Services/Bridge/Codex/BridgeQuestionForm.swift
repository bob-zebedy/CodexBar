import Foundation

nonisolated struct BridgeQuestionForm {
    struct Question {
        let key: String
        let title: String
        let options: [String]
        let allowsOther: Bool
    }

    let questions: [Question]
    private let customKeys: [String: String]

    init(_ questions: [Question]) {
        self.questions = questions
        var taken = Set(questions.map(\.key))
        var custom: [String: String] = [:]
        for question in questions where question.allowsOther && !question.options.isEmpty {
            var key = question.key + "_other"
            while !taken.insert(key).inserted {
                key += "_other"
            }
            custom[question.key] = key
        }
        customKeys = custom
    }

    func answer(_ question: Question, in content: BridgeJSON) throws -> String {
        if let key = customKeys[question.key], let custom = content[key].text, !custom.isEmpty {
            return try content.required(key, maxBytes: 8192)
        }
        let answer = try content.required(question.key, maxBytes: 8192)
        guard question.options.isEmpty || question.options.contains(answer) else { throw BridgeFailure("invalid_form_response") }
        return answer
    }

    var schema: BridgeJSON {
        var fields: [String: BridgeJSON] = [:]
        var required: [BridgeJSON] = []
        for question in questions {
            var field: [String: BridgeJSON] = ["type": "string", "title": .string(questions.count == 1 ? "" : question.title)]
            if question.options.isEmpty || !question.allowsOther {
                required.append(.string(question.key))
            }
            if !question.options.isEmpty {
                field["enum"] = .array(question.options.map(BridgeJSON.string))
                if let other = customKeys[question.key] {
                    fields[other] = ["type": "string", "title": ""]
                }
            }
            fields[question.key] = .object(field)
        }
        return ["type": "object", "properties": .object(fields), "required": .array(required)]
    }
}
