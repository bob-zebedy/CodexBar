#!/usr/bin/env swift

import AppKit
import Darwin
import Foundation
import ServiceManagement

private enum CleanupBuildConfiguration: String, CaseIterable {
    case release = "Release"
    case debug = "Debug"

    var bundleIdentifier: String {
        switch self {
        case .release:
            "app.zabrian.codexbar"
        case .debug:
            "app.zabrian.codexbar.debug"
        }
    }
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
    var selectedConfigurations: Set<CleanupBuildConfiguration> = []
    var signingIdentity = ProcessInfo.processInfo.environment["CODEXBAR_CLEANUP_SIGN_IDENTITY"]
        ?? "Apple Development"
    var isCheckOnly = false

    func includes(_ configuration: CleanupBuildConfiguration) -> Bool {
        selectedConfigurations.isEmpty || selectedConfigurations.contains(configuration)
    }
}

private final class KeepAliveCleanupCommand {
    private let fileManager = FileManager.default
    private let scriptURL = URL(fileURLWithPath: #filePath).standardizedFileURL

    private var projectURL: URL {
        scriptURL.deletingLastPathComponent().deletingLastPathComponent()
    }

    func run(arguments: [String]) throws {
        let options = try parseOptions(arguments)
        let targets = try makeTargets(options: options)

        guard !targets.isEmpty else {
            print("清理完成: 没有可用目标")
            return
        }

        let runningTargets = runningTargets(in: targets)
        if !options.isCheckOnly, !runningTargets.isEmpty {
            let bundleIdentifiers = runningTargets.map(\.bundleIdentifier).joined(separator: ", ")
            throw CleanupError.message("CodexBar 仍在运行, bundle=\(bundleIdentifiers)")
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
    }

    private func parseOptions(_ arguments: [String]) throws -> CleanupOptions {
        var options = CleanupOptions()

        for argument in arguments {
            switch argument {
            case "--release":
                options.selectedConfigurations.insert(.release)
            case "--debug":
                options.selectedConfigurations.insert(.debug)
            case "--check":
                options.isCheckOnly = true
            case "-h", "--help":
                printUsage()
                Darwin.exit(EXIT_SUCCESS)
            default:
                throw CleanupError.message("未知选项, value=\(argument)")
            }
        }

        return options
    }

    private func printUsage() {
        print(
            """
            usage: Scripts/cleanup.swift [options]

            仅注销 CodexBar 的 Release 和 Debug KeepAlive LaunchDaemon

            Options:
              --release       只移除 Release Helper
              --debug         只移除 Debug Helper
              --check         只检查目标
              -h, --help      显示帮助

            不指定 --release 或 --debug 时同时处理两个目标
            实际清理前请先退出待清理的 CodexBar 实例
            """
        )
    }

    private func makeTargets(options: CleanupOptions) throws -> [CleanupTarget] {
        try CleanupBuildConfiguration.allCases
            .filter(options.includes)
            .compactMap { configuration in
                let bundleIdentifier = configuration.bundleIdentifier
                guard let appURL = try resolveAppURL(configuration: configuration) else {
                    print("清理跳过: bundle=\(bundleIdentifier), reason=未找到 App")
                    return nil
                }

                print("清理目标: bundle=\(bundleIdentifier), path=\(appURL.path)")
                return CleanupTarget(
                    appURL: appURL,
                    bundleIdentifier: bundleIdentifier,
                    buildConfiguration: configuration
                )
            }
    }

    /// 候选按可信度排序, 命中的唯一标准是 Info.plist 里的 CFBundleIdentifier 对得上
    /// 这里就是唯一的 App 校验点: 读到 Info.plist 即说明是个目录, 标识符对上即说明是这个 App
    private func resolveAppURL(configuration: CleanupBuildConfiguration) throws -> URL? {
        let bundleIdentifier = configuration.bundleIdentifier
        var candidates: [URL] = []
        if configuration == .release {
            candidates.append(URL(fileURLWithPath: "/Applications/CodexBar.app"))
        }
        if let registeredURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleIdentifier
        ) {
            candidates.append(registeredURL)
        }
        if configuration == .release {
            candidates.append(projectURL.appending(path: "Build/CodexBar.app"))
        }

        for candidate in candidates {
            if try appBundleIdentifier(at: candidate) == bundleIdentifier {
                return candidate
            }
        }

        // xcodebuild 定位不到是"查不到"而不是数据损坏, 保持非致命
        guard let builtAppURL = try? resolveBuiltAppURL(configuration: configuration) else {
            return nil
        }
        return try appBundleIdentifier(at: builtAppURL) == bundleIdentifier ? builtAppURL : nil
    }

    /// 返回 nil 只代表这个路径下没有 App, 属于正常跳过
    /// 读到了却解析不了必须抛出去: 用 try? 折叠成 nil 会把损坏的安装当成"不是这个 App",
    /// 于是一次什么都没清理的运行照样打印完成并以 0 退出
    private func appBundleIdentifier(at appURL: URL) throws -> String? {
        let infoURL = appURL.appending(path: "Contents/Info.plist")
        guard fileManager.fileExists(atPath: infoURL.path) else {
            return nil
        }

        return try propertyListDictionary(at: infoURL)["CFBundleIdentifier"] as? String
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

    private func runningTargets(in targets: [CleanupTarget]) -> [CleanupTarget] {
        targets.filter { target in
            !NSRunningApplication.runningApplications(
                withBundleIdentifier: target.bundleIdentifier
            ).isEmpty
        }
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
            failureReason: "签名 Helper 失败"
        )
        try runCodeSigningChecked(
            [
                "--force",
                "--options", "runtime",
                "--timestamp=none",
                "--sign", signingIdentity,
                cleanupAppURL.path
            ],
            failureReason: "签名 App 失败"
        )

        let cleanupTeamIdentifier = try signingTeamIdentifier(for: cleanupAppURL)
        guard cleanupTeamIdentifier == teamIdentifier else {
            throw CleanupError.codeSigningValidationFailed(
                "Team ID 不匹配, actual=\(cleanupTeamIdentifier), expected=\(teamIdentifier)"
            )
        }
        try runCodeSigningChecked(
            ["--verify", "--strict", "--verbose=2", cleanupAppURL.path],
            failureReason: "验证 App 签名失败"
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
