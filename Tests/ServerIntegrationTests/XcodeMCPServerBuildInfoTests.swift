import XcodeMCPServerRuntimeContract
@testable import XcodeMCPCore
import Testing
import XcodeMCPKit
@testable import XcodeMCPServerKit
import XcodeMCPServerRuntime

@Suite
struct XcodeMCPServerBuildInfoTests {
    @Test func startupSummaryDescribesHeadlessOperation() {
        let summary = XcodeMCPServer.startupSummary(displayHost: "localhost", port: 8765)
        #expect(summary == """
        XcodeMCPServerKit \(XcodeMCPServer.productMetadata.version)

        Server
          URL: http://localhost:8765/mcp
          Xcode mode: headless (saved project files)
        """)
    }
}
