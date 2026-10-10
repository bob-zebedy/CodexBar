import Foundation

/// 方法和参数只在协议入口定义, 调用方通过响应类型约束请求
nonisolated struct AppServerRequest<Response: Decodable> {
    let method: String
    var params: [String: Any]?
}

nonisolated enum AccountRequests {
    static func account(refreshToken: Bool) -> AppServerRequest<AccountReadResponse> {
        AppServerRequest(method: "account/read", params: ["refreshToken": refreshToken])
    }

    static var rateLimits: AppServerRequest<AccountRateLimitsResponse> {
        AppServerRequest(method: "account/rateLimits/read")
    }

    static var usage: AppServerRequest<AccountUsageResponse> {
        AppServerRequest(method: "account/usage/read")
    }

    static var configuration: AppServerRequest<ConfigReadResponse> {
        AppServerRequest(method: "config/read", params: ["includeLayers": false])
    }

    static func consumeCredit(id: String, idempotencyKey: String) -> AppServerRequest<ResetCreditConsumeResponse> {
        AppServerRequest(method: "account/rateLimitResetCredit/consume", params: ["creditId": id, "idempotencyKey": idempotencyKey])
    }

    static func setTUINotifications(_ enabled: Bool) -> AppServerRequest<ConfigWriteResponse> {
        let edit = ConfigBatchEdit(keyPath: "tui.notifications", value: enabled, mergeStrategy: "upsert")
        return AppServerRequest(method: "config/batchWrite", params: ["edits": [edit.appServerObject], "reloadUserConfig": true])
    }
}

nonisolated enum ActivityRequests {
    static func loadedThreads(cursor: String?) -> AppServerRequest<ActivityLoadedPage> {
        var params: [String: Any] = ["limit": 100]
        if let cursor {
            params["cursor"] = cursor
        }
        return AppServerRequest(method: "thread/loaded/list", params: params)
    }

    static func thread(_ id: String) -> AppServerRequest<ActivityThreadRead> {
        AppServerRequest(method: "thread/read", params: ["threadId": id, "includeTurns": false])
    }

    static func subscribe(_ id: String) -> AppServerRequest<ActivityThreadResume> {
        AppServerRequest(method: "thread/resume", params: ["threadId": id, "excludeTurns": true])
    }

    static func turns(_ id: String, limit: Int, includesItems: Bool, cursor: String? = nil) -> AppServerRequest<ActivityTurnsPage> {
        var params: [String: Any] = ["threadId": id, "limit": limit, "itemsView": includesItems ? "full" : "notLoaded"]
        if let cursor {
            params["cursor"] = cursor
        }
        return AppServerRequest(method: "thread/turns/list", params: params)
    }
}
