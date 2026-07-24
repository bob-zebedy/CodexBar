import Foundation

nonisolated enum CodexBarHelperIPC {
    static let helperBundleIdentifierSuffix = ".helper"
    static let machServiceName = bundleIdentifier.hasSuffix(helperBundleIdentifierSuffix)
        ? bundleIdentifier
        : bundleIdentifier + helperBundleIdentifierSuffix
    static let daemonPlistName = machServiceName + ".plist"
    static let watchdogGraceSeconds: TimeInterval = 15
    static let sentinelCheckIntervalSeconds: TimeInterval = 60

    private static let bundleIdentifier: String = {
        guard let identifier = Bundle.main.bundleIdentifier, !identifier.isEmpty else {
            preconditionFailure("CodexBar bundle identifier 缺失")
        }
        return identifier
    }()
}

@objc nonisolated protocol CodexBarHelperProtocol: AnyObject {
    func setSleepDisabled(
        _ disabled: Bool,
        reply: @escaping @Sendable (Int32, Bool) -> Void
    )
}
