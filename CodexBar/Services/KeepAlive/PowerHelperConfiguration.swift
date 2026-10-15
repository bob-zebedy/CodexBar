import Combine
import CryptoKit
import Foundation
import Security
import ServiceManagement

@MainActor
enum PowerHelperConfiguration {
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
        CodexBarPowerHelperIPC.requestTimeoutSeconds
    )
    static let externalObservationInterval = Duration.seconds(
        CodexBarPowerHelperIPC.externalCheckIntervalSeconds
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
    private nonisolated static let signatureValidationFlags = SecCSFlags(
        rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate
    ).union(.noNetworkAccess)

    nonisolated static func validatePackage(appURL: URL, serviceIdentifier: String) -> PowerHelperPackageIssue? {
        let managerURL = PowerHelperManagement.bundleURL(in: appURL)
        let powerHelperURL = managerURL.appending(path: "Contents/Helpers/CodexBarPowerHelper")
        let plistURL = managerURL.appending(path: "Contents/Library/LaunchDaemons/\(CodexBarPowerHelperIPC.daemonPlistName)")
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: plistURL.path),
              fileManager.isExecutableFile(atPath: powerHelperURL.path) else {
            return .missing
        }
        guard let manager = Bundle(url: managerURL),
              manager.bundleIdentifier == PowerHelperManagement.bundleIdentifier,
              manager.executableURL.map({ fileManager.isExecutableFile(atPath: $0.path) }) == true,
              let plistData = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              plist["Label"] as? String == serviceIdentifier,
              plist["BundleProgram"] as? String == "Contents/Helpers/CodexBarPowerHelper",
              plist["AssociatedBundleIdentifiers"] as? [String] == [PowerHelperManagement.bundleIdentifier],
              (plist["MachServices"] as? [String: Any])?[serviceIdentifier] as? Bool == true else {
            return .invalid
        }
        var appCode: SecStaticCode?
        var signingInformation: CFDictionary?
        guard SecStaticCodeCreateWithPath(appURL as CFURL, SecCSFlags(), &appCode) == errSecSuccess,
              let appCode,
              SecStaticCodeCheckValidity(appCode, signatureValidationFlags, nil) == errSecSuccess,
              SecCodeCopySigningInformation(appCode, SecCSFlags(rawValue: kSecCSSigningInformation), &signingInformation) == errSecSuccess,
              let values = signingInformation as NSDictionary?,
              let teamIdentifier = values[kSecCodeInfoTeamIdentifier] as? String,
              !teamIdentifier.isEmpty,
              teamIdentifier.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains),
              signatureIsValid(codeURL: managerURL, teamIdentifier: teamIdentifier, expectedIdentifier: PowerHelperManagement.bundleIdentifier),
              signatureIsValid(codeURL: powerHelperURL, teamIdentifier: teamIdentifier, expectedIdentifier: serviceIdentifier) else {
            return .invalid
        }
        return nil
    }

    private nonisolated static func signatureIsValid(codeURL: URL, teamIdentifier: String, expectedIdentifier: String) -> Bool {
        guard !expectedIdentifier.isEmpty,
              expectedIdentifier.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-")).contains) else {
            return false
        }

        // App 资源封印覆盖 plist, Power Helper 另按客户端校验使用的签名团队验证全部架构
        let requirementText = "anchor apple generic"
            + " and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
            + " and identifier \"\(expectedIdentifier)\""
        var requirement: SecRequirement?
        var code: SecStaticCode?
        guard SecRequirementCreateWithString(requirementText as CFString, SecCSFlags(), &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCreateWithPath(codeURL as CFURL, SecCSFlags(), &code) == errSecSuccess,
              let code else {
            return false
        }
        return SecStaticCodeCheckValidity(code, signatureValidationFlags, requirement) == errSecSuccess
    }

    static func registrationNeedsRefresh(defaults: UserDefaults, fingerprint: String) -> Bool {
        defaults.string(forKey: registrationFingerprintKey) != fingerprint
    }

    static func beginUpdate(
        defaults: UserDefaults,
        requiresSleepReset: Bool,
        fingerprint: String
    ) -> String {
        // 待完成重置是跨 Power Helper 版本的欠账, 后续更新只能转交给新指纹, 不能清除
        let hasPendingSleepReset = defaults.string(forKey: pendingUpdateIdentifierKey) != nil
        if requiresSleepReset || hasPendingSleepReset {
            defaults.set(fingerprint, forKey: pendingUpdateIdentifierKey)
        } else {
            defaults.removeObject(forKey: pendingUpdateIdentifierKey)
        }
        return fingerprint
    }

    static func pendingUpdateIdentifier(defaults: UserDefaults, fingerprint: String) -> String? {
        guard defaults.string(forKey: registrationFingerprintKey) == fingerprint,
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
        status: KeepAliveController.PowerHelperStatus,
        fingerprint: String
    ) {
        guard status.isRegisteredOrAwaitingApproval else {
            return
        }
        defaults.set(fingerprint, forKey: registrationFingerprintKey)
    }

    static func isTransientRegistrationError(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == SMAppServiceErrorDomain
            && error.code == operationNotPermittedErrorCode
    }

    static func registerRefreshedPowerHelper(_ service: PowerHelperManagerClient) async throws {
        await Task.yield()

        var retryDelays = registrationRetryDelays.makeIterator()
        while true {
            do {
                _ = try await service.perform(.register)
                return
            } catch {
                guard isTransientRegistrationError(error),
                      let retryDelay = retryDelays.next() else {
                    throw error
                }
                try await Task.sleep(for: retryDelay)
            }
        }
    }

    private static let registrationFingerprintKey = "PowerHelper.registrationFingerprint"
    private static let pendingUpdateIdentifierKey = "PowerHelper.pendingUpdateIdentifier"
    private static let operationNotPermittedErrorCode = 1

    nonisolated static func inspectPackage(appURL: URL, serviceIdentifier: String) -> PowerHelperPackageSnapshot {
        if let issue = validatePackage(appURL: appURL, serviceIdentifier: serviceIdentifier) {
            return PowerHelperPackageSnapshot(issue: issue, fingerprint: nil)
        }
        let managerURL = PowerHelperManagement.bundleURL(in: appURL)
        let managerExecutableURL = managerURL.appending(path: "Contents/MacOS/\(PowerHelperManagement.executableName)")
        let powerHelperExecutableURL = managerURL.appending(path: "Contents/Helpers/CodexBarPowerHelper")
        let daemonPlistURL = managerURL.appending(path: "Contents/Library/LaunchDaemons/\(CodexBarPowerHelperIPC.daemonPlistName)")
        guard let managerData = try? Data(contentsOf: managerExecutableURL, options: .mappedIfSafe),
              let managerInfo = try? Data(contentsOf: managerURL.appending(path: "Contents/Info.plist")),
              let managerSeal = try? Data(contentsOf: managerURL.appending(path: "Contents/_CodeSignature/CodeResources")),
              let powerHelperData = try? Data(contentsOf: powerHelperExecutableURL, options: .mappedIfSafe),
              let daemonPlistData = try? Data(contentsOf: daemonPlistURL, options: .mappedIfSafe) else {
            return PowerHelperPackageSnapshot(issue: .invalid, fingerprint: nil)
        }

        var hasher = SHA256()
        for (name, data) in [
            (managerExecutableURL.lastPathComponent, managerData),
            ("Info.plist", managerInfo),
            ("CodeResources", managerSeal),
            (powerHelperExecutableURL.lastPathComponent, powerHelperData),
            (daemonPlistURL.lastPathComponent, daemonPlistData)
        ] {
            hasher.update(data: Data("\(name)\n\(data.count)\n".utf8))
            hasher.update(data: data)
        }
        return PowerHelperPackageSnapshot(issue: nil, fingerprint: hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }
}

