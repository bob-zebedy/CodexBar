import Combine
import CryptoKit
import Foundation
import Security
import ServiceManagement

@MainActor
enum HelperConfiguration {
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

    nonisolated static func validatePackage(appURL: URL, machServiceName: String) -> HelperPackageIssue? {
        let managerURL = HelperManagement.bundleURL(in: appURL)
        let helperURL = managerURL.appending(path: "Contents/Resources/CodexBarHelper")
        let plistURL = managerURL.appending(path: "Contents/Library/LaunchDaemons/\(machServiceName).plist")
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: plistURL.path),
              fileManager.isExecutableFile(atPath: helperURL.path) else {
            return .missing
        }
        guard let manager = Bundle(url: managerURL),
              manager.bundleIdentifier == HelperManagement.bundleIdentifier,
              manager.executableURL.map({ fileManager.isExecutableFile(atPath: $0.path) }) == true,
              let plistData = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              plist["Label"] as? String == machServiceName,
              plist["BundleProgram"] as? String == "Contents/Resources/CodexBarHelper",
              plist["AssociatedBundleIdentifiers"] as? [String] == [HelperManagement.bundleIdentifier],
              (plist["MachServices"] as? [String: Any])?[machServiceName] as? Bool == true else {
            return .invalid
        }
        guard helperSignatureIsValid(helperURL: managerURL, appURL: appURL, machServiceName: HelperManagement.bundleIdentifier),
              helperSignatureIsValid(helperURL: helperURL, appURL: appURL, machServiceName: machServiceName) else {
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

    static func registrationNeedsRefresh(defaults: UserDefaults, fingerprint: String) -> Bool {
        defaults.string(forKey: registrationFingerprintKey) != fingerprint
    }

    static func beginUpdate(
        defaults: UserDefaults,
        requiresSleepReset: Bool,
        fingerprint: String
    ) -> String {
        // 待完成重置是跨 Helper 版本的欠账, 后续更新只能转交给新指纹, 不能清除
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
        status: KeepAliveController.HelperStatus,
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

    static func registerRefreshedHelper(_ service: HelperManagerClient) async throws {
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

    private static let registrationFingerprintKey = "KeepAlive.helperRegistrationFingerprint"
    private static let pendingUpdateIdentifierKey = "KeepAlive.pendingHelperUpdateIdentifier"
    private static let operationNotPermittedErrorCode = 1

    nonisolated static func inspectPackage(appURL: URL, machServiceName: String) -> HelperPackageSnapshot {
        if let issue = validatePackage(appURL: appURL, machServiceName: machServiceName) {
            return HelperPackageSnapshot(issue: issue, fingerprint: nil)
        }
        let managerURL = HelperManagement.bundleURL(in: appURL)
        let managerExecutableURL = managerURL.appending(path: "Contents/MacOS/\(HelperManagement.executableName)")
        let helperExecutableURL = managerURL.appending(path: "Contents/Resources/CodexBarHelper")
        let daemonPlistURL = managerURL.appending(path: "Contents/Library/LaunchDaemons/\(machServiceName).plist")
        guard let managerData = try? Data(contentsOf: managerExecutableURL, options: .mappedIfSafe),
              let managerInfo = try? Data(contentsOf: managerURL.appending(path: "Contents/Info.plist")),
              let managerSeal = try? Data(contentsOf: managerURL.appending(path: "Contents/_CodeSignature/CodeResources")),
              let helperData = try? Data(contentsOf: helperExecutableURL, options: .mappedIfSafe),
              let daemonPlistData = try? Data(contentsOf: daemonPlistURL, options: .mappedIfSafe) else {
            return HelperPackageSnapshot(issue: .invalid, fingerprint: nil)
        }

        var hasher = SHA256()
        for (name, data) in [
            (managerExecutableURL.lastPathComponent, managerData),
            ("Info.plist", managerInfo),
            ("CodeResources", managerSeal),
            (helperExecutableURL.lastPathComponent, helperData),
            (daemonPlistURL.lastPathComponent, daemonPlistData)
        ] {
            hasher.update(data: Data("\(name)\n\(data.count)\n".utf8))
            hasher.update(data: data)
        }
        return HelperPackageSnapshot(issue: nil, fingerprint: hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }
}

nonisolated struct HelperPackageSnapshot {
    let issue: HelperPackageIssue?
    let fingerprint: String?
}

@MainActor
final class HelperPackageValidation: ObservableObject {
    /// 同一轮校验提供注册与就绪判断共用的指纹, 不在主 actor 读取包文件
    @Published private(set) var issue: HelperPackageIssue?
    private(set) var fingerprint: String?
    var onValidated: (() -> Void)?
    private let inspect: @Sendable () async -> HelperPackageSnapshot
    private var task: Task<Void, Never>?

    init(inspect: @escaping @Sendable () async -> HelperPackageSnapshot = {
        let appURL = Bundle.main.bundleURL
        let machServiceName = CodexBarHelperIPC.machServiceName
        return await Task.detached(priority: .utility) {
            HelperConfiguration.inspectPackage(appURL: appURL, machServiceName: machServiceName)
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
