import XcodeMCPProxyRuntimeContract
@testable import XcodeMCPCore
import Testing
import XcodeMCPKit
@testable import XcodeMCPProxyKit
import XcodeMCPProxyRuntime

@Suite
struct XcodeMCPProxyServerBuildInfoTests {
    @Test func startupSummaryDescribesHeadlessOperation() {
        let summary = XcodeMCPProxyServer.startupSummary(displayHost: "localhost", port: 8765)
        #expect(summary == """
        XcodeMCPProxyKit \(XcodeMCPProxyServer.productMetadata.version)

        Server
          URL: http://localhost:8765/mcp
          Xcode mode: headless (saved project files)
        """)
    }
}
