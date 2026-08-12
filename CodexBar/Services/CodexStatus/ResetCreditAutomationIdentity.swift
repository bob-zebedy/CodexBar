import CryptoKit
import Foundation

/// 自动使用重置的跨设备身份规则
/// namespace 和 UUIDv5 输入一旦发布就属于兼容性协议
nonisolated enum ResetCreditAutomationIdentity {
    static let namespaceString = "8abd477b-2320-5e39-9518-2a2adfc542fa"

    private static let namespace = UUID(uuidString: namespaceString)!

    static func idempotencyKey(forCreditID creditID: String) -> String {
        var input = uuidData(namespace)
        input.append(contentsOf: creditID.utf8)

        var bytes = Array(Insecure.SHA1.hash(data: input).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return uuid(from: bytes).uuidString.lowercased()
    }

    static func accountIdentity(for account: CodexAccount) -> String {
        let email = account.email?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        return "\(account.type)\u{0}\(email)"
    }

    /// 通知去重键只保留哈希, 不把账号和 creditId 写入 UserDefaults
    static func notificationToken(accountIdentity: String, creditID: String) -> String {
        var input = Data(accountIdentity.utf8)
        input.append(0)
        input.append(contentsOf: creditID.utf8)
        return SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
    }

    private static func uuidData(_ uuid: UUID) -> Data {
        var bytes = uuid.uuid
        return withUnsafeBytes(of: &bytes) { Data($0) }
    }

    private static func uuid(from bytes: [UInt8]) -> UUID {
        precondition(bytes.count == 16)
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
