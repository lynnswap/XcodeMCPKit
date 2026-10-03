import XcodeMCPProxyRuntimeContract
@testable import XcodeMCPCore
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

            maxBodyBytes: 1_048_576,
            requestTimeout: 300,
            autoApproveXcodeDialog: true
        )
        let target = ProxyRuntimeInventorySnapshot.XcodeTarget(
            processID: 9004, appPath: "/Applications/Xcode.app"
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
          Auto approve: enabled

        Xcode
          App: /Applications/Xcode.app
          PID: 9004
        """)
    }

    @Test func startupSummaryRemainsAvailableWithoutGUIXcode() {
        let config = ProxyConfig(
            listenHost: "localhost",
            listenPort: 8765,

            maxBodyBytes: 1_048_576,
            requestTimeout: 300,
            autoApproveXcodeDialog: true
        )

        let summary = XcodeMCPProxyServer.startupSummary(
            displayHost: "localhost",
            port: 8765,
            config: config,
            xcodeTargets: []
        )

        #expect(summary == """
        XcodeMCPProxyKit \(XcodeMCPProxyServer.productMetadata.version)

        Server
          URL: http://localhost:8765/mcp
          Auto approve: enabled

        Xcode
          GUI: not detected
        """)
    }
}
