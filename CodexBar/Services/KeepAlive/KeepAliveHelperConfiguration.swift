import Combine
import CryptoKit
import Foundation
import Security
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

    nonisolated static func validatePackage(appURL: URL, machServiceName: String) -> HelperPackageIssue? {
        let helperURL = appURL.appending(path: "Contents/Resources/CodexBarHelper")
        let plistURL = appURL.appending(path: "Contents/Library/LaunchDaemons/\(machServiceName).plist")
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: plistURL.path),
              fileManager.isExecutableFile(atPath: helperURL.path) else {
            return .missing
        }
        guard let appIdentifier = Bundle(url: appURL)?.bundleIdentifier,
              let plistData = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              plist["Label"] as? String == machServiceName,
              plist["BundleProgram"] as? String == "Contents/Resources/CodexBarHelper",
              (plist["AssociatedBundleIdentifiers"] as? [String])?.contains(appIdentifier) == true,
              (plist["MachServices"] as? [String: Any])?[machServiceName] as? Bool == true else {
            return .invalid
        }
        guard helperSignatureIsValid(helperURL: helperURL, appURL: appURL, machServiceName: machServiceName) else {
            return .invalid
        }
        return nil
    }

    private nonisolated static func helperSignatureIsValid(helperURL: URL, appURL: URL, machServiceName: String) -> Bool {
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate).union(.noNetworkAccess)
        var appCode: SecStaticCode?
        var signingInformation: CFDictionary?
        guard SecStaticCodeCreateWithPath(appURL as CFURL, SecCSFlags(), &appCode) == errSecSuccess,
              let appCode,
              SecStaticCodeCheckValidity(appCode, flags, nil) == errSecSuccess,
              SecCodeCopySigningInformation(appCode, SecCSFlags(rawValue: kSecCSSigningInformation), &signingInformation) == errSecSuccess,
              let values = signingInformation as NSDictionary?,
              let teamIdentifier = values[kSecCodeInfoTeamIdentifier] as? String,
              !teamIdentifier.isEmpty,
              teamIdentifier.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains),
              !machServiceName.isEmpty,
              machServiceName.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-")).contains) else {
            return false
        }

        // App 资源封印覆盖 plist, helper 另按客户端校验使用的签名团队验证全部架构
        let requirementText = "anchor apple generic"
            + " and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
            + " and identifier \"\(machServiceName)\""
        var requirement: SecRequirement?
        var helperCode: SecStaticCode?
        guard SecRequirementCreateWithString(requirementText as CFString, SecCSFlags(), &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCreateWithPath(helperURL as CFURL, SecCSFlags(), &helperCode) == errSecSuccess,
              let helperCode else {
            return false
        }
        return SecStaticCodeCheckValidity(helperCode, flags, requirement) == errSecSuccess
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

    static func registerRefreshedHelper(_ service: SMAppService) async throws {
        await Task.yield()

        var retryDelays = registrationRetryDelays.makeIterator()
        while true {
            do {
                try service.register()
                return
            } catch {
                let status = KeepAliveController.HelperStatus(service.status)
                if status.isRegisteredOrAwaitingApproval {
                    return
                }
                guard isTransientRegistrationError(error),
                      let retryDelay = retryDelays.next() else {
                    throw error
                }
                try await Task.sleep(for: retryDelay)
            }
        }
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

@MainActor
final class HelperPackageValidation: ObservableObject {
    /// 包校验与安装前检查共用组件异常, 不写入注册操作错误
    @Published private(set) var issue: HelperPackageIssue?
    private var task: Task<Void, Never>?

    func refresh() {
        guard task == nil else { return }
        let appURL = Bundle.main.bundleURL
        let machServiceName = CodexBarHelperIPC.machServiceName
        task = Task { [weak self] in
            let worker = Task.detached(priority: .utility) {
                KeepAliveHelperConfiguration.validatePackage(appURL: appURL, machServiceName: machServiceName)
            }
            let result = await worker.value
            guard let self, !Task.isCancelled else { return }
            task = nil
            if issue != result {
                issue = result
            }
        }
    }

    func reportMissingAssets() {
        // 丢弃先前校验结果, 避免旧的正常结果覆盖刚确认的缺失
        cancel()
        if issue != .missing {
            issue = .missing
        }
        refresh()
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
