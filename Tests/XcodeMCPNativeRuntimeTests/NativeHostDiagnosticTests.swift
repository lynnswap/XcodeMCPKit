import Testing
@testable import XcodeMCPNativeRuntime

struct NativeHostDiagnosticTests {
    @Test(arguments: [
        (NativeHostDiagnostic.Level.error, "[xcode-mcp-native-host] ERROR : First\n[xcode-mcp-native-host] ERROR : Second"),
        (.warning, "[xcode-mcp-native-host] WARNING : First\n[xcode-mcp-native-host] WARNING : Second"),
    ])
    func multilineDiagnosticsKeepTheirDeclaredLevel(input: (level: NativeHostDiagnostic.Level, expected: String)) {
        #expect(NativeHostDiagnostic.formattedMessage("First\nSecond", level: input.level) == input.expected)
    }
}
