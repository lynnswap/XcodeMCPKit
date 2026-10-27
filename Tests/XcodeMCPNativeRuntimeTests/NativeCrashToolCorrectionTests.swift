import Foundation
import Testing
import XcodeMCPWire
@testable import XcodeMCPNativeRuntime

@Suite
@MainActor
struct NativeCrashToolCorrectionTests {
    @Test(arguments: ["cache", "networkWithCacheFallback"])
    func explicitCachedQueryDoesNotRequireTheProductInventory(source: String) async throws {
        try #require(NSClassFromString("IDEProductManager") == nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = root.appending(path: "Xcode.app/Contents")
        try FileManager.default.createDirectory(at: contents.appending(path: "Frameworks/IDEFoundation.framework"),
                                               withIntermediateDirectories: true)
        let installation = try NativeXcodeInstallation(developerDirectory: contents.appending(component: "Developer"))
        let artifacts = root.appending(component: "request")
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: false)
        let context = NativeToolContext(artifactsDirectory: artifacts, artifactsRoot: root, conversationID: "crash-cache")
        let key: JSONValue = .object([
            "bundleId": .string("example.App"), "platform": .string("com.apple.platform.macosx"),
            "uploadPlatform": .string("com.apple.platform.iphoneos"), "appVersion": .null, "isBeta": .null,
            "timePeriod": .string("last14Days"), "allPages": .bool(false),
            "page": .number(.int(0)), "pageSize": .number(.int(25)),
        ])
        let store = NativeCrashStore(root: root.appending(component: "CrashAnalytics"))
        let originalTime = "2024-01-01T00:00:00Z"
        let saved = try store.write(.object(["points": .array([])]), key: key, fetchedAt: originalTime)
        let bytes = try Data(contentsOf: URL(fileURLWithPath: saved.path))
        let input: JSONValue = .object([
            "workspaceIdentifier": .string("unavailable-workspace"), "bundle_id": .string("example.App"),
            "platform": .string("macOS"), "upload_platform": .string("iOS"),
            "page": .number(.int(0)), "source": .string(source),
        ])
        let correction = NativeCrashToolCorrection(installation: installation)
        let stream = try correction.execute(.topIssues, input: NativeCrashStore.encode(input), context: context)
        var events: [[String: JSONValue]] = []
        for await event in stream { events.append(try NativeCrashStore.object(event)) }

        let event = try #require(events.last)
        guard case .object(let result) = event["data"], case .object(let provenance) = result["provenance"],
              case .array(let errors) = result["errors"] else {
            Issue.record("A cached crash response must preserve its structured result")
            return
        }
        #expect(event["type"] == .string("completed"))
        #expect(result["query"] == key)
        #expect(result["issues"] == .array([]))
        #expect(provenance["source"] == .string("cache"))
        #expect(provenance["fetchedAt"] == .string(originalTime))
        if source == "cache" {
            #expect(result["status"] == .string("complete"))
            #expect(errors.isEmpty)
        } else {
            #expect(result["status"] == .string("partial"))
            #expect(errors.count == 1)
            guard case .object(let failure) = try #require(errors.first) else { return }
            #expect(failure["operation"] == .string("download"))
            #expect(failure["message"] == .string("Xcode's product manager is unavailable"))
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: saved.path)) == bytes)
    }

    @Test func aRecoveredSampleIsSavedWithoutReplacingTheCachedDistribution() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = root.appending(path: "Xcode.app/Contents")
        try FileManager.default.createDirectory(at: contents.appending(path: "Frameworks/IDEFoundation.framework"),
                                               withIntermediateDirectories: true)
        let installation = try NativeXcodeInstallation(developerDirectory: contents.appending(component: "Developer"))
        let query = NativeCrashQuery(bundleIdentifier: "example.App", platformIdentifier: "com.apple.platform.iphoneos",
            uploadPlatformIdentifier: "com.apple.platform.iphoneos", appVersion: nil, isBeta: nil,
            timePeriod: "last14Days", pageIndex: 0, pageSize: 25)
        let distribution: JSONValue = .object(["body": .object(["timeSeriesDistribution": .object([
            "timeDistributionMetaDatas": .array([.object(["timePeriod": .string("last14Days"),
                "uniqueDeviceCountForTimePeriod": .number(.int(9)), "timeDistributionDatas": .array([])])]),
        ])])])
        let text = "Exception Type: EXC_BAD_ACCESS\nThread 0 Crashed:\n0   Fixture.crash()\n"
        let failure: JSONValue = .object(["operation": .string("organizerIssueRefresh"), "message": .string("Refresh failed")])
        let loaded = NativeCrashData.Loaded(value: .object(["distribution": distribution, "logs": .array([])]),
            source: "cache", fetchedAt: "2024-01-01T00:00:00Z",
            recovery: NativeCrashData.Fetched(value: .object(["cachedDistribution": distribution,
                "sampleFreshness": .string("unverifiedSavedSamples"),
                "logs": .array([.object(["data": .string(Data(text.utf8).base64EncodedString())])])]),
                fetchedAt: nil, source: "organizerCache", errors: [failure], isComplete: false), errors: [failure])

        let correction = NativeCrashToolCorrection(installation: installation)
        let response = try correction.response(.logs, query: query, loaded: loaded, issueID: "stable-issue", directory: root)

        #expect(try nativeTestField(.object(response), "provenance", "source") == .string("cache"))
        #expect(try nativeTestField(.object(response), "provenance", "fetchedAt") == .string("2024-01-01T00:00:00Z"))
        #expect(try nativeTestField(.object(response), "timeSeries", "uniqueDeviceCountForTimePeriod") == .number(.int(9)))
        #expect(response["sampleLogCount"] == .number(.int(0)))
        #expect(response["errors"] == .array([failure]))
        let recovered = try nativeTestField(.object(response), "recovery")
        #expect(try nativeTestField(recovered, "status") == .string("partial"))
        #expect(try nativeTestField(recovered, "provenance", "source") == .string("organizerCache"))
        #expect(try nativeTestField(recovered, "provenance", "fetchedAt") == .null)
        #expect(try nativeTestField(recovered, "native", "sampleFreshness") == .string("unverifiedSavedSamples"))
        #expect(try nativeTestField(recovered, "sampleLogCount") == .number(.int(1)))
        guard case .array(let logs) = try nativeTestField(recovered, "logs"),
              case .string(let path) = try nativeTestField(try #require(logs.first), "path") else {
            Issue.record("Recovery must expose a saved sample path")
            return
        }
        #expect(try String(contentsOfFile: path, encoding: .utf8) == text)
    }
}
