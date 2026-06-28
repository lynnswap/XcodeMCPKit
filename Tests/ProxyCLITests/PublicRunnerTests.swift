import Foundation
import Testing
import XcodeMCPProxyKit

@Suite
struct PublicRunnerTests {
    @Test func adapterDiscoveryFileURLHonorsProxyDiscoveryEnvironment() throws {
        let explicitURL = XcodeMCPProxyAdapterEndpointResolver.discoveryFileURL(
            environment: [
                "XCODE_MCP_PROXY_DISCOVERY_FILE": "/tmp/runner-contract/endpoint.json",
                "XCODE_MCP_PROXY_CACHE_ROOT": "/tmp/ignored-runner-cache",
            ]
        )
        #expect(explicitURL == URL(fileURLWithPath: "/tmp/runner-contract/endpoint.json"))

        let cacheRootURL = XcodeMCPProxyAdapterEndpointResolver.discoveryFileURL(
            environment: [
                "XCODE_MCP_PROXY_CACHE_ROOT": "/tmp/runner-cache",
            ]
        )
        #expect(
            cacheRootURL == URL(fileURLWithPath: "/tmp/runner-cache")
                .appendingPathComponent("XcodeMCPProxy", isDirectory: true)
                .appendingPathComponent("endpoint.json")
        )
    }

    @Test func serverRunnerPrintsVersionThroughPublicAPI() async throws {
        let output = CapturedLines()
        let errors = CapturedLines()

        let exitCode = await XcodeMCPProxyServer.run(
            arguments: ["xcode-mcp-proxy-server", "--version"],
            environment: [:],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )

        #expect(exitCode == 0)
        #expect(output.snapshot() == ["xcode-mcp-proxy-server \(XcodeMCPProxyServer.productMetadata.version)"])
        #expect(errors.snapshot().isEmpty)
    }

    @Test func stdioAdapterRunnerRoutesValidationErrorsToStderr() async throws {
        let output = CapturedLines()
        let errors = CapturedLines()

        let exitCode = await XcodeMCPProxyStdioAdapter.run(
            arguments: [
                "xcode-mcp-proxy",
                "--url", "http://localhost:8765/mcp",
                "--stdio",
            ],
            environment: [:],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )

        #expect(exitCode == 1)
        #expect(output.snapshot().isEmpty)
        let errorLines = errors.snapshot()
        #expect(errorLines.contains("Use either --url or --stdio (not both)."))
        #expect(errorLines.contains { $0.contains("Usage:") })
    }

    @Test func installerRunnerPrintsVersionThroughPublicAPI() throws {
        let output = CapturedLines()
        let errors = CapturedLines()

        let exitCode = XcodeMCPProxyInstaller.run(
            arguments: ["xcode-mcp-proxy-install", "--version"],
            environment: [:],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )

        #expect(exitCode == 0)
        #expect(output.snapshot() == ["xcode-mcp-proxy-install \(XcodeMCPProxyServer.productMetadata.version)"])
        #expect(errors.snapshot().isEmpty)
    }
}
