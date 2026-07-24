#!/usr/bin/env swift

import Darwin
import Foundation
import ServiceManagement

private enum CleanupBuildConfiguration: String {
    case debug = "Debug"
    case release = "Release"
}

private struct CleanupTarget {
    let appURL: URL
    let bundleIdentifier: String
    let buildConfiguration: CleanupBuildConfiguration

    var plistName: String {
        serviceLabel + ".plist"
    }

    var serviceLabel: String {
        bundleIdentifier + ".helper"
    }
}

private struct CommandOutput {
    let status: Int32
    let text: String
}

private enum CleanupError: LocalizedError {
    case message(String)
    case commandFailed(executable: String, arguments: [String], status: Int32, output: String)
    case codeSigningValidationFailed(String)

    var errorDescription: String? {
        switch self {
        case let .message(message):
            message
        case let .commandFailed(executable, arguments, status, output):
            "命令执行失败, status=\(status), command=\(([executable] + arguments).joined(separator: " "))\n\(output)"
        case let .codeSigningValidationFailed(reason):
            "签名校验失败, \(reason)"
        }
    }
}

private struct CleanupOptions {
    var releaseAppURL = URL(fileURLWithPath: "/Applications/CodexBar.app")
    var debugAppURL: URL?
    var cleansRelease = true
    var cleansDebug = true
    var signingIdentity = ProcessInfo.processInfo.environment["CODEXBAR_CLEANUP_SIGN_IDENTITY"]
        ?? "Apple Development"
    var isDryRun = false
    var isCheckOnly = false
}

