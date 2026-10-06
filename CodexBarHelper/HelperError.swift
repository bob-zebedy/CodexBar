import Foundation

enum HelperError: LocalizedError {
    case insecureOwnershipDirectory(String)
    case invalidOwnershipRecord(String)
    case ownershipWriteFailed(operation: String, code: Int32)
    case codeSigningValidationFailed(String)

    var errorDescription: String? {
        switch self {
        case let .insecureOwnershipDirectory(detail):
            "睡眠设置目录无效: \(detail)"
        case let .invalidOwnershipRecord(detail):
            "睡眠所有权记录无效: \(detail)"
        case let .ownershipWriteFailed(operation, code):
            "睡眠所有权记录写入失败: operation=\(operation); errno=\(code)"
        case let .codeSigningValidationFailed(reason):
            "签名校验失败: \(reason)"
        }
    }
}
