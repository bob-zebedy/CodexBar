import Foundation
import Testing

struct CodexVersionAndProxyTests {
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
        #expect(CodexCLIVersionReader.isVersion(version, atLeast: minimum) == expected)
    }

    @Test(arguments: ["unknown", "0.150", "0.150.x", "0.150.0-", "0.150.0-alpha..1"])
    func unrecognizedVersionHasNoOrdering(_ version: String) {
        #expect(CodexCLIVersionReader.isVersion(version, atLeast: "0.150.0") == nil)
    }

    @Test func installedUpgradeDoesNotReplaceActualRunningVersion() {
        let item = CodexCLIVersionItem(source: .global, path: "/new/codex", version: "0.151.0")
        let connection = CodexCLIConnectionInfo(source: .global, executablePath: "/running/codex", version: "0.149.0", openedAt: TestFixtures.now)
        let display = CodexCLIVersionDisplay(item: item, connection: connection)
        #expect(display.displayVersion == "0.149.0")
        #expect(display.path == "/running/codex")
        #expect(display.newerInstalledVersion == "0.151.0")
    }

    @Test func explicitMissingCLISourceDoesNotSilentlyFallback() throws {
        let installations = CodexCLIInstallations(globalPath: nil, bundledPath: "/app/codex")
        #expect(try CodexCLIResolver.command(from: installations).source == .bundled)
        #expect(throws: (any Error).self) {
            try CodexCLIResolver.command(from: installations, source: .global)
        }
    }

    @Test func codexHomeUsesExplicitEnvironmentAndTrimsWhitespace() {
        #expect(CodexCLIResolver.codexHomeDirectory(environment: ["CODEX_HOME": " /tmp/custom ", "HOME": "/tmp/home"]).path == "/tmp/custom")
        #expect(CodexCLIResolver.codexHomeDirectory(environment: ["CODEX_HOME": " ", "HOME": "/tmp/home"]).path == "/tmp/home/.codex")
    }

    @Test(arguments: ["https://proxy.example", "host/path", "user@host", "host?query", "host#fragment", "host name", "[invalid]", "fe80::1%en0"])
    func proxyRejectsAmbiguousHostInput(_ host: String) {
        let configuration = CodexProxyConfiguration(host: host, port: "8080")
        #expect(throws: (any Error).self) { try configuration.validated() }
    }

    @Test(arguments: ["0", "65536", "-1", "abc", "1.5"])
    func proxyRejectsInvalidPorts(_ port: String) {
        #expect(throws: (any Error).self) { try CodexProxyConfiguration(host: "localhost", port: port).validated() }
    }

    @Test func proxyNormalizesIPv6AndPortAndEncodesCredentials() throws {
        let configuration = CodexProxyConfiguration(isEnabled: true, transport: .https, host: " ::1 ", port: " 08080 ", usesAuthentication: true, username: "user@name")
        let validated = try configuration.validated()
        #expect(validated.host == "[::1]")
        #expect(validated.port == "8080")
        let environment = try configuration.environment(overriding: ["PATH": "/bin", "NO_PROXY": "*"], password: "p:@/#")
        for key in ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "WS_PROXY", "WSS_PROXY"] {
            #expect(environment[key] == "https://user%40name:p%3A%40%2F%23@[::1]:8080")
            #expect(environment[key.lowercased()] == environment[key])
        }
        #expect(environment["NO_PROXY"] == "localhost,127.0.0.1,::1")
        #expect(environment["PATH"] == "/bin")
    }

    @Test func disabledInvalidProxyPreservesInheritedEnvironment() throws {
        let base = ["HTTPS_PROXY": "http://inherited:80", "NO_PROXY": "example.com"]
        #expect(try CodexProxyConfiguration().environment(overriding: base, password: "") == base)
    }

    @Test(arguments: ["", "name:password", "name\n"])
    func proxyRejectsInvalidAuthenticationUsernames(_ username: String) {
        let configuration = CodexProxyConfiguration(host: "localhost", port: "80", usesAuthentication: true, username: username)
        #expect(configuration.validationIssues.contains { $0.field == .username })
    }
}
