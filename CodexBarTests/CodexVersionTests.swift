import Foundation
import Testing

struct CodexVersionTests {
    @Test(arguments: [
        ("0.150.0", false),
        ("0.152.1", false),
        ("0.160.0-alpha.2", false),
        ("0.160.0", true),
        ("0.160.1", true)
    ])
    func activityRequiresSharedServerProtocol(_ version: String, _ expected: Bool) {
        #expect(CodexVersionReader.isVersion(version, atLeast: CodexMinimumVersion.activity) == expected)
        #expect(CodexVersionReader.isVersion(version, atLeast: CodexMinimumVersion.global) == expected)
    }

    @Test(arguments: [
        ("0.149.9", "0.150.0", false),
        ("0.150.0", "0.150.0", true),
        ("0.150.0-alpha.2", "0.150.0", false),
        ("0.150.0-alpha.10", "0.150.0-alpha.2", true),
        ("0.150.0-beta", "0.150.0-alpha.10", true),
        ("1.0.0", "0.150.0", true),
        ("codex-cli 0.150.0+build1", "0.150.0+build2", true)
    ])
    func minimumVersionComparesNumericAndPrereleaseComponents(_ version: String, _ minimum: String, _ expected: Bool) {
        #expect(CodexVersionReader.isVersion(version, atLeast: minimum) == expected)
    }

    @Test(arguments: ["unknown", "0.150", "0.150.x", "0.150.0-", "0.150.0-alpha..1"])
    func unrecognizedVersionHasNoOrdering(_ version: String) {
        #expect(CodexVersionReader.isVersion(version, atLeast: "0.150.0") == nil)
    }

    @Test func installedVersionDoesNotClaimToBeSharedServerVersion() {
        let item = CodexVersionItem(source: .global, path: "/installed/codex", version: "0.160.1")
        let display = CodexVersionDisplay(item: item)
        #expect(display.displayVersion == "0.160.1")
        #expect(display.path == "/installed/codex")
    }

    @Test func codexHomeUsesExplicitEnvironmentAndTrimsWhitespace() {
        #expect(CodexPaths.codexHomeDirectory(environment: ["CODEX_HOME": " /tmp/custom ", "HOME": "/tmp/home"]).path == "/tmp/custom")
        #expect(CodexPaths.codexHomeDirectory(environment: ["CODEX_HOME": " ", "HOME": "/tmp/home"]).path == "/tmp/home/.codex")
    }

    @Test func bundledCLIUsesManifestEntrypointBeforeLegacyPath() throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        _ = try directory.write(#"{"entrypoint":"custom/cli","version":"0.158.0","layoutVersion":1}"#, to: "codex-cli/codex-package.json")
        let entrypoint = try writeExecutable(in: directory, path: "codex-cli/custom/cli")
        _ = try writeExecutable(in: directory, path: "codex")

        let installations = CodexPaths.resolveInstallations(environment: ["PATH": ""], bundledResourceURL: directory.url)
        #expect(installations.bundledPath == entrypoint.path)
        #expect(installations.globalPath == nil)
    }

    @Test(arguments: [nil, "invalid", "{}", #"{"entrypoint":42}"#, #"{"entrypoint":""}"#, #"{"entrypoint":"bin/missing"}"#, #"{"entrypoint":"bin/codex"}"#])
    func unavailablePackageFallsBackToLegacyPath(_ manifest: String?) throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        if let manifest {
            _ = try directory.write(manifest, to: "codex-cli/codex-package.json")
        }
        let nonExecutable = try directory.write("", to: "codex-cli/bin/codex")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: nonExecutable.path)
        let legacy = try writeExecutable(in: directory, path: "codex")

        let installations = CodexPaths.resolveInstallations(environment: ["PATH": ""], bundledResourceURL: directory.url)
        #expect(installations.bundledPath == legacy.path)
        #expect(installations.globalPath == nil)
        try FileManager.default.removeItem(at: legacy)
        let missing = CodexPaths.resolveInstallations(environment: ["PATH": ""], bundledResourceURL: directory.url)
        #expect(missing.bundledPath == nil)
    }

    @Test func globalCLIStillTakesPriorityOverManifestEntrypoint() throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        _ = try directory.write(#"{"entrypoint":"bin/codex"}"#, to: "codex-cli/codex-package.json")
        let bundled = try writeExecutable(in: directory, path: "codex-cli/bin/codex")
        let global = try writeExecutable(in: directory, path: "global/codex")

        let installations = CodexPaths.resolveInstallations(
            environment: ["PATH": global.deletingLastPathComponent().path],
            bundledResourceURL: directory.url
        )
        #expect(installations.globalPath == global.path)
        #expect(installations.bundledPath == bundled.path)
    }

    @Test(arguments: ["codex-cli/bin/codex", "codex"])
    func pathSymlinkToBundledCLIIsNotClassifiedAsGlobal(_ target: String) throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        _ = try directory.write(#"{"entrypoint":"bin/codex"}"#, to: "codex-cli/codex-package.json")
        let bundled = try writeExecutable(in: directory, path: "codex-cli/bin/codex")
        _ = try writeExecutable(in: directory, path: "codex")
        let link = directory.url.appendingPathComponent("global/codex")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory.url.appendingPathComponent(target))

        let installations = CodexPaths.resolveInstallations(
            environment: ["PATH": link.deletingLastPathComponent().path],
            bundledResourceURL: directory.url
        )
        #expect(installations.globalPath == nil)
        #expect(installations.bundledPath == bundled.path)
    }

    private func writeExecutable(in directory: TestDirectory, path: String) throws -> URL {
        let url = try directory.write("#!/bin/sh\nexit 0\n", to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
