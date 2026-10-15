import Foundation
import Testing

struct AppServerRPCTests {
    @Test(arguments: [-32601, -32602, -32600, -32700])
    func rpcCodesWorkWithoutEnglishErrorMessages(_ code: Int) throws {
        let data = try JSONSerialization.data(withJSONObject: ["id": 1, "error": ["code": code, "message": "本地化错误", "data": ["field": "test"]]])
        do {
            let _: [String: Int] = try AppServerRPC.decode(data, as: [String: Int].self)
            Issue.record("Expected RPC error")
        } catch let error as CodexStatusError {
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
        let missing = CodexStatusError.serverError(AppServerRPCError(
            code: -32600, message: "no rollout found for thread id thread-a", data: nil
        ))
        #expect(missing.isMissingRollout(for: "thread-a"))
        #expect(!missing.isMissingRollout(for: "thread-b"))
        #expect(missing.isProtocolOrParameterFailure)
        for code in [-32700, -32602, -32603] {
            let error = CodexStatusError.serverError(AppServerRPCError(
                code: code, message: "no rollout found for thread id thread-a", data: nil
            ))
            #expect(!error.isMissingRollout(for: "thread-a"))
        }
        let invalid = CodexStatusError.serverError(AppServerRPCError(code: -32600, message: "invalid request", data: nil))
        #expect(!invalid.isMissingRollout(for: "thread-a"))
        #expect(invalid.isProtocolOrParameterFailure)
        #expect(!CodexStatusError.serverConnectionClosed.isMissingRollout(for: "thread-a"))
        #expect(!CodexStatusError.invalidResponsePayload.isMissingRollout(for: "thread-a"))
    }

    @Test func rpcMalformedEnvelopeAndPayloadHaveDifferentBoundaries() {
        #expect(throws: CodexStatusError.self) {
            let _: Int = try AppServerRPC.decode(Data(#"{"error":{},"result":3}"#.utf8), as: Int.self)
        }
        do {
            let _: Int = try AppServerRPC.decode(Data(#"{"result":"wrong"}"#.utf8), as: Int.self)
        } catch let error as CodexStatusError {
            #expect(!error.isTransportFailure)
        } catch { Issue.record(error) }
    }
}
