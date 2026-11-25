import CoreFoundation
import Foundation

nonisolated struct AppServerRPCError: Error {
    let code: Int?
    let message: String
    let data: Data?
}

/// 账户和活动连接共用这套解码规则, 分别报告 RPC 响应格式错误和 result 内容错误
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

    static func decode<Response: Decodable>(_ object: [String: Any], as _: Response.Type) throws -> Response {
        guard (object["error"] != nil) != (object["result"] != nil) else {
            throw AppServerError.invalidServerResponse
        }
        if let error = object["error"] {
            guard let error = error as? [String: Any], let message = error["message"] as? String else {
                throw AppServerError.invalidServerResponse
            }
            if let code = error["code"] {
                guard let number = code as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), code is Int else {
                    throw AppServerError.invalidServerResponse
                }
            }
            let detail = try error["data"].map {
                try JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes])
            }
            throw AppServerError.serverError(AppServerRPCError(code: error["code"] as? Int, message: message, data: detail))
        }
        do {
            let payload = try JSONSerialization.data(withJSONObject: object["result"]!, options: [.fragmentsAllowed])
            return try JSONDecoder().decode(Response.self, from: payload)
        } catch {
            throw AppServerError.invalidResponsePayload
        }
    }

    static func permitsRetry(_ method: String) -> Bool {
        ["account/read", "account/rateLimits/read", "config/read", "model/list", "configRequirements/read"].contains(method)
    }
}
