import Testing
@testable import XcodeMCPNativeRuntime

@Suite
@MainActor
struct NativePreviewLocationTests {
    @Test func unicodePrefixUsesMacroByteCoordinates() throws {
        let source = "import SwiftUI\n/* 🌸 */ #Preview { Text(\"A\") }\n"
        #expect(try NativePreviewCorrection.registryColumn(in: source, line: 2, utf16Column: 9) == 12)
    }

    @Test func changedSourceCannotUseStaleCoordinates() {
        #expect(throws: NativeRuntimeError.self) {
            try NativePreviewCorrection.registryColumn(in: "#Preview {}", line: 1, utf16Column: 100)
        }
    }
}
