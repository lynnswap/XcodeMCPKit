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

    @Test func runtimeOnlyArraysPreserveFieldsAndOptionalPaths() async throws {
        let fixture = NativeWorkspaceSnapshotFixture()
        let list = try await ABIRuntime.shared.object(fixture).method(
            named: "list() -> Swift.Array<XcodeMCPNativeRuntimeTests.NativeWorkspaceSnapshotEntry>",
            as: (() -> NativeSwiftValue).self)
        let snapshot = try unsafe list.unsafeInvoke()
        try snapshot.withCopy { value in
            let entries = try #require(value as? [Any])
            #expect(entries.count == 2)
            for (index, entry) in entries.enumerated() {
                let fields = Mirror(reflecting: entry).children
                let identifier = try #require(fields.first { $0.label == "identifier" }?.value as? String)
                let pathField = try #require(fields.first { $0.label == "path" })
                let path = try #require(pathField.value as? String?)
                #expect(identifier == "workspace-\(index)")
                #expect(path == (index == 0 ? "/tmp/Example.xcworkspace" : nil))
            }
        }
    }
}

private final class AnalyticsFixtureLocator: NSObject {}

public struct NativeWorkspaceSnapshotEntry {
    let identifier: String
    let path: String?
}

public final class NativeWorkspaceSnapshotFixture: NSObject {
    @inline(never)
    public func list() -> [NativeWorkspaceSnapshotEntry] {
        [
            NativeWorkspaceSnapshotEntry(identifier: "workspace-0", path: "/tmp/Example.xcworkspace"),
            NativeWorkspaceSnapshotEntry(identifier: "workspace-1", path: nil),
        ]
    }
}

@inline(never)
@concurrent
public func nativeAnalyticsValueFixture(_ boolean: Bool?, _ string: String?, _ integer: Int?) async -> [String: Any] {
    await Task.yield()
    return ["boolean": boolean.map(String.init) ?? "nil", "string": string ?? "nil", "integer": integer.map(String.init) ?? "nil"]
}
