import Foundation

nonisolated struct BridgeAsyncQuestions {
    typealias Question = BridgeQuestionForm.Question
    static let maximumBytes = 32 * 1024
    let itemID: String
    let questions: [Question]

    init?(_ item: BridgeJSON) {
        let input = item["questions"]
        guard item["type"] == "agentMessage", item["delivery"] == "async",
              let id = try? item.required("id"), !input.elements.isEmpty,
              let size = try? input.data().count, size <= Self.maximumBytes else { return nil }
        var questions: [Question] = []
        for (index, value) in input.elements.enumerated() {
            guard value["isSecret"] != .bool(true), let title = try? value.required("title", maxBytes: 8192) else { return nil }
            var options: [String] = []
            if value["options"] != .null {
                guard case let .array(choices) = value["options"] else { return nil }
                var seen = Set<String>()
                for choice in choices {
                    guard let label = choice.text, !label.isEmpty else { return nil }
                    if seen.insert(label).inserted {
                        options.append(label)
                    }
                }
            }
            questions.append(Question(key: "q\(index + 1)", title: title, options: options, allowsOther: true))
        }
        itemID = id
        self.questions = questions
    }

    static func replyIndices(in item: BridgeJSON) -> [String: Set<Int>] {
        guard item["type"] == "userMessage", let data = try? item.data(),
              let decoded = try? JSONDecoder().decode(ActivityItem.self, from: data), let replies = decoded.questionReplies else { return [:] }
        // 正文有大小上限, 超出该范围的序号不可能属于有效表单
        return Dictionary(grouping: replies, by: \.itemID).mapValues { group in
            Set(group.lazy.map(\.index).filter { $0 < maximumBytes })
        }
    }

    func isAnswered(by indices: Set<Int>?) -> Bool {
        guard let indices else { return false }
        return questions.indices.allSatisfy(indices.contains)
    }

    var summary: String {
        questions.map(\.title).joined(separator: "\n")
    }

    var schema: BridgeJSON {
        BridgeQuestionForm(questions).schema
    }

    func reply(_ response: BridgeJSON) throws -> String? {
        switch response["action"] {
        case "decline", "cancel": return nil
        case "accept": break
        default: throw BridgeFailure("invalid_form_response")
        }
        let content = response["content"]
        let form = BridgeQuestionForm(questions)
        let answers: [BridgeJSON] = try questions.enumerated().map { index, question in
            let answer = try form.answer(question, in: content)
            // Codex 客户端用工具名, 消息 ID 和问题序号关联异步答复
            let key: BridgeJSON = ["request_user_input_async", .string(itemID), .integer(index)]
            return try ["questionItemId": .string(key.jsonText()), "question": .string(question.title), "answer": .string(answer)]
        }
        let payload = try BridgeJSON.array(answers).jsonText().replacingOccurrences(of: "<", with: #"\u003c"#)
        return "<send_user_message_question_reply>\n" + payload + "\n</send_user_message_question_reply>\n"
    }
}
