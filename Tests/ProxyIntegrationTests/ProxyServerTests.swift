import Foundation
import Testing

@testable import XcodeMCPProxy

struct ProxyServerTests {
    @Test func firstXcrunToolSelectionTreatsLogAsFlagWithoutValue() {
        let selection = ProxyServer.firstXcrunToolSelection(
            from: ["--sdk", "macosx", "--log", "mcpbridge", "--some-flag"]
        )

        #expect(selection?.toolName == "mcpbridge")
        #expect(selection?.preToolArguments == ["--sdk", "macosx", "--log"])
    }

    @Test func additionalPermissionDialogExecutableCandidatesKeepXcrunPathWhenToolResolutionFails() {
        let config = ProxyConfig(
            listenHost: "localhost",
            listenPort: 0,
            upstreamCommand: "/usr/bin/xcrun",
            upstreamArgs: ["--foo"],
            maxBodyBytes: 1_048_576,
            requestTimeout: 300
        )

        let candidates = ProxyServer.additionalPermissionDialogExecutableCandidates(config: config)

        #expect(candidates.contains("/usr/bin/xcrun"))
    }

    @Test func additionalPermissionDialogExecutableCandidatesUseConfiguredXcrunCommand() throws {
        let fixture = try makeXcrunFixture()
        defer { fixture.cleanup() }

        let config = ProxyConfig(
            listenHost: "localhost",
            listenPort: 0,
            upstreamCommand: fixture.wrapperPath,
            upstreamArgs: ["--sdk", "macosx", "mcpbridge"],
            maxBodyBytes: 1_048_576,
            requestTimeout: 300
        )

        let candidates = ProxyServer.additionalPermissionDialogExecutableCandidates(config: config)

        #expect(candidates.contains(fixture.wrapperPath))
        #expect(candidates.contains(fixture.toolPath))
    }

    @Test func additionalPermissionDialogExecutableCandidatesUseConfiguredXcrunFromUpstreamArgs() throws {
        let fixture = try makeXcrunFixture()
        defer { fixture.cleanup() }

        let config = ProxyConfig(
            listenHost: "localhost",
            listenPort: 0,
            upstreamCommand: "/bin/echo",
            upstreamArgs: [fixture.wrapperPath, "--log", "mcpbridge"],
            maxBodyBytes: 1_048_576,
            requestTimeout: 300
        )

        let candidates = ProxyServer.additionalPermissionDialogExecutableCandidates(config: config)

        #expect(candidates.contains(fixture.wrapperPath))
        #expect(candidates.contains(fixture.toolPath))
    }

    @Test func executableLookupClientResolvesPathAndXcrunToolThroughInjectedClients() {
        let fileSystem = testDependency(of: FileSystemClient.self) {
            $0.isExecutableFile = { path in
                path == "/custom/bin/xcrun"
            }
        }
        let client = ExecutableLookupClient.live(
            environment: { ["PATH": "/usr/bin:/custom/bin"] },
            fileSystem: fileSystem,
            runCommand: { executablePath, arguments in
                #expect(executablePath == "/custom/bin/xcrun")
                #expect(arguments == ["--sdk", "macosx", "--find", "mcpbridge"])
                return "/custom/toolchain/mcpbridge\n"
            }
        )

        #expect(client.resolveExecutablePath("xcrun") == "/custom/bin/xcrun")
        #expect(
            client.resolveXcrunToolPath(
                "xcrun",
                "mcpbridge",
                ["--sdk", "macosx"]
            ) == "/custom/toolchain/mcpbridge"
        )
    }
}

private struct XcrunFixture {
    let wrapperPath: String
    let toolPath: String
    let directoryURL: URL

    func cleanup() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

private func makeXcrunFixture() throws -> XcrunFixture {
    let fileManager = FileManager.default
    let directoryURL = fileManager.temporaryDirectory
        .appendingPathComponent("xcode-mcp-proxy-xcrun-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

    let toolPath = directoryURL.appendingPathComponent("fake-mcpbridge").path
    let wrapperPath = directoryURL.appendingPathComponent("xcrun").path
    let script = """
    #!/bin/sh
    if [ "$1" = "--sdk" ]; then
      shift 2
    fi
    if [ "$1" = "--log" ]; then
      shift
    fi
    if [ "$1" = "--find" ] && [ "$2" = "mcpbridge" ]; then
      echo "\(toolPath)"
      exit 0
    fi
    exit 1
    """
    try script.write(to: URL(fileURLWithPath: wrapperPath), atomically: true, encoding: .utf8)
    try fileManager.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o755))],
        ofItemAtPath: wrapperPath
    )

    return XcrunFixture(
        wrapperPath: wrapperPath,
        toolPath: toolPath,
        directoryURL: directoryURL
    )
}
