import CryptoKit
import Foundation
import ServiceManagement

@MainActor
enum KeepAliveHelperConfiguration {
    static let registrationRetryDelays: [Duration] = [
        .milliseconds(500),
        .seconds(1),
        .seconds(2)
    ]
    static let updateCompletionRetryDelays: [Duration] = [
        .zero,
        .milliseconds(250),
        .milliseconds(500),
        .seconds(1),
        .seconds(2)
    ]
    static let requestTimeout = Duration.seconds(
        CodexBarHelperIPC.requestTimeoutSeconds
    )
    static let externalObservationInterval = Duration.seconds(
        CodexBarHelperIPC.externalCheckIntervalSeconds
    )
    static let sleepToggleRetryDelays: [Duration] = [
        .seconds(2),
        .seconds(4),
        .seconds(8),
        .seconds(16),
        .seconds(32),
        .seconds(64),
        .seconds(128),
        .seconds(256)
    ]
    static let wakeScheduleRetryDelays: [Duration] = [
        .seconds(2),
        .seconds(4),
        .seconds(8),
        .seconds(16),
        .seconds(32),
        .seconds(64)
    ]
    static let wakeCancellationRetryDelays: [Duration] = [
        .zero,
        .milliseconds(250),
        .seconds(1)
    ]

    static var service: SMAppService {
        SMAppService.daemon(plistName: CodexBarHelperIPC.daemonPlistName)
    }

    static var assetsArePresent: Bool {
        FileManager.default.fileExists(atPath: daemonPlistURL.path)
            && FileManager.default.isExecutableFile(atPath: helperExecutableURL.path)
    }

    static func registrationNeedsRefresh(defaults: UserDefaults) -> Bool {
        guard let fingerprint else {
            return false
        }
        return defaults.string(forKey: registrationFingerprintKey) != fingerprint
    }

    static func beginUpdate(
        defaults: UserDefaults,
        requiresSleepReset: Bool
    ) -> String? {
        guard let fingerprint else {
            return nil
        }
        // 待完成重置是跨 Helper 版本的欠账, 后续更新只能转交给新指纹, 不能清除
        let hasPendingSleepReset = defaults.string(forKey: pendingUpdateIdentifierKey) != nil
        if requiresSleepReset || hasPendingSleepReset {
            defaults.set(fingerprint, forKey: pendingUpdateIdentifierKey)
        } else {
            defaults.removeObject(forKey: pendingUpdateIdentifierKey)
        }
        return fingerprint
    }

    static func pendingUpdateIdentifier(defaults: UserDefaults) -> String? {
        guard let fingerprint,
              defaults.string(forKey: registrationFingerprintKey) == fingerprint,
              defaults.string(forKey: pendingUpdateIdentifierKey) == fingerprint else {
            return nil
        }
        return fingerprint
    }

    static func completeUpdate(
        _ updateIdentifier: String,
        defaults: UserDefaults
    ) {
        guard defaults.string(forKey: pendingUpdateIdentifierKey) == updateIdentifier else {
            return
        }
        defaults.removeObject(forKey: pendingUpdateIdentifierKey)
    }

    static func recordRegistration(
        defaults: UserDefaults,
        status: KeepAliveController.HelperStatus
    ) {
        guard status.isRegisteredOrAwaitingApproval, let fingerprint else {
            return
        }
        defaults.set(fingerprint, forKey: registrationFingerprintKey)
    }

    static func isTransientRegistrationError(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == SMAppServiceErrorDomain
            && error.code == operationNotPermittedErrorCode
    }

    private static let registrationFingerprintKey = "KeepAlive.helperRegistrationFingerprint"
    private static let pendingUpdateIdentifierKey = "KeepAlive.pendingHelperUpdateIdentifier"
    private static let operationNotPermittedErrorCode = 1

    private static var fingerprint: String? {
        guard let helperData = try? Data(contentsOf: helperExecutableURL, options: .mappedIfSafe),
              let daemonPlistData = try? Data(contentsOf: daemonPlistURL, options: .mappedIfSafe) else {
            return nil
        }

        var hasher = SHA256()
        for (name, data) in [
            (helperExecutableURL.lastPathComponent, helperData),
            (daemonPlistURL.lastPathComponent, daemonPlistData)
        ] {
            hasher.update(data: Data("\(name)\n\(data.count)\n".utf8))
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static var appContentsURL: URL {
        Bundle.main.bundleURL.appending(path: "Contents", directoryHint: .isDirectory)
    }

    private static var helperExecutableURL: URL {
        appContentsURL
            .appending(path: "Resources", directoryHint: .isDirectory)
            .appending(path: "CodexBarHelper")
    }

    private static var daemonPlistURL: URL {
        appContentsURL
            .appending(path: "Library/LaunchDaemons", directoryHint: .isDirectory)
            .appending(path: CodexBarHelperIPC.daemonPlistName)
    }
}
