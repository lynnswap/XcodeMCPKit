import Testing
import XcodeMCPRuntime

@Suite
struct MCPProtocolVersionTests {
    @Test func currentRemainsStable() {
        #expect(MCP.ProtocolVersion.current == "2025-06-18")
    }

    @Test func supportRemainsCurrentOnly() {
        #expect(MCP.ProtocolVersion.isSupported(MCP.ProtocolVersion.current))
        #expect(MCP.ProtocolVersion.isSupported("2024-11-05") == false)
        #expect(MCP.ProtocolVersion.isSupported("unknown") == false)
    }
}
