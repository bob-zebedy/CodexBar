import Foundation
import Testing

struct AppServerRPCTests {
    @Test(arguments: [-32601, -32602, -32600, -32700])
    func rpcCodesWorkWithoutEnglishErrorMessages(_ code: Int) throws {
        let response: [String: Any] = ["id": 1, "error": ["code": code, "message": "本地化错误", "data": ["field": "test"]]]
        do {
            let _: [String: Int] = try AppServerRPC.decode(response, as: [String: Int].self)
            Issue.record("Expected RPC error")
        } catch let error as AppServerError {
            guard case let .serverError(detail) = error else { Issue.record("Lost RPC error")
                return
            }
            #expect(detail.code == code)
            #expect(detail.message == "本地化错误")
            let value = try JSONSerialization.jsonObject(with: #require(detail.data)) as? [String: String]
            #expect(value == ["field": "test"])
            #expect(!error.isRetriableServerError)
            #expect(code == -32601 ? error.isUnsupportedMethod : error.isProtocolOrParameterFailure)
        }
        #expect(!AppServerRPC.permitsRetry("config/value/write"))
    }

    @Test func missingRolloutClassificationRequiresExactThreadAndError() {
        let missing = AppServerError.serverError(AppServerRPCError(
            code: -32600, message: "no rollout found for thread id thread-a", data: nil
        ))
        #expect(missing.isThreadUnavailable(for: "thread-a"))
        #expect(!missing.isThreadUnavailable(for: "thread-b"))
        #expect(missing.isProtocolOrParameterFailure)
        for code in [-32700, -32602, -32603] {
            let error = AppServerError.serverError(AppServerRPCError(
                code: code, message: "no rollout found for thread id thread-a", data: nil
            ))
            #expect(!error.isThreadUnavailable(for: "thread-a"))
        }
        let invalid = AppServerError.serverError(AppServerRPCError(code: -32600, message: "invalid request", data: nil))
        #expect(!invalid.isThreadUnavailable(for: "thread-a"))
        #expect(invalid.isProtocolOrParameterFailure)
        #expect(!AppServerError.serverConnectionClosed.isThreadUnavailable(for: "thread-a"))
        #expect(!AppServerError.invalidResponsePayload.isThreadUnavailable(for: "thread-a"))
    }

    @Test(arguments: ["modelProviderMismatch", "modelProviderNotConfigured", "modelProviderPolicyConflict"])
    func providerErrorsAreThreadLocalWithoutChangingSharedRetryPolicy(type: String) throws {
        let response: [String: Any] = ["id": 1, "error": [
            "code": -32600, "message": "本地化业务错误", "data": [
                "type": type, "modelProvider": "saved", "currentModelProvider": "current", "requiredModelProvider": "required"
            ]
        ]]
        do {
            let _: [String: Int] = try AppServerRPC.decode(response, as: [String: Int].self)
            Issue.record("Expected provider error")
        } catch let error as AppServerError {
            #expect(error.isThreadUnavailable(for: "thread-a"))
            #expect(!error.isTransportFailure)
            #expect(error.isProtocolOrParameterFailure)
            #expect(!error.isRetriableServerError)
        }
    }

    @Test(arguments: [
        nil, "null", "{}", "[]", "{", #""modelProviderMismatch""#,
        #"{"type":null}"#, #"{"type":1}"#, #"{"type":"futureProviderError"}"#, #"{"type":"ModelProviderMismatch"}"#
    ] as [String?])
    func unknownOrMalformedThreadErrorsKeepTheirFallback(detail: String?) {
        let error = AppServerError.serverError(AppServerRPCError(
            code: -32600, message: "modelProviderMismatch", data: detail.map { Data($0.utf8) }
        ))
        #expect(!error.isThreadUnavailable(for: "thread-a"))
        #expect(error.isProtocolOrParameterFailure)
        #expect(!error.isRetriableServerError)
    }

    @Test(arguments: [nil, -32700, -32602, -32601, -32603, 0] as [Int?])
    func providerErrorTypeRequiresMatchingRPCCode(code: Int?) {
        let error = AppServerError.serverError(AppServerRPCError(
            code: code, message: "本地化业务错误", data: Data(#"{"type":"modelProviderMismatch"}"#.utf8)
        ))
        #expect(!error.isThreadUnavailable(for: "thread-a"))
    }

    @Test func rpcMalformedEnvelopeAndPayloadHaveDifferentBoundaries() {
        #expect(throws: AppServerError.self) {
            let _: Int = try AppServerRPC.decode(["error": [:], "result": 3], as: Int.self)
        }
        do {
            let _: Int = try AppServerRPC.decode(["result": "wrong"], as: Int.self)
            Issue.record("Expected invalid response payload")
        } catch let error as AppServerError {
            #expect(!error.isTransportFailure)
        } catch { Issue.record(error) }
    }
}