nonisolated struct PowerHelperPackageSnapshot {
    let issue: PowerHelperPackageIssue?
    let fingerprint: String?
}

@MainActor
final class PowerHelperPackageValidation: ObservableObject {
    /// 同一轮校验提供注册与就绪判断共用的指纹, 不在主 actor 读取包文件
    @Published private(set) var issue: PowerHelperPackageIssue?
    private(set) var fingerprint: String?
    var onValidated: (() -> Void)?
    private let inspect: @Sendable () async -> PowerHelperPackageSnapshot
    private var task: Task<Void, Never>?

    init(inspect: @escaping @Sendable () async -> PowerHelperPackageSnapshot = {
        let appURL = Bundle.main.bundleURL
        let serviceIdentifier = CodexBarPowerHelperIPC.serviceIdentifier
        return await Task.detached(priority: .utility) {
            PowerHelperConfiguration.inspectPackage(appURL: appURL, serviceIdentifier: serviceIdentifier)
        }.value
    }) {
        self.inspect = inspect
    }

    func refresh() {
        guard task == nil else { return }
        fingerprint = nil
        let inspect = inspect
        task = Task { [weak self] in
            let result = await inspect()
            guard let self, !Task.isCancelled else { return }
            task = nil
            fingerprint = result.issue == nil ? result.fingerprint : nil
            if issue != result.issue {
                issue = result.issue
            }
            onValidated?()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        fingerprint = nil
    }
}
