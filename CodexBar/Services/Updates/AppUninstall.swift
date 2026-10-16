import Darwin
import Foundation
import ServiceManagement

nonisolated struct AppUninstallOptions: Equatable {
    static let argument = "--uninstall"
    let keepsApp: Bool
    let showsHelp: Bool

    init(arguments: [String]) throws {
        guard arguments.first == Self.argument,
              arguments.dropFirst().allSatisfy({ ["--keep-app", "--help"].contains($0) }),
              Set(arguments).count == arguments.count else {
            throw AppUninstallError("参数无效, 使用 --uninstall --help 查看帮助")
        }
        keepsApp = arguments.contains("--keep-app")
        showsHelp = arguments.contains("--help")
    }
}

nonisolated struct AppUninstallError: LocalizedError {
    let message: String
    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}

enum AppUninstall {
    nonisolated static func validatedExecutableURL(appURL: URL) throws -> URL {
        guard appURL.pathExtension == "app", let bundle = Bundle(url: appURL) else {
            throw AppUninstallError("当前路径不是有效的 App 包, 请运行 App 包中的 Contents/MacOS/CodexBar")
        }
        guard bundle.bundleIdentifier == CodexBarHelperIPC.appBundleIdentifier else {
            throw AppUninstallError("当前 App 标识与卸载命令不匹配")
        }
        // URL 的目录标记和 baseURL 表示可能不同, 按标准化文件路径核对位置
        let executableDirectory = appURL.appending(path: "Contents/MacOS").standardizedFileURL.path
        guard let executable = bundle.executableURL,
              executable.deletingLastPathComponent().standardizedFileURL.path == executableDirectory else {
            throw AppUninstallError("当前 App 可执行文件不在 Contents/MacOS 目录中")
        }
        return executable
    }

    static func isUnregistered(_ status: SMAppService.Status) -> Bool {
        status == .notRegistered || status == .notFound
    }

    nonisolated static func preferencesURL(domain: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Preferences/\(domain).plist")
    }