private final class KeepAliveCleanupCommand {
    private let fileManager = FileManager.default
    private let scriptURL = URL(fileURLWithPath: #filePath).standardizedFileURL

    private var projectURL: URL {
        scriptURL.deletingLastPathComponent().deletingLastPathComponent()
    }

    func run(arguments: [String]) throws {
        var options = try parseOptions(arguments)
        if options.cleansDebug, options.debugAppURL == nil {
            options.debugAppURL = try resolveBuiltAppURL(configuration: .debug)
        }

        let requestedTargets = try makeTargets(options: options)
        var targets: [CleanupTarget] = []
        for target in requestedTargets {
            guard try validate(target) else {
                print(
                    "清理跳过: bundle=\(target.bundleIdentifier), reason=App 不存在, path=\(target.appURL.path)"
                )
                continue
            }
            targets.append(target)
            print("清理目标: bundle=\(target.bundleIdentifier), path=\(target.appURL.path)")
        }

        guard !targets.isEmpty else {
            print("清理完成: 没有可用目标")
            return
        }

        if options.isDryRun {
            return
        }

        if !options.isCheckOnly, isCodexBarRunning() {
            throw CleanupError.message("CodexBar 仍在运行")
        }

        let temporaryRoot = fileManager.temporaryDirectory
            .appending(path: "codexbar-keep-alive-cleanup.\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        let cleanupExecutableURL = temporaryRoot.appending(path: "KeepAliveCleanup")
        try runChecked(
            "/usr/bin/xcrun",
            ["swiftc", scriptURL.path, "-o", cleanupExecutableURL.path]
        )

        for target in targets {
            let helperSourceURL = try resolveHelperSourceURL(for: target)
            try prepareAndRun(
                target: target,
                helperSourceURL: helperSourceURL,
                cleanupExecutableURL: cleanupExecutableURL,
                temporaryRoot: temporaryRoot,
                signingIdentity: options.signingIdentity,
                isCheckOnly: options.isCheckOnly
            )
        }

        if options.isCheckOnly {
            print("清理验证完成: 后台服务未注销")
        } else {
            print("后台服务已注销: 系统设置记录可能延迟清除")
        }
    }

    private func parseOptions(_ arguments: [String]) throws -> CleanupOptions {
        var options = CleanupOptions()
        var index = 0

        while index < arguments.count {
            switch arguments[index] {
            case "--release-app":
                index += 1
                guard index < arguments.count, !arguments[index].isEmpty else {
                    throw CleanupError.message("选项参数缺失, option=--release-app")
                }
                options.releaseAppURL = URL(fileURLWithPath: arguments[index])
            case "--debug-app":
                index += 1
                guard index < arguments.count, !arguments[index].isEmpty else {
                    throw CleanupError.message("选项参数缺失, option=--debug-app")
                }
                options.debugAppURL = URL(fileURLWithPath: arguments[index])
            case "--release-only":
                options.cleansRelease = true
                options.cleansDebug = false
            case "--debug-only":
                options.cleansRelease = false
                options.cleansDebug = true
            case "--sign-identity":
                index += 1
                guard index < arguments.count, !arguments[index].isEmpty else {
                    throw CleanupError.message("选项参数缺失, option=--sign-identity")
                }
                options.signingIdentity = arguments[index]
            case "--dry-run":
                options.isDryRun = true
            case "--check":
                options.isCheckOnly = true
            case "-h", "--help":
                printUsage()
                Darwin.exit(EXIT_SUCCESS)
            default:
                throw CleanupError.message("未知选项, value=\(arguments[index])")
            }
            index += 1
        }

        return options
    }

    private func printUsage() {
        print(
            """
            usage: Scripts/cleanup.swift [options]

            仅注销 CodexBar 的 Release 和 Debug KeepAlive LaunchDaemon

            Options:
              --release-app PATH       Release CodexBar.app, 默认 /Applications/CodexBar.app
              --debug-app PATH         Debug CodexBar.app, 默认使用当前 Xcode Debug 产物
              --release-only           只移除 Release Helper
              --debug-only             只移除 Debug Helper
              --sign-identity NAME     临时清理 App 的本机签名身份, 默认 Apple Development
              --dry-run                只显示目标
              --check                  只编译和验证临时清理 App, 不注销服务
              -h, --help               显示帮助

            实际清理前请先退出所有 CodexBar 实例
            """
        )
    }

    private func makeTargets(options: CleanupOptions) throws -> [CleanupTarget] {
        var targets: [CleanupTarget] = []
        if options.cleansRelease {
            targets.append(
                CleanupTarget(
                    appURL: options.releaseAppURL,
                    bundleIdentifier: "app.zabrian.codexbar",
                    buildConfiguration: .release
                )
            )
        }
        if options.cleansDebug {
            guard let debugAppURL = options.debugAppURL else {
                throw CleanupError.message("无法定位 Xcode Debug App")
            }
            targets.append(
                CleanupTarget(
                    appURL: debugAppURL,
                    bundleIdentifier: "app.zabrian.codexbar.debug",
                    buildConfiguration: .debug
                )
            )
        }
        return targets
    }

    private func resolveBuiltAppURL(configuration: CleanupBuildConfiguration) throws -> URL {
        let output = try runChecked(
            "/usr/bin/xcodebuild",
            [
                "-project", projectURL.appending(path: "CodexBar.xcodeproj").path,
                "-scheme", "CodexBar",
                "-configuration", configuration.rawValue,
                "-destination", "generic/platform=macOS",
                "-showBuildSettings"
            ],
            capturesOutput: true
        ).text

        guard let targetBuildDirectory = buildSetting("TARGET_BUILD_DIR", in: output),
              let wrapperName = buildSetting("WRAPPER_NAME", in: output) else {
            throw CleanupError.message(
                "无法从 Xcode 构建设置定位 App, configuration=\(configuration.rawValue)"
            )
        }
        return URL(fileURLWithPath: targetBuildDirectory).appending(path: wrapperName)
    }

    private func buildSetting(_ name: String, in output: String) -> String? {
        let prefix = "\(name) = "
        return output.split(whereSeparator: \.isNewline)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
    }

    private func validate(_ target: CleanupTarget) throws -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: target.appURL.path, isDirectory: &isDirectory) else {
            return false
        }
        guard isDirectory.boolValue else {
            throw CleanupError.message(
                "App 类型错误, actual=file, expected=directory, path=\(target.appURL.path)"
            )
        }

        let info = try propertyListDictionary(at: target.appURL.appending(path: "Contents/Info.plist"))
        let actualIdentifier = info["CFBundleIdentifier"] as? String ?? "missing"
        guard actualIdentifier == target.bundleIdentifier else {
            throw CleanupError.message(
                "App 标识符错误, actual=\(actualIdentifier), expected=\(target.bundleIdentifier), path=\(target.appURL.path)"
            )
        }
        return true
    }

    private func resolveHelperSourceURL(for target: CleanupTarget) throws -> URL {
        let bundledHelperURL = helperURL(in: target.appURL)
        if fileManager.isExecutableFile(atPath: bundledHelperURL.path) {
            return bundledHelperURL
        }

        let builtAppURL = try resolveBuiltAppURL(configuration: target.buildConfiguration)
        let builtHelperURL = helperURL(in: builtAppURL)
        guard fileManager.isExecutableFile(atPath: builtHelperURL.path) else {
            throw CleanupError.message(
                "CodexBarHelper 未构建, configuration=\(target.buildConfiguration.rawValue)"
            )
        }
        return builtHelperURL
    }

    private func helperURL(in appURL: URL) -> URL {
        appURL.appending(path: "Contents/Resources/CodexBarHelper")
    }

