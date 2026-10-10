import Foundation

nonisolated enum HelperManagement {
    static let executableName = "CodexBarHelperManager"
    #if DEBUG
        static let bundleName = "CodexBar Helper Debug.app"
        static let bundleIdentifier = "app.zabrian.codexbar.helper-manager.debug"
    #else
        static let bundleName = "CodexBar Helper.app"
        static let bundleIdentifier = "app.zabrian.codexbar.helper-manager"
    #endif

    enum Command: String, Sendable {
        case status
        case register
        case unregister
    }

    struct Reply: Codable, Sendable {
        let status: Int
        let errorDomain: String?
        let errorCode: Int?
    }

    static func bundleURL(in appURL: URL) -> URL {
        appURL.appending(path: "Contents/Library/LoginItems/\(bundleName)")
    }
}