    nonisolated static func removePreferences(domain: String) throws -> Bool {
        let keys = try preferenceKeys(domain: domain)
        let url = preferencesURL(domain: domain)
        guard !keys.isEmpty || FileManager.default.fileExists(atPath: url.path) else { return false }

        // 先通过偏好服务清空并落盘, 避免仅删除 plist 后被缓存写回
        CFPreferencesSetMultiple(nil, keys as CFArray, domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard try preferenceKeys(domain: domain).isEmpty else {
            throw AppUninstallError("App 设置仍存在, 未删除设置 plist")
        }
        if unlink(url.path) != 0, errno != ENOENT {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try verifyPreferencesRemoved(domain: domain)
        return true
    }

    nonisolated static func verifyPreferencesRemoved(domain: String) throws {
        guard try preferenceKeys(domain: domain).isEmpty,
              !FileManager.default.fileExists(atPath: preferencesURL(domain: domain).path) else {
            throw AppUninstallError("App 设置或设置 plist 仍存在")
        }
    }

    private nonisolated static func preferenceKeys(domain: String) throws -> [String] {
        guard CFPreferencesSynchronize(domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            throw AppUninstallError("无法同步 App 设置, 未确认偏好缓存与 plist 状态")
        }
        return CFPreferencesCopyKeyList(domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String] ?? []
    }

    enum Step: String, CaseIterable {
        case quit = "退出 CodexBar App"
        case hooks = "移除 CodexBar Hook"
        case loginItem = "注销 CodexBar 启动项"
        case helper = "注销 CodexBar Helper"
        case preferences = "移除 CodexBar 配置"
        case verify = "验证清理结果"
        case trash = "将 App 移到废纸篓"

        static var cleanupSteps: [Step] {
            allCases.filter { $0 != .trash }
        }

        func progressMessage(_ status: Status, detail: String? = nil) -> String {
            let result = status.description + (detail.map { " (\($0))" } ?? "")
            if self == .trash {
                return "收尾 \(rawValue) ... \(result)"
            }
            let index = (Self.allCases.firstIndex(of: self) ?? 0) + 1
            return "[\(index)/\(Self.cleanupSteps.count)] \(rawValue) ... \(result)"
        }
    }

    enum Status: Equatable {
        case running
        case succeeded
        case failed(String)
        case skipped(String)

        var description: String {
            switch self {
            case .running: "执行中"
            case .succeeded: "成功"
            case let .failed(reason): "失败 (\(reason))"
            case let .skipped(reason): "跳过 (\(reason))"
            }
        }
    }

    struct Report {
        var results: [Step: Status] = [:]

        var hasFailures: Bool {
            results.values.contains {
                if case .failed = $0 {
                    true
                } else {
                    false
                }
            }
        }

        var summary: String {
            let cleanupResults = Step.cleanupSteps.compactMap { results[$0] }
            let succeeded = cleanupResults.filter { $0 == .succeeded }.count
            let failed = cleanupResults.filter {
                if case .failed = $0 {
                    true
                } else {
                    false
                }
            }.count
            let skipped = cleanupResults.filter {
                if case .skipped = $0 {
                    true
                } else {
                    false
                }
            }.count
            let appStatus = switch results[.trash] {
            case .succeeded: "App 已移到废纸篓"
            case let .failed(reason): "App 移到废纸篓失败: \(reason)"
            default: "App 已保留"
            }
            let retry = hasFailures ? "\n请处理失败项后重新运行卸载命令" : ""
            return "清理结束: 成功 \(succeeded), 失败 \(failed), 跳过 \(skipped)\n\(appStatus)\(retry)"
        }
    }

    static func run(
        options: AppUninstallOptions,
        progress: (Step, Status) -> Void = { _, _ in },
        perform: (Step) async throws -> Status
    ) async -> Report {
        var report = Report()
        guard !options.showsHelp else { return report }
        var cancelled = false
        for step in Step.allCases {
            let status: Status
            if cancelled {
                status = .skipped("操作已取消")
            } else if Task.isCancelled {
                status = .failed("操作已取消")
                cancelled = true
            } else if step == .trash, options.keepsApp {
                status = .skipped("已指定 --keep-app")
            } else if step != .quit, report.results[.quit] != .succeeded {
                status = .skipped("App 未完成退出或前置检查")
            } else if step == .preferences, report.hasFailures {
                status = .skipped("前序清理失败, 保留设置以便重试")
            } else if step == .trash, report.hasFailures || report.results[.verify] != .succeeded {
                status = .skipped("存在失败步骤, 保留 App 以便重试")
            } else {
                progress(step, .running)
                do {
                    status = try await perform(step)
                } catch is CancellationError {
                    status = .failed("操作已取消")
                    cancelled = true
                } catch {
                    status = .failed(error.localizedDescription)
                }
            }
            report.results[step] = status
            progress(step, status)
        }
        return report
    }

    static func removeLoginItem(status: SMAppService.Status, unregister: () async throws -> Void) async throws -> Status {
        switch status {
        case .notRegistered, .notFound, .requiresApproval:
            return .skipped("开机自动启动未启用")
        case .enabled:
            try await unregister()
            return .succeeded
        @unknown default:
            throw AppUninstallError("无法确认开机启动项状态")
        }
    }

    static func removeHelper(
        status: SMAppService.Status,
        clearState: () async throws -> Void,
        unregister: () async throws -> Void
    ) async throws -> Status {
        switch status {
        case .notRegistered, .notFound:
            return .skipped("Helper 未注册")
        case .enabled:
            try await clearState()
        case .requiresApproval:
            // 未授权的服务不能依赖 XPC 清理, 直接注销后由验证步骤核对残留状态
            break
        @unknown default:
            throw AppUninstallError("无法确认 Helper 注册状态")
        }
        try await unregister()
        return .succeeded
    }
}

/// 普通 App 持有共享锁, 清理进程在旧 App 退出后持有独占锁直到结束
final nonisolated class AppUninstallLease: Sendable {
    private let descriptor: Int32
    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    static func acquire(exclusive: Bool, url: URL = defaultURL) throws -> AppUninstallLease {
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
            close(descriptor)
            throw AppUninstallError("清理锁文件无效")
        }
        guard flock(descriptor, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0 else {
            close(descriptor)
            throw AppUninstallError("App 仍在运行或另一个清理正在进行, 请稍后重试")
        }
        return AppUninstallLease(descriptor: descriptor)
    }

    private static var defaultURL: URL {
        FileManager.default.temporaryDirectory.appending(path: "\(CodexBarHelperIPC.appBundleIdentifier).uninstall.lock")
    }

    deinit { close(descriptor) }
}