    private func isCodexBarRunning() -> Bool {
        (try? run("/usr/bin/pgrep", ["-x", "CodexBar"], capturesOutput: true).status) == 0
    }

    private func prepareAndRun(
        target: CleanupTarget,
        helperSourceURL: URL,
        cleanupExecutableURL: URL,
        temporaryRoot: URL,
        signingIdentity: String,
        isCheckOnly: Bool
    ) throws {
        let teamIdentifier = try signingTeamIdentifier(for: target.appURL)
        let cleanupAppURL = temporaryRoot
            .appending(path: "\(target.bundleIdentifier).app", directoryHint: .isDirectory)
        let contentsURL = cleanupAppURL.appending(path: "Contents", directoryHint: .isDirectory)
        let macOSURL = contentsURL.appending(path: "MacOS", directoryHint: .isDirectory)
        let daemonsURL = contentsURL.appending(path: "Library/LaunchDaemons", directoryHint: .isDirectory)
        let resourcesURL = contentsURL.appending(path: "Resources", directoryHint: .isDirectory)

        for directory in [macOSURL, daemonsURL, resourcesURL] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        var info = try propertyListDictionary(at: target.appURL.appending(path: "Contents/Info.plist"))
        info["CFBundleExecutable"] = "KeepAliveCleanup"
        info["CFBundleName"] = "CodexBar KeepAlive Cleanup"
        try writePropertyList(info, to: contentsURL.appending(path: "Info.plist"))

        let bundledPlistURL = target.appURL
            .appending(path: "Contents/Library/LaunchDaemons")
            .appending(path: target.plistName)
        let sourcePlistURL = fileManager.fileExists(atPath: bundledPlistURL.path)
            ? bundledPlistURL
            : projectURL.appending(path: "CodexBarHelper").appending(path: target.plistName)
        guard fileManager.fileExists(atPath: sourcePlistURL.path) else {
            throw CleanupError.message("LaunchDaemon 配置缺失, name=\(target.plistName)")
        }

        let destinationPlistURL = daemonsURL.appending(path: target.plistName)
        let destinationHelperURL = resourcesURL.appending(path: "CodexBarHelper")
        let destinationExecutableURL = macOSURL.appending(path: "KeepAliveCleanup")
        try fileManager.copyItem(at: sourcePlistURL, to: destinationPlistURL)
        try fileManager.copyItem(at: helperSourceURL, to: destinationHelperURL)
        try fileManager.copyItem(at: cleanupExecutableURL, to: destinationExecutableURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destinationHelperURL.path)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destinationExecutableURL.path)

        try runCodeSigningChecked(
            [
                "--force",
                "--identifier", target.serviceLabel,
                "--options", "runtime",
                "--timestamp=none",
                "--sign", signingIdentity,
                destinationHelperURL.path
            ],
            failureReason: "Helper 签名失败"
        )
        try runCodeSigningChecked(
            [
                "--force",
                "--options", "runtime",
                "--timestamp=none",
                "--sign", signingIdentity,
                cleanupAppURL.path
            ],
            failureReason: "清理 App 签名失败"
        )

        let cleanupTeamIdentifier = try signingTeamIdentifier(for: cleanupAppURL)
        guard cleanupTeamIdentifier == teamIdentifier else {
            throw CleanupError.codeSigningValidationFailed(
                "Team ID 不匹配, actual=\(cleanupTeamIdentifier), expected=\(teamIdentifier)"
            )
        }
        try runCodeSigningChecked(
            ["--verify", "--strict", "--verbose=2", cleanupAppURL.path],
            failureReason: "清理 App 验证失败"
        )

        if isCheckOnly {
            print("目标验证完成: bundle=\(target.bundleIdentifier)")
            return
        }

        try runChecked(destinationExecutableURL.path, ["--unregister-child", target.plistName])
        try runChecked(
            "/usr/bin/defaults",
            ["write", target.bundleIdentifier, "KeepAlive.isEnabled", "-bool", "false"]
        )
        _ = try run(
            "/usr/bin/defaults",
            ["delete", target.bundleIdentifier, "KeepAlive.helperRegistrationFingerprint"],
            capturesOutput: true
        )

