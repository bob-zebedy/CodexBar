import Foundation

nonisolated struct BridgePendingRequest {
    enum Source {
        case rpc(BridgeRPCRequest)
        case message(BridgeAsyncQuestions, origin: String)
    }

    let id: String
    let source: Source
    let task: String
    var turn: String
    var submissionUncertain = false
    var answered = Set<Int>()

    var messageID: String? {
        guard case let .message(questions, _) = source else { return nil }
        return questions.itemID
    }

    var isMessageQuestion: Bool {
        messageID != nil
    }

    func disallowsApproval(under permissions: BridgePermissions) -> Bool {
        guard case let .rpc(rpc) = source, rpc.method.isApproval else { return false }
        return !rpc.isPermitted(by: permissions)
    }

    var blocking: Bool {
        if case let .rpc(request) = source {
            return request.params["isBlocking"] != .bool(false)
        }
        return false
    }

    private var content: String {
        switch source {
        case let .rpc(request): request.summary
        case let .message(questions, _): questions.summary
        }
    }

    var info: BridgeJSON {
        let kind: BridgeJSON = switch source {
        case let .rpc(request) where request.method.isApproval: "approval"
        default: "input"
        }
        var fields: [String: BridgeJSON] = ["requestId": .string(id), "kind": kind, "summary": .string(String(content.prefix(2048)))]
        if submissionUncertain {
            fields["status"] = "outcome_unknown"
        }
        return .object(fields)
    }

    func form(approvalOptions: BridgeApprovalOptions = .init()) -> BridgeJSON? {
        let schema: BridgeJSON
        let multipleQuestions: Bool
        switch source {
        case let .rpc(request):
            guard let form = request.form else { return nil }
            schema = switch form {
            case let .approval(scope): approvalOptions.schema(for: scope)
            case let .input(fields): fields
            }
            multipleQuestions = request.method == .userInput && request.params["questions"].elements.count > 1
        case let .message(questions, _):
            schema = questions.schema
            multipleQuestions = questions.questions.count > 1
        }
        // 多题表单的题目已分别显示在对应的输入框上方
        return ["message": .string(multipleQuestions ? "" : content), "requestedSchema": schema]
    }
}

nonisolated struct BridgePendingRequests {
    private static let limit = 64
    private var open: [String: BridgePendingRequest] = [:]
    private var files: [BridgeTurnKey: [String: [String]]] = [:]

    var hasQuestionCapacity: Bool {
        open.values.lazy.filter(\.isMessageQuestion).count < Self.limit
    }

    func needsFastPolling(activeTasks: [String: BridgeTaskRecord]) -> Bool {
        open.values.contains { !$0.isMessageQuestion || activeTasks[$0.task]?.latestTurnID == $0.turn }
    }

    var blockingTurns: Set<BridgeTurnKey> {
        Set(open.values.filter(\.blocking).map { BridgeTurnKey(task: $0.task, turn: $0.turn) })
    }

    func hasPending(in key: BridgeTurnKey) -> Bool {
        open.values.contains { $0.task == key.task && $0.turn == key.turn && !$0.submissionUncertain }
    }

    func forTurn(_ key: BridgeTurnKey) -> [BridgePendingRequest] {
        open.values.filter { $0.task == key.task && $0.turn == key.turn }.sorted { $0.id < $1.id }
    }

    func pending(task: String, id: String) throws -> BridgePendingRequest {
        guard let request = open[id], request.task == task else { throw BridgeFailure("request_closed") }
        return request
    }

    mutating func insert(_ request: BridgePendingRequest) -> Bool {
        let sameKind = open.values.filter { $0.isMessageQuestion == request.isMessageQuestion }
        guard sameKind.count < Self.limit else { return false }
        open[request.id] = request
        return true
    }

    mutating func includeAnswers(_ indices: Set<Int>, for id: String) -> Set<Int> {
        open[id]?.answered.formUnion(indices)
        return open[id]?.answered ?? indices
    }

    mutating func markSubmissionUncertain(_ id: String) {
        open[id]?.submissionUncertain = true
    }

    mutating func close(_ id: String) {
        open[id] = nil
    }

    func question(task: String, item: String) -> BridgePendingRequest? {
        open.values.first { $0.task == task && $0.messageID == item }
    }

    mutating func resolveRPC(task: String, id: BridgeJSON) -> BridgePendingRequest? {
        guard let match = open.values.first(where: {
            guard case let .rpc(rpc) = $0.source else { return false }
            return $0.task == task && rpc.id == id
        }) else { return nil }
        return open.removeValue(forKey: match.id)
    }

    mutating func moveQuestions(task: String, from: String, to: String) {
        for request in open.values where request.task == task && request.turn == from && request.isMessageQuestion {
            open[request.id]?.turn = to
        }
    }

    mutating func discardQuestionsOutsideLatestTurn(task: String, turn: String?) {
        open = open.filter { _, request in request.task != task || request.turn == turn || !request.isMessageQuestion }
    }

    mutating func endTurn(_ key: BridgeTurnKey, status: BridgeTurnStatus) {
        files[key] = nil
        open = open.filter { _, request in
            request.task != key.task || request.turn != key.turn || (request.isMessageQuestion && status == .completed)
        }
    }

    mutating func disconnect() {
        open.removeAll()
        files.removeAll()
    }

    func disallowedApprovals(in tasks: Set<String>, permissions: BridgePermissions) -> [BridgePendingRequest] {
        open.values.filter { tasks.contains($0.task) && $0.disallowsApproval(under: permissions) }
    }

    mutating func removeRequests(for tasks: Set<String>) -> [BridgePendingRequest] {
        let declined = open.values.filter { tasks.contains($0.task) && !$0.isMessageQuestion }
        open = open.filter { !tasks.contains($0.value.task) }
        files = files.filter { !tasks.contains($0.key.task) }
        return declined
    }

    mutating func recordFiles(_ paths: [String]?, item: String, in key: BridgeTurnKey) {
        if let paths {
            guard files[key] != nil || files.count < Self.limit,
                  files[key]?[item] != nil || (files[key]?.count ?? 0) < 8 else { return }
            files[key, default: [:]][item] = paths
        } else {
            files[key]?[item] = nil
            if files[key]?.isEmpty == true {
                files[key] = nil
            }
        }
    }

    func changedPaths(item: String?, in key: BridgeTurnKey) -> [String]? {
        item.flatMap { files[key]?[$0] }
    }
}
