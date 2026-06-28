import Testing
import XcodeMCPCore
import XcodeMCPProcessRuntime
@testable import XcodeMCPProxyKit


@Suite
struct XcodeMCPProxyServerBuildInfoTests {
    @Test func proxyServerStartupSummaryUsesReadableSections() throws {
        let config = ProxyConfig(
            listenHost: "localhost",
            listenPort: 8765,
            upstreamCommand: MCPBridgeInvocation.defaultMCPBridge.command,
            upstreamArgs: MCPBridgeInvocation.defaultMCPBridge.arguments,
            upstreamProcessCount: 2,
            maxBodyBytes: 1_048_576,
            requestTimeout: 300,
            autoApproveXcodeDialog: true
        )
        let target = XcodeProcessTarget(
            processID: 9004,
            appPath: "/Applications/Xcode.app",
            developerDir: "/Applications/Xcode.app/Contents/Developer",
            mcpbridgePath: "/Applications/Xcode.app/Contents/Developer/usr/bin/mcpbridge",
            xcodeVersion: "26.0"
        )

        let summary = XcodeMCPProxyServer.startupSummary(
            displayHost: "localhost",
            port: 8765,
            config: config,
            xcodeTargets: [target]
        )

        #expect(summary == """
        XcodeMCPProxyKit \(XcodeMCPProxyServer.productMetadata.version)

        Server
          URL: http://localhost:8765/mcp
          Upstream processes: 2
          Upstream processes per Xcode: 2
          Auto approve: enabled

        Xcode
          App: /Applications/Xcode.app
          PID: 9004
          DocumentationSearch: pending
        """)
    }
}
