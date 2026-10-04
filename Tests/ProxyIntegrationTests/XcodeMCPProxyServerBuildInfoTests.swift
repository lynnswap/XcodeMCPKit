import XcodeMCPProxyRuntimeContract
@testable import XcodeMCPCore
import Testing
import XcodeMCPKit
@testable import XcodeMCPProxyKit
import XcodeMCPProxyRuntime

@Suite
struct XcodeMCPProxyServerBuildInfoTests {
    @Test func proxyServerStartupSummaryUsesReadableSections() throws {
        let config = XcodeMCPProxyServerConfiguration(
            bindAddress: .init(host: "localhost", port: 8765),

            maxBodyBytes: 1_048_576,
            requestTimeout: .seconds(300)
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
          Agent access: automatically allowed

        Xcode
          App: /Applications/Xcode.app
          PID: 9004
        """)
    }

    @Test func startupSummaryRemainsAvailableWithoutGUIXcode() {
        let config = XcodeMCPProxyServerConfiguration(
            bindAddress: .init(host: "localhost", port: 8765),

            maxBodyBytes: 1_048_576,
            requestTimeout: .seconds(300)
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
          Agent access: automatically allowed

        Xcode
          GUI: not detected
        """)
    }
}
