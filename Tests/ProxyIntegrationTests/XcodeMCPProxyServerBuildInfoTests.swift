import Testing
import XcodeMCPKit
@testable import XcodeMCPProxyKit
import XcodeMCPProxyRuntime


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
            xcodeMode: .gui,
            xcodeTargets: [
                ProxyRuntimeInventorySnapshot.XcodeTarget(
                    processID: target.processID,
                    appPath: target.appPath,
                    mcpBridgePath: target.mcpbridgePath
                )
            ]
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

    @Test func headlessStartupSummaryNamesTheServiceAndUpstreamDocumentationOwner() {
        let config = ProxyConfig(
            listenHost: "localhost",
            listenPort: 8765,
            upstreamCommand: MCPBridgeInvocation.defaultMCPBridge.command,
            upstreamArgs: MCPBridgeInvocation.defaultMCPBridge.arguments,
            maxBodyBytes: 1_048_576,
            requestTimeout: 300,
            autoApproveXcodeDialog: true
        )

        let summary = XcodeMCPProxyServer.startupSummary(
            displayHost: "localhost",
            port: 8765,
            config: config,
            xcodeMode: .headless,
            xcodeTargets: []
        )

        #expect(summary == """
        XcodeMCPProxyKit \(XcodeMCPProxyServer.productMetadata.version)

        Server
          URL: http://localhost:8765/mcp
          Upstream processes: 1
          Auto approve: enabled

        Xcode
          Mode: headless
          Status: Xcode Service
          DocumentationSearch: upstream
        """)
    }
}
