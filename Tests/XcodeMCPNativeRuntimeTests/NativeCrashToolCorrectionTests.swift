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
        #expect(try nativeTestField(.object(result), "cacheInfo", "sourceAvailable") == .bool(true))
        guard case .array(let errors) = result["errors"] else { throw FixtureError.missingField }
        if source == "cache" {
            #expect(result["status"] == .string("complete"))
            #expect(try nativeTestField(.object(result), "cacheInfo", "sourceComplete") == .bool(true))
            #expect(errors.isEmpty)
        } else {
            #expect(result["status"] == .string("partial"))
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

    @Test func aCacheMissFailsInsteadOfBecomingASuccessfulEmptySource() async throws {
        try #require(NSClassFromString("IDEProductManager") == nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = root.appending(path: "Xcode.app/Contents")
        try FileManager.default.createDirectory(at: contents.appending(path: "Frameworks/IDEFoundation.framework"),
                                               withIntermediateDirectories: true)
        let installation = try NativeXcodeInstallation(developerDirectory: contents.appending(component: "Developer"))
        let context = NativeToolContext(artifactsDirectory: root.appending(component: "request"),
            artifactsRoot: root, conversationID: "missing-crash-source")
        let correction = NativeCrashToolCorrection(installation: installation)
        let result = try await execute(.sync, input: .object([
            "bundle_id": .string("example.App"), "platform": .string("iOS"), "source": .string("cache"),
        ]), correction: correction, context: context, expectedEventType: "error")

        #expect(result["status"] == .string("failed"))
        #expect(try nativeTestField(.object(result), "cacheInfo", "sourceAvailable") == .bool(false))
        #expect(try nativeTestField(.object(result), "cacheInfo", "sourceComplete") == .bool(false))
        guard case .array(let errors) = result["errors"] else { throw FixtureError.missingField }
        #expect(try nativeTestField(try #require(errors.first), "operation") == .string("cacheRead"))
    }

    @Test(arguments: ["cache", "networkWithCacheFallback"])
    func aStartedJobFinishesEveryImportAfterItsRequestEndsAndAnotherRequestCanReadTheChanges(source: String) async throws {
        try #require(NSClassFromString("IDEProductManager") == nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installation = try jobInstallation(at: root)
        let cache = root.appending(component: "shared-cache")
        let startContext = NativeToolContext(artifactsDirectory: root.appending(path: "start/request"),
            artifactsRoot: root.appending(component: "start"), conversationID: "start-crash-job", crashCacheRoot: cache)
        let observerContext = NativeToolContext(artifactsDirectory: root.appending(path: "observer/request"),
            artifactsRoot: root.appending(component: "observer"), conversationID: "observe-crash-job", crashCacheRoot: cache)
        let query = NativeCrashQuery(bundleIdentifier: "example.App", platformIdentifier: "com.apple.platform.iphoneos",
            uploadPlatformIdentifier: "com.apple.platform.iphoneos", appVersion: nil, isBeta: nil,
            timePeriod: "last14Days", pageIndex: 0, pageSize: 25, collectsAllPages: true)
        let identifiers = ["first-issue", "second-issue"]
        let points: [JSONValue] = identifiers.map { id in
            .object(["analyticsPointIdentifier": .string(id), "analyticsPointName": .string(id + ".crash()")])
        }
        let sourceStore = NativeCrashStore(root: cache.appending(component: "SourceSnapshots"))
        _ = try sourceStore.write(.object(["points": .array(points)]), key: query.json(issueID: nil),
            fetchedAt: "2024-01-01T00:00:00Z")
        let input: JSONValue = .object(["bundle_id": .string("example.App"), "platform": .string("iOS"),
            "source": .string(source), "max_records": .number(.int(1))])
        let owner = NativeCrashToolCorrection(installation: installation)
        let observer = NativeCrashToolCorrection(installation: installation)

        // The Start response stream has fully ended before the separate request waits.
        let started = try await execute(.start, input: input, correction: owner, context: startContext)
        #expect(started["state"] == .string("queued"))
        await owner.finishExecution(request: startContext.artifactsDirectory)
        let finished = try await finishedJob(started, correction: observer, context: observerContext)
        let expectedState = source == "cache" ? "completed" : "failed"
        #expect(finished["state"] == .string(expectedState))
        let result = try nativeTestObject(try nativeTestField(.object(finished), "result"))
        #expect(try nativeTestField(.object(result), "cacheInfo", "processedCount") == .number(.int(2)))
        #expect(result["nextCursor"] == .null)
        guard case .string(let responsePath) = result["responsePath"] else { throw FixtureError.missingField }
        #expect(try NativeCrashStore.object(Data(contentsOf: URL(fileURLWithPath: responsePath))) == result)

        let read = try await execute(.read, input: .object(["bundle_id": .string("example.App"), "platform": .string("iOS")]),
            correction: observer, context: observerContext)
        guard case .array(let changes) = read["changes"], case .string(let checkpoint) = read["checkpoint"] else {
            throw FixtureError.missingField
        }
        let readIdentifiers = try changes.map { change -> String in
            guard case .string(let identifier) = try nativeTestField(change, "issueId") else { throw FixtureError.missingField }
            return identifier
        }
        #expect(readIdentifiers.sorted() == identifiers.sorted())

        let repeated = try await execute(.start, input: input, correction: owner, context: startContext)
        let repeatedResult = try await finishedJob(repeated, correction: observer, context: observerContext)
        #expect(repeatedResult["state"] == .string(expectedState))
        let unchanged = try await execute(.read, input: .object(["checkpoint": .string(checkpoint)]),
            correction: observer, context: observerContext)
        #expect(unchanged["changes"] == .array([]))
        try await owner.shutdown()
        try await observer.shutdown()
    }

    @Test func aFailedBackgroundSyncRemainsASuccessfulJobStatusResponseWithItsCause() async throws {
        try #require(NSClassFromString("IDEProductManager") == nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let correction = NativeCrashToolCorrection(installation: try jobInstallation(at: root))
        let context = NativeToolContext(artifactsDirectory: root.appending(component: "request"),
            artifactsRoot: root, conversationID: "missing-crash-job-source")
        let started = try await execute(.start, input: .object(["bundle_id": .string("example.App"),
            "platform": .string("iOS"), "source": .string("cache")]), correction: correction, context: context)
        let finished = try await finishedJob(started, correction: correction, context: context)
        #expect(finished["state"] == .string("failed"))
        #expect(try nativeTestField(.object(finished), "result", "status") == .string("failed"))
        guard case .array(let errors) = try nativeTestField(.object(finished), "result", "errors") else {
            throw FixtureError.missingField
        }
        #expect(try nativeTestField(try #require(errors.first), "operation") == .string("cacheRead"))
        try await correction.shutdown()
    }

    @Test func anUnreadableSampleStopsTheJobAndRetainsOneImportResponseForExplicitRetry() async throws {
        try #require(NSClassFromString("IDEProductManager") == nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let logs = root.appending(component: "Logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let sample = logs.appending(component: "2024-01-01_00-00-00_+0000-" + String(repeating: "a", count: 40) + ".crash")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sample.path)
            try? FileManager.default.removeItem(at: root)
        }
        try Data("saved sample".utf8).write(to: sample)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: sample.path)
        try #require(!FileManager.default.isReadableFile(atPath: sample.path))
        // A native filename supplies the date, so import reaches the body read after metadata capture succeeds.
        #expect(try NativeCrashLogSource.inspect(rawURL: sample, includeHeaderDate: false).nativeID
            == sample.deletingPathExtension().lastPathComponent)
        let correction = NativeCrashToolCorrection(installation: try jobInstallation(at: root))
        let context = NativeToolContext(artifactsDirectory: root.appending(component: "request"),
            artifactsRoot: root, conversationID: "unreadable-crash-job-sample")
        let query = NativeCrashQuery(bundleIdentifier: "example.App", platformIdentifier: "com.apple.platform.iphoneos",
            uploadPlatformIdentifier: "com.apple.platform.iphoneos", appVersion: nil, isBeta: nil,
            timePeriod: "last14Days", pageIndex: 0, pageSize: 25, collectsAllPages: true)
        let source = NativeCrashStore(root: context.crashCacheRoot.appending(component: "SourceSnapshots"))
        _ = try source.write(.object(["logDirectory": .string(logs.path)]), key: query.json(issueID: "stable-issue"),
            fetchedAt: "2024-01-01T00:00:00Z")
        let started = try await execute(.start, input: .object(["bundle_id": .string("example.App"),
            "platform": .string("iOS"), "issue_id": .string("stable-issue"), "source": .string("cache")]),
            correction: correction, context: context)
        let finished = try await finishedJob(started, correction: correction, context: context)
        #expect(finished["state"] == .string("failed"))
        let result = try nativeTestField(.object(finished), "result")
        #expect(try nativeTestField(result, "status") == .string("partial"))
        #expect(try nativeTestField(result, "cacheInfo", "failedCount") == .number(.int(1)))
        guard case .string(let cursor) = try nativeTestField(result, "nextCursor") else { throw FixtureError.missingField }
        guard case .array(let errors) = try nativeTestField(result, "errors") else { throw FixtureError.missingField }
        #expect(try nativeTestField(try #require(errors.first), "operation") == .string("importCrashRecord"))
        let responses = try FileManager.default.contentsOfDirectory(at: context.crashCacheRoot.appending(component: "Responses"),
            includingPropertiesForKeys: nil)
        #expect(responses.count == 1)

        let failedResume = try await execute(.resume, input: .object(["job_id": try nativeTestField(.object(finished), "jobId")]),
            correction: correction, context: context)
        let failedRetry = try await finishedJob(failedResume, correction: correction, context: context)
        #expect(failedRetry["state"] == .string("failed"))
        let failedRetryResult = try nativeTestField(.object(failedRetry), "result")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sample.path)
        let resumed = try await execute(.resume, input: .object(["job_id": try nativeTestField(.object(failedRetry), "jobId")]),
            correction: correction, context: context)
        let retriedJob = try await finishedJob(resumed, correction: correction, context: context)
        #expect(retriedJob["state"] == .string("completed"))
        #expect(retriedJob["previousJobId"] == failedRetry["jobId"])
        let retried = try nativeTestField(.object(retriedJob), "result")
        #expect(try nativeTestField(retried, "cacheInfo", "acquisitionComplete") == .bool(true))
        #expect(try nativeTestField(retried, "cacheInfo", "processedCount") == .number(.int(1)))
        // The original continuation remains replayable after Resume used it.
        let originalContinuation = try await execute(.sync, input: .object(["cursor": .string(cursor)]),
            correction: correction, context: context)
        #expect(.object(originalContinuation) == failedRetryResult)
        try await correction.shutdown()
    }

    @Test(arguments: ["cache", "network", "missing-page"])
    func resumeRecoversSavedPagesAndImportsThenRefetchesChangedIssueNames(sourceMode: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = NativeToolContext(artifactsDirectory: root.appending(component: "request"),
            artifactsRoot: root, conversationID: "resume-crash-job")
        let query = NativeCrashQuery(bundleIdentifier: "example.App", platformIdentifier: "com.apple.platform.iphoneos",
            uploadPlatformIdentifier: "com.apple.platform.iphoneos", appVersion: nil, isBeta: nil,
            timePeriod: "last14Days", pageIndex: 0, pageSize: 25, collectsAllPages: true)
        let input: JSONValue = .object(["bundle_id": .string("example.App"), "platform": .string("iOS"),
            "source": .string(sourceMode == "network" ? "network" : "cache"), "max_records": .number(.int(1))])
        let retained = point("retained", name: "Previously captured")
        let before = point("changed", name: "Unsymbolicated")
        let importer = try NativeCrashSyncStore(root: context.crashCacheRoot)
        let partialSnapshot = try NativeCrashToolCorrection.snapshot(collection: .issues, query: query, issueID: nil,
            loaded: .init(value: .object(["points": .array([before, retained])]), source: "organizer",
                fetchedAt: "2024-01-01T00:00:00Z", isComplete: false))
        let partial = try await importer.synchronize(partialSnapshot, maxRecords: 1, maxBytes: 1024 * 1024)
        let cursor = try nativeTestField(partial, "nextCursor")
        guard case .string = cursor else { throw FixtureError.missingField }
        let firstRead = try await importer.readChanges(collection: .issues, query: partialSnapshot.query,
            checkpoint: nil, limit: 25, maxBytes: 256 * 1024, order: .observedNewestFirst)
        let checkpoint = try nativeTestField(firstRead, "checkpoint")
        let jobs = try NativeCrashSyncJobs(root: context.crashCacheRoot)
        let started = try jobs.start(input: input) { job in
            let pageQuery = query.withPage(0).json(issueID: nil)
            let pages = NativeCrashStore(root: job.directory.appending(component: "Pages"))
            if sourceMode != "missing-page" {
                _ = try pages.write(.object(["points": .array([before, retained])]), key: pageQuery,
                    fetchedAt: "2024-01-01T00:00:00Z")
            }
            try job.updateProgress(["pages": .array([.object(["query": pageQuery])])])
            return partial
        }
        let correction = NativeCrashToolCorrection(installation: try jobInstallation(at: root))
        let previous = try await finishedJob(try nativeTestObject(started), correction: correction, context: context)
        #expect(previous["state"] == .string("failed"))
        guard case .string(let oldID) = previous["jobId"] else { throw FixtureError.missingField }
        let ledger = context.crashCacheRoot.appending(path: "Jobs/\(oldID)/job.json")
        let originalBytes = try Data(contentsOf: ledger)
        let source = NativeCrashStore(root: context.crashCacheRoot.appending(component: "SourceSnapshots"))
        _ = try source.write(.object(["points": .array([point("changed", name: "Symbolicated"),
            point("new", name: "New issue")])]), key: query.json(issueID: nil), fetchedAt: "2024-01-02T00:00:00Z")

        let resumed = try await execute(.resume, input: .object(["job_id": .string(oldID)]),
            correction: correction, context: context)
        let finished = try await finishedJob(resumed, correction: correction, context: context)
        #expect(finished["state"] == .string(sourceMode != "network" ? "completed" : "failed"))
        #expect(finished["previousJobId"] == .string(oldID))
        #expect(finished["jobId"] != previous["jobId"])
        #expect(try Data(contentsOf: ledger) == originalBytes)
        #expect(try nativeTestField(.object(finished), "result", "cacheInfo", "sourceComplete") == .bool(sourceMode != "network"))
        guard case .array(let recoveredImports) = try nativeTestField(.object(finished), "progress", "recoveredImports") else {
            throw FixtureError.missingField
        }
        let imported = try #require(recoveredImports.first)
        if sourceMode == "missing-page" {
            guard case .array(let failures) = try nativeTestField(.object(finished), "progress", "recoveryErrors") else {
                throw FixtureError.missingField
            }
            #expect(try nativeTestField(try #require(failures.first), "jobId") == .string(oldID))
        }
        #expect(try nativeTestField(imported, "cacheInfo", "processedCount") == .number(.int(2)))
        guard case .string(let recoveryPath) = try nativeTestField(imported, "responsePath") else { throw FixtureError.missingField }
        #expect(try NativeCrashStore.object(Data(contentsOf: URL(filePath: recoveryPath)))["cacheInfo"]
            == nativeTestField(imported, "cacheInfo"))
        let changes = try await execute(.read, input: .object(["checkpoint": checkpoint]),
            correction: correction, context: context)
        guard case .array(let records) = changes["changes"] else { throw FixtureError.missingField }
        let names = try records.map { try nativeTestField($0, "name") }
        #expect(names.contains(.string("Previously captured")))
        #expect(names.contains(.string("Symbolicated")) == (sourceMode != "network"))
        #expect(names.contains(.string("New issue")) == (sourceMode != "network"))
        let secondCheckpoint = try #require(changes["checkpoint"])
        let unchanged = try await execute(.read, input: .object(["checkpoint": secondCheckpoint]),
            correction: correction, context: context)
        #expect(unchanged["changes"] == .array([]))
        guard case .string(let token) = cursor else { throw FixtureError.missingField }
        let replay = try await importer.resumeSync(token)
        #expect(try nativeTestField(replay, "cacheInfo", "processedCount") == .number(.int(2)))
        await jobs.shutdown()
        try await correction.shutdown()
    }

    @Test(arguments: [false, true])
    func resumeRetriesALogWithoutNativeSamplesAndRetainsPriorErrorsIfCleanupFails(incompleteIdentity: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = NativeToolContext(artifactsDirectory: root.appending(component: "request"),
            artifactsRoot: root, conversationID: "resume-empty-log")
        let input: JSONValue = .object(["bundle_id": .string("example.Resume." + UUID().uuidString),
            "platform": .string("iOS"), "issue_id": .string("no-downloaded-samples")])
        let originalFailure: JSONValue = .object(["operation": .string("download"), "message": .string("Original download failed")])
        let partial: JSONValue = .object(["status": .string("failed"), "errors": .array([originalFailure])])
        let owner = try NativeCrashSyncJobs(root: context.crashCacheRoot)
        let started = try owner.start(input: input) { job in
            try job.updateProgress(["adamIdentifier": .string("123")])
            if incompleteIdentity { try job.updateProgress(["organizer": .object(["processId": .number(.int(123))])]) }
            return partial
        }
        let correction = NativeCrashToolCorrection(installation: try jobInstallation(at: root))
        let previous = try await finishedJob(try nativeTestObject(started), correction: correction, context: context)
        let resumed = try await execute(.resume, input: .object(["job_id": try #require(previous["jobId"])]),
            correction: correction, context: context)
        let finished = try await finishedJob(resumed, correction: correction, context: context)
        #expect(finished["state"] == .string("failed"))
        if incompleteIdentity {
            #expect(finished["result"] == partial)
            guard case .array(let errors) = finished["errors"] else { throw FixtureError.missingField }
            #expect(errors.contains(originalFailure))
            let cleanup = try #require(errors.last)
            #expect(try nativeTestField(cleanup, "cacheErrors") == .array([originalFailure]))
            #expect(try nativeTestField(cleanup, "underlyingError", "message")
                == .string("The saved Organizer process identity is incomplete; no termination was requested"))
        } else {
            // The product inventory failure identifies the new acquisition path:
            // no saved native sample must prevent attempting that acquisition.
            #expect(try nativeTestField(.object(finished), "result", "cacheInfo", "sourceAvailable") == .bool(false))
            guard case .array(let errors) = try nativeTestField(.object(finished), "result", "errors") else {
                throw FixtureError.missingField
            }
            #expect(try nativeTestField(try #require(errors.first), "message")
                == .string("Xcode's product manager is unavailable"))
        }
        await owner.shutdown()
        try await correction.shutdown()
    }

    private func point(_ id: String, name: String) -> JSONValue {
        .object(["analyticsPointIdentifier": .string(id), "analyticsPointName": .string(name)])
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
        let originalTime = "2024-01-01T00:00:00.125Z"
        var loaded = NativeCrashData.Loaded(value: .object(["distribution": distribution, "logDirectory": .string(primaryLogs.path)]),
            source: "cache", fetchedAt: originalTime, isComplete: true)
        let primary = try NativeCrashToolCorrection.snapshot(collection: .logs, query: query, issueID: "stable-issue", loaded: loaded)
        #expect(primary.sourceObservedAt == Date(timeIntervalSince1970: 1_704_067_200.125))
        loaded.recovery = NativeCrashData.Fetched(value: .object(["cachedDistribution": distribution,
                "sampleFreshness": .string("unverifiedSavedSamples"), "logDirectory": .string(recoveredLogs.path)]),
                fetchedAt: nil, source: "organizerCache", errors: [failure], isComplete: false)
        loaded.errors = [failure]
        let snapshot = try NativeCrashToolCorrection.snapshot(collection: .logs, query: query, issueID: "stable-issue", loaded: loaded)
        #expect(try nativeTestField(snapshot.metadata, "provenance", "source") == .string("cache"))
        #expect(try nativeTestField(snapshot.metadata, "provenance", "fetchedAt") == .string(originalTime))
        #expect(try nativeTestField(snapshot.metadata, "timeSeries", "uniqueDeviceCountForTimePeriod") == .number(.int(9)))
        #expect(try nativeTestField(snapshot.metadata, "recovery", "provenance", "fetchedAt") == .null)
        #expect(try nativeTestField(snapshot.metadata, "recovery", "native", "sampleFreshness") == .string("unverifiedSavedSamples"))
        #expect(try nativeTestField(snapshot.metadata, "importProvenance", "source") == .string("organizerCache"))
        #expect(try nativeTestField(snapshot.metadata, "importProvenance", "fetchedAt") == .null)
        #expect(!snapshot.isComplete)
        #expect(snapshot.sourceAvailable)
        #expect(snapshot.sourceObservedAt == nil)

        let store = try NativeCrashSyncStore(root: root.appending(component: "cache"))
        let sync = try await store.synchronize(snapshot, maxRecords: 100, maxBytes: 64 * 1024 * 1024)
        #expect(try nativeTestField(sync, "status") == .string("partial"))
        #expect(try nativeTestField(sync, "cacheInfo", "sourceAvailable") == .bool(true))
        #expect(try nativeTestField(sync, "cacheInfo", "sourceComplete") == .bool(false))
        let read = try await store.readChanges(collection: .logs, query: snapshot.query, checkpoint: nil,
            limit: 25, maxBytes: 256 * 1024, order: .observedNewestFirst)
        guard case .array(let changes) = try nativeTestField(read, "changes") else { throw FixtureError.missingField }
        #expect(changes.count == 1)
        guard case .string(let path) = try nativeTestField(try #require(changes.first), "path") else { throw FixtureError.missingField }
        #expect(try String(contentsOfFile: path, encoding: .utf8) == text)
    }

    private func execute(_ kind: NativeCrashToolCorrection.Kind, input: JSONValue,
                         correction: NativeCrashToolCorrection, context: NativeToolContext,
                         expectedEventType: String = "completed") async throws -> [String: JSONValue] {
        let stream = try correction.execute(kind, input: NativeCrashStore.encode(input), context: context)
        var events: [[String: JSONValue]] = []
        for await event in stream { events.append(try NativeCrashStore.object(event)) }
        let event = try #require(events.last)
        #expect(event["type"] == .string(expectedEventType))
        guard case .object(let result) = event["data"] else { throw FixtureError.missingField }
        return result
    }

    private func jobInstallation(at root: URL) throws -> NativeXcodeInstallation {
        let contents = root.appending(path: "Xcode.app/Contents")
        try FileManager.default.createDirectory(at: contents.appending(path: "Frameworks/IDEFoundation.framework"),
                                               withIntermediateDirectories: true)
        return try NativeXcodeInstallation(developerDirectory: contents.appending(component: "Developer"))
    }

    private func finishedJob(_ started: [String: JSONValue], correction: NativeCrashToolCorrection,
                             context: NativeToolContext) async throws -> [String: JSONValue] {
        guard case .string(let jobID) = started["jobId"] else { throw FixtureError.missingField }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        var latest = started
        while true {
            guard case .string(let state) = latest["state"], case .number(.int(let revision)) = latest["revision"] else {
                throw FixtureError.missingField
            }
            if ["completed", "failed", "cancelled", "interrupted"].contains(state) { return latest }
            guard clock.now < deadline else { throw FixtureError.jobDidNotFinish }
            latest = try await execute(.wait, input: .object(["job_id": .string(jobID),
                "after_revision": .number(.int(revision)), "wait_seconds": .number(.int(5))]),
                correction: correction, context: context)
        }
    }

    private enum FixtureError: Error { case missingField, jobDidNotFinish }
}
