import Foundation
import Testing
import XcodeMCPNativeRuntime

@Suite
struct NativeGUIMessageCapabilitiesTests {
    private static let initialization = Data(#"{"initializeSession":{"context":{"sessionID":"00000000-0000-0000-0000-000000000000","clientInfo":{"name":"Test Client","version":"1"}}}}"#.utf8)
    @Test func cancellationSupportComesFromTheNativeEnumContract() throws {
        #expect(try NativeGUIMessageCapabilities(oneWayType: CancellableMessages.self, initializingWith: Self.initialization).supportsToolCancellation)
        #expect(try !NativeGUIMessageCapabilities(oneWayType: CompletionOnlyMessages.self, initializingWith: Self.initialization).supportsToolCancellation)
    }

    @Test func anUnrelatedDecoderFailureIsNotMisreportedAsUnsupportedCancellation() {
        #expect(throws: DecoderFailure.failed) {
            try NativeGUIMessageCapabilities(oneWayType: BrokenMessages.self, initializingWith: Self.initialization)
        }
    }
}

private struct EmptyContext: Decodable {}
private enum CancellableMessages: Decodable {
    case initializeSession(context: EmptyContext)
    case cancelToolCall(name: String, progressToken: String?)
}
private enum CompletionOnlyMessages: Decodable {
    case initializeSession(context: EmptyContext)
}
private enum DecoderFailure: Error { case failed }
private struct BrokenMessages: Decodable {
    init(from decoder: any Decoder) throws { throw DecoderFailure.failed }
}
