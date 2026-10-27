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
        let query = NativeCrashQuery(bundleIdentifier: "example.App", platformIdentifier: "com.apple.platform.macosx",
            uploadPlatformIdentifier: "com.apple.platform.iphoneos", appVersion: nil, isBeta: nil,
            timePeriod: "last14Days", pageIndex: 0, pageSize: 25, collectsAllPages: true)
        let key = query.json(issueID: nil)
        let store = NativeCrashStore(root: context.crashCacheRoot.appending(component: "SourceSnapshots"))
        let originalTime = "2024-01-01T00:00:00Z"
        let saved = try store.write(.object(["points": .array([])]), key: key, fetchedAt: originalTime)
        let bytes = try Data(contentsOf: URL(fileURLWithPath: saved.path))
        let input: JSONValue = .object([
            "workspaceIdentifier": .string("unavailable-workspace"), "bundle_id": .string("example.App"),
            "platform": .string("macOS"), "upload_platform": .string("iOS"), "source": .string(source),
        ])
        let correction = NativeCrashToolCorrection(installation: installation)
        let result = try await execute(.sync, input: input, correction: correction, context: context)
        guard case .string(let metadataPath) = result["metadataPath"] else {
            Issue.record("Sync must retain its source metadata without returning all records")
            return
        }
        let metadata = try NativeCrashStore.object(Data(contentsOf: URL(fileURLWithPath: metadataPath)))
        let provenance = try nativeTestField(.object(metadata), "provenance")
        #expect(try nativeTestField(provenance, "source") == .string("cache"))
        #expect(try nativeTestField(provenance, "fetchedAt") == .string(originalTime))
        guard case .array(let errors) = result["errors"] else { throw FixtureError.missingField }
        if source == "cache" { #expect(errors.isEmpty) }
        else {
            #expect(errors.count == 1)
            #expect(try nativeTestField(try #require(errors.first), "operation") == .string("download"))
            #expect(try nativeTestField(try #require(errors.first), "message") == .string("Xcode's product manager is unavailable"))
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: saved.path)) == bytes)

        let read = try await execute(.read, input: .object(["bundle_id": .string("example.App"),
            "platform": .string("macOS"), "upload_platform": .string("iOS")]),
            correction: correction, context: context)
        #expect(read["changes"] == .array([]))
        guard case .string = read["checkpoint"] else {
            Issue.record("A locally completed empty read must issue a checkpoint")
            return
        }
        #expect(try nativeTestField(.object(read), "cacheInfo", "readComplete") == .bool(true))
    }

    @Test func aRecoveredSampleIsImportedWithoutReplacingTheCachedDistribution() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let primaryLogs = root.appending(component: "primary-logs")
        let recoveredLogs = root.appending(component: "recovered-logs")
        try FileManager.default.createDirectory(at: primaryLogs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: recoveredLogs, withIntermediateDirectories: true)
        let query = NativeCrashQuery(bundleIdentifier: "example.App", platformIdentifier: "com.apple.platform.iphoneos",
            uploadPlatformIdentifier: "com.apple.platform.iphoneos", appVersion: nil, isBeta: nil,
            timePeriod: "last14Days", pageIndex: 0, pageSize: 25)
        let distribution: JSONValue = .object(["body": .object(["timeSeriesDistribution": .object([
            "timeDistributionMetaDatas": .array([.object(["timePeriod": .string("last14Days"),
                "uniqueDeviceCountForTimePeriod": .number(.int(9)), "timeDistributionDatas": .array([])])]),
        ])])])
        let text = "Exception Type: EXC_BAD_ACCESS\nThread 0 Crashed:\n0   Fixture.crash()\n"
        try Data(text.utf8).write(to: recoveredLogs.appending(component: "sample.crash"))
        let failure: JSONValue = .object(["operation": .string("organizerIssueRefresh"), "message": .string("Refresh failed")])
        let loaded = NativeCrashData.Loaded(value: .object(["distribution": distribution, "logDirectory": .string(primaryLogs.path)]),
            source: "cache", fetchedAt: "2024-01-01T00:00:00Z",
            recovery: NativeCrashData.Fetched(value: .object(["cachedDistribution": distribution,
                "sampleFreshness": .string("unverifiedSavedSamples"), "logDirectory": .string(recoveredLogs.path)]),
                fetchedAt: nil, source: "organizerCache", errors: [failure], isComplete: false), errors: [failure], isComplete: true)
        let snapshot = try NativeCrashToolCorrection.snapshot(collection: .logs, query: query, issueID: "stable-issue", loaded: loaded)
        #expect(try nativeTestField(snapshot.metadata, "provenance", "source") == .string("cache"))
        #expect(try nativeTestField(snapshot.metadata, "provenance", "fetchedAt") == .string("2024-01-01T00:00:00Z"))
        #expect(try nativeTestField(snapshot.metadata, "timeSeries", "uniqueDeviceCountForTimePeriod") == .number(.int(9)))
        #expect(try nativeTestField(snapshot.metadata, "recovery", "provenance", "fetchedAt") == .null)
        #expect(try nativeTestField(snapshot.metadata, "recovery", "native", "sampleFreshness") == .string("unverifiedSavedSamples"))
        #expect(try nativeTestField(snapshot.metadata, "importProvenance", "source") == .string("organizerCache"))
        #expect(try nativeTestField(snapshot.metadata, "importProvenance", "fetchedAt") == .null)
        #expect(!snapshot.isComplete)

        let store = try NativeCrashSyncStore(root: root.appending(component: "cache"))
        let sync = try await store.synchronize(snapshot, maxRecords: 100, maxBytes: 64 * 1024 * 1024)
        #expect(try nativeTestField(sync, "cacheInfo", "sourceComplete") == .bool(false))
        let read = try await store.readChanges(collection: .logs, query: snapshot.query, checkpoint: nil,
            limit: 25, maxBytes: 256 * 1024, order: .observedNewestFirst)
        guard case .array(let changes) = try nativeTestField(read, "changes") else { throw FixtureError.missingField }
        #expect(changes.count == 1)
        guard case .string(let path) = try nativeTestField(try #require(changes.first), "path") else { throw FixtureError.missingField }
        #expect(try String(contentsOfFile: path, encoding: .utf8) == text)
    }

    private func execute(_ kind: NativeCrashToolCorrection.Kind, input: JSONValue,
                         correction: NativeCrashToolCorrection, context: NativeToolContext) async throws -> [String: JSONValue] {
        let stream = try correction.execute(kind, input: NativeCrashStore.encode(input), context: context)
        var events: [[String: JSONValue]] = []
        for await event in stream { events.append(try NativeCrashStore.object(event)) }
        let event = try #require(events.last)
        #expect(event["type"] == .string("completed"))
        guard case .object(let result) = event["data"] else { throw FixtureError.missingField }
        return result
    }

    private enum FixtureError: Error { case missingField }
}
