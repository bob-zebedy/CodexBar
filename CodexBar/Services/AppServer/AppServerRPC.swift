import CoreFoundation
import Foundation

nonisolated struct AppServerRPCError: Error {
    let code: Int?
    let message: String
    let data: Data?
}

/// 账户与活动连接使用相同的信封和载荷错误边界
nonisolated enum AppServerRPC {
    static func encode(method: String, id: Int?, params: [String: Any]?) throws -> Data {
        var object: [String: Any] = ["method": method]
        if let id {
            object["id"] = id
        }
        if let params {
            object["params"] = params
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    static func decode<Response: Decodable>(_ data: Data, as _: Response.Type) throws -> Response {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (object["error"] != nil) != (object["result"] != nil) else {
            throw CodexStatusError.invalidServerResponse
        }
        if let error = object["error"] {
            guard let error = error as? [String: Any], let message = error["message"] as? String else {
                throw CodexStatusError.invalidServerResponse
            }
            if let code = error["code"] {
                guard let number = code as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), code is Int else {
                    throw CodexStatusError.invalidServerResponse
                }
            }
            let detail = try error["data"].map {
                try JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes])
            }
            throw CodexStatusError.serverError(AppServerRPCError(code: error["code"] as? Int, message: message, data: detail))
        }
        do {
            let payload = try JSONSerialization.data(withJSONObject: object["result"]!, options: [.fragmentsAllowed])
            return try JSONDecoder().decode(Response.self, from: payload)
        } catch {
            throw CodexStatusError.invalidResponsePayload
        }
    }

    static func permitsRetry(_ method: String) -> Bool {
        ["account/read", "account/rateLimits/read", "config/read", "model/list", "configRequirements/read"].contains(method)
    }
}
