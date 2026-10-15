import Foundation

nonisolated enum PowerHelperManagement {
    static let executableName = "CodexBarPowerHelperManager"
    #if DEBUG
        static let bundleName = "CodexBar Power Helper Debug.app"
        static let bundleIdentifier = "app.zabrian.codexbar.helper.power.manager.debug"
    #else
        static let bundleName = "CodexBar Power Helper.app"
        static let bundleIdentifier = "app.zabrian.codexbar.helper.power.manager"
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
        appURL.appending(path: "Contents/Helpers/\(bundleName)")
    }
}
