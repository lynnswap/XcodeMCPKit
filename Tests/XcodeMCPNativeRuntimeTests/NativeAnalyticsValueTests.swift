import ABIBridge
import Foundation
import Testing
@testable import XcodeMCPNativeRuntime

@Suite
@MainActor
struct NativeAnalyticsValueTests {
    @Test(arguments: [Bool?.none, .some(false), .some(true)], [Int?.none, .some(0), .some(7)])
    func standardOptionalValuesUseTheCompilerKnownABI(boolean: Bool?, integer: Int?) async throws {
        let executable = try #require(Bundle(for: AnalyticsFixtureLocator.self).executableURL)
        let function = try await ABIRuntime.shared.swiftFunction(
            named: "XcodeMCPNativeRuntimeTests.nativeAnalyticsValueFixture(Swift.Optional<Swift.Bool>, Swift.Optional<Swift.String>, Swift.Optional<Swift.Int>) async -> Swift.Dictionary<Swift.String, Any>",
            as: (@concurrent (NativeAnalyticsBoolean, String?, NativeAnalyticsInteger) async -> NativeAnalyticsDictionary).self,
            in: .path(executable), loading: .loadedOnly)
        for string: String? in [nil, String(repeating: "retained text", count: 128)] {
            let output = try unsafe await function.unsafeInvoke(NativeAnalyticsBoolean(value: boolean), string,
                NativeAnalyticsInteger(value: integer)).value
            #expect(output["boolean"] as? String == (boolean.map(String.init) ?? "nil"))
            #expect(output["integer"] as? String == (integer.map(String.init) ?? "nil"))
            #expect(output["string"] as? String == (string ?? "nil"))
        }
    }
}

private final class AnalyticsFixtureLocator: NSObject {}

@inline(never)
@concurrent
public func nativeAnalyticsValueFixture(_ boolean: Bool?, _ string: String?, _ integer: Int?) async -> [String: Any] {
    await Task.yield()
    return ["boolean": boolean.map(String.init) ?? "nil", "string": string ?? "nil", "integer": integer.map(String.init) ?? "nil"]
}
