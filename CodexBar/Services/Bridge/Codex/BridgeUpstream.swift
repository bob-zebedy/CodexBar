import Foundation

nonisolated protocol BridgeUpstream: AnyObject {
    func call(_ method: String, _ params: BridgeJSON) throws -> BridgeJSON
    func next() throws -> BridgeJSON?
    func answer(_ method: BridgeRPCRequest.Method, id: BridgeJSON, result: BridgeJSON) throws
    func reject(_ method: String, id: BridgeJSON) throws
    func close()
}

final nonisolated class BridgeControlConnection: BridgeUpstream {
    static let connectionName = "bridge"
    static let maximumMessageSize = 8 * 1024 * 1024
    private let session: AppServerSession

    init(socket: URL, logs: AppServerLogStore = .shared) throws {
        session = try AppServerSession(socketURL: socket, logStorage: logs, connectionName: Self.connectionName, maximumMessageSize: Self.maximumMessageSize)
        try session.initialize(clientName: "codexbar_bridge", minimumVersion: CodexVersionReader.minimumAppServerVersion, experimentalAPI: true)
    }

    func call(_ method: String, _ params: BridgeJSON) throws -> BridgeJSON {
        let object = try JSONSerialization.jsonObject(with: params.data()) as? [String: Any] ?? [:]
        return try session.request(method, params: object)
    }

    func next() throws -> BridgeJSON? {
        guard let data = try session.nextEvent() else { return nil }
        return try JSONDecoder().decode(BridgeJSON.self, from: data)
    }

    func answer(_ method: BridgeRPCRequest.Method, id: BridgeJSON, result: BridgeJSON) throws {
        try session.sendMessage(BridgeJSON.object(["id": id, "result": result]).data(), method: method.rawValue)
    }

    func reject(_ method: String, id: BridgeJSON) throws {
        let response: BridgeJSON = ["id": id, "error": ["code": .integer(-32601), "message": "Unsupported Bridge request"]]
        try session.sendMessage(response.data(), method: method)
    }

    func close() {
        session.close()
    }
}
