import Foundation
import Testing

@testable import XcodeMCPProxyKit

@Suite
struct CLIUsageContractTests {
    @Test func adapterUsageRemainsStable() {
        let usage = XcodeMCPProxyCLICommand.usage(
            discoveryFileURL: URL(fileURLWithPath: "/tmp/xcode-mcp-contract/endpoint.json")
        )

        #expect(
            usage == """
            Usage:
              xcode-mcp-proxy [options]

            Description:
              STDIO compatibility adapter that forwards MCP traffic to a running xcode-mcp-proxy-server (Streamable HTTP).

            Options:
              --request-timeout seconds  Request timeout (default: 300, 0 disables)
              --url url                  Explicit upstream URL (default: env/discovery/http://localhost:8765/mcp)
              --version                  Show version
              -h, --help                 Show help

            Environment:
              XCODE_MCP_PROXY_ENDPOINT   Upstream proxy URL (overrides discovery)

            Notes:
              - Proxy server: xcode-mcp-proxy-server
              - --config is only supported by xcode-mcp-proxy-server
              - Discovery file: /tmp/xcode-mcp-contract/endpoint.json
            """
        )
    }

    @Test func serverUsageRemainsStable() {
        #expect(
            XcodeMCPProxyServerCommand.serverUsage() == """
            Usage:
              xcode-mcp-proxy-server [options]

            Options:
              --listen host:port
              --host host
              --port port
              --config path
              --auto-approve
              --upstream-processes n
              --refresh-code-issues-mode proxy|upstream
              --force-restart
              --dry-run
              --version
              -h, --help

            Notes:
              - Starts the Streamable HTTP proxy server (and spawns xcrun mcpbridge as upstream processes).
              - HTTP-capable clients should connect directly; xcode-mcp-proxy is the STDIO compatibility adapter.
              - Default listen: localhost:8765 (override via --listen / --host / --port or env LISTEN/HOST/PORT).
              - --auto-approve opt-in enables automatic approval of the Xcode permission dialog.
              - Initialize config path: --config or env MCP_XCODE_CONFIG
              - When the listen port is already in use, rerun with --force-restart to terminate an existing xcode-mcp-proxy-server.
            """
        )
    }
}