        let serviceStatus = try run(
            "/bin/launchctl",
            ["print", "system/\(target.serviceLabel)"],
            capturesOutput: true
        )
        guard serviceStatus.status != 0 else {
            throw CleanupError.message("后台服务仍在运行, service=\(target.serviceLabel)")
        }
    }

    private func propertyListDictionary(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let dictionary = try PropertyListSerialization.propertyList(from: data, format: nil)
            as? [String: Any] else {
            throw CleanupError.message("plist 内容无效, path=\(url.path)")
        }
        return dictionary
    }

    private func writePropertyList(_ dictionary: [String: Any], to url: URL) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: dictionary,
            format: .xml,
            options: 0
        )
        try data.write(to: url, options: .atomic)
    }

    private func signingTeamIdentifier(for appURL: URL) throws -> String {
        let output = try runCodeSigningChecked(
            ["-dvv", appURL.path],
            failureReason: "读取签名信息失败, path=\(appURL.path)",
            capturesOutput: true
        ).text
        guard let line = output.split(whereSeparator: \.isNewline)
            .first(where: { $0.hasPrefix("TeamIdentifier=") }) else {
            throw CleanupError.codeSigningValidationFailed(
                "Team ID 缺失, path=\(appURL.path)"
            )
        }
        let teamIdentifier = String(line.dropFirst("TeamIdentifier=".count))
        guard !teamIdentifier.isEmpty else {
            throw CleanupError.codeSigningValidationFailed(
                "Team ID 为空, path=\(appURL.path)"
            )
        }
        guard teamIdentifier.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains) else {
            throw CleanupError.codeSigningValidationFailed(
                "Team ID 格式错误, actual=\(teamIdentifier), expected=alphanumeric"
            )
        }
        return teamIdentifier
    }

    @discardableResult
    private func runCodeSigningChecked(
        _ arguments: [String],
        failureReason: String,
        capturesOutput: Bool = false
    ) throws -> CommandOutput {
        let output: CommandOutput
        do {
            output = try run(
                "/usr/bin/codesign",
                arguments,
                capturesOutput: capturesOutput
            )
        } catch {
            throw CleanupError.codeSigningValidationFailed(
                "\(failureReason), detail=\(error.localizedDescription)"
            )
        }
        guard output.status == 0 else {
            let detail = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let detailSuffix = detail.isEmpty ? "" : ", detail=\(detail)"
            throw CleanupError.codeSigningValidationFailed(
                "\(failureReason), status=\(output.status)\(detailSuffix)"
            )
        }
        return output
    }

    @discardableResult
    private func runChecked(
        _ executable: String,
        _ arguments: [String],
        capturesOutput: Bool = false
    ) throws -> CommandOutput {
        let output = try run(executable, arguments, capturesOutput: capturesOutput)
        guard output.status == 0 else {
            throw CleanupError.commandFailed(
                executable: executable,
                arguments: arguments,
                status: output.status,
                output: output.text
            )
        }
        return output
    }

    private func run(
        _ executable: String,
        _ arguments: [String],
        capturesOutput: Bool
    ) throws -> CommandOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let pipe: Pipe?
        if capturesOutput {
            let outputPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = outputPipe
            pipe = outputPipe
        } else {
            pipe = nil
        }

        try process.run()
        let data = pipe?.fileHandleForReading.readDataToEndOfFile() ?? Data()
        process.waitUntilExit()
        return CommandOutput(
            status: process.terminationStatus,
            text: String(decoding: data, as: UTF8.self)
        )
    }
}

private func runUnregisterChild(plistName: String) -> Never {
    let service = SMAppService.daemon(plistName: plistName)
    switch service.status {
    case .enabled, .requiresApproval:
        service.unregister { error in
            if let error {
                FileHandle.standardError.write(
                    Data(
                        "后台服务注销失败: service=\(plistName), detail=\(error.localizedDescription)\n".utf8
                    )
                )
                Darwin.exit(EXIT_FAILURE)
            }
            print("后台服务已注销: service=\(plistName)")
            Darwin.exit(EXIT_SUCCESS)
        }
        RunLoop.main.run()
        Darwin.exit(EXIT_FAILURE)
    case .notRegistered, .notFound:
        print("后台服务未注册: service=\(plistName)")
        Darwin.exit(EXIT_SUCCESS)
    @unknown default:
        FileHandle.standardError.write(
            Data("后台服务状态未知: service=\(plistName)\n".utf8)
        )
        Darwin.exit(EXIT_FAILURE)
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "--unregister-child" {
    guard arguments.count == 2 else {
        FileHandle.standardError.write(
            Data("内部参数无效: expected=2, actual=\(arguments.count)\n".utf8)
        )
        Darwin.exit(EXIT_FAILURE)
    }
    runUnregisterChild(plistName: arguments[1])
}

do {
    try KeepAliveCleanupCommand().run(arguments: arguments)
} catch {
    FileHandle.standardError.write(Data("清理失败: \(error.localizedDescription)\n".utf8))
    Darwin.exit(EXIT_FAILURE)
}
