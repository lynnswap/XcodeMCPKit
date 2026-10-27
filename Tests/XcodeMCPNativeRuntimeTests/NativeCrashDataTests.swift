import Foundation
import Testing
import XcodeMCPWire
@testable import XcodeMCPNativeRuntime

@Suite
struct NativeCrashDataTests {
    @Test func syncRequestsDecodeThePublishedSelectionAndImportBudget() throws {
        let input = Data(#"{"workspaceIdentifier":"workspace","bundle_id":"example.App","platform":"iOS","app_version":"2.0","is_beta":false,"time_period":"last365Days","collection":"issues","source":"cache","max_records":3,"max_bytes":4096}"#.utf8)
        let request = try JSONDecoder().decode(NativeCrashSyncRequest.self, from: input)
        #expect(request.query.workspaceIdentifier == "workspace")
        #expect(request.query.bundleIdentifier == "example.App")
        #expect(request.query.platform == "iOS")
        #expect(request.query.appVersion == "2.0")
        #expect(request.query.isBeta == false)
        #expect(request.query.timePeriod == "last365Days")
        #expect(request.query.specifiedFields.contains("time_period"))
        #expect(request.collection == .issues)
        #expect(request.maxRecords == 3)
        #expect(request.maxBytes == 4096)
        #expect(request.source == .cache)
    }

    @Test func aMinimalSyncRequestKeepsQueryAndImportDefaults() throws {
        let request = try JSONDecoder().decode(NativeCrashSyncRequest.self, from: Data(#"{"bundle_id":"example.App","platform":"iOS"}"#.utf8))
        #expect(request.query.timePeriod == "last14Days")
        #expect(!request.query.specifiedFields.contains("time_period"))
        #expect(request.collection == nil)
        #expect(request.maxRecords == 100)
        #expect(request.maxBytes == 64 * 1024 * 1024)
        #expect(request.source == .network)
        #expect(request.query.appVersion == nil)
        #expect(request.query.isBeta == nil)
    }

    @Test func readContinuationsKeepTokenScopeAndRejectConflictingTokensOrInvalidBudgets() throws {
        let request = try JSONDecoder().decode(NativeCrashReadRequest.self, from: Data(#"{"cursor":"read-cursor"}"#.utf8))
        #expect(request.query.bundleIdentifier == nil)
        #expect(request.query.specifiedFields.isEmpty)
        #expect(request.collection == nil)
        #expect(request.order == nil)
        #expect(request.limit == 25)
        #expect(request.maxBytes == 256 * 1024)
        #expect(throws: NativeRuntimeError.self) {
            try JSONDecoder().decode(NativeCrashReadRequest.self, from: Data(#"{"cursor":"read-cursor","checkpoint":"baseline"}"#.utf8))
        }
        #expect(throws: NativeRuntimeError.self) {
            try JSONDecoder().decode(NativeCrashReadRequest.self, from: Data(#"{"max_bytes":0}"#.utf8))
        }
        #expect(throws: NativeRuntimeError.self) {
            try JSONDecoder().decode(NativeCrashSyncRequest.self, from: Data(#"{"max_records":0}"#.utf8))
        }
    }

    @Test @MainActor func networkFallbackUsesOnlyTheExactCachedRequestAndItsOriginalFetchTime() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeCrashStore(root: root)
        let requested = cacheKey()
        let requestedValue: JSONValue = .object(["issues": .array([.string("requested-issue")])])
        _ = try store.write(requestedValue, key: requested, fetchedAt: "2024-01-01T00:00:00Z")
        _ = try store.write(.object(["issues": .array([.string("another-page")])]),
                            key: cacheKey(page: 2), fetchedAt: "2024-01-02T00:00:00Z")
        _ = try store.write(.object(["issues": .array([.string("another-filter")])]),
                            key: cacheKey(version: "3.0", period: "last365Days"), fetchedAt: "2024-01-03T00:00:00Z")

        let failure = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        let cached = try await NativeCrashData.load(key: requested, source: .networkWithCacheFallback, store: store) {
            throw failure
        }
        #expect(cached.value == requestedValue)
        #expect(cached.source == "cache")
        #expect(cached.fetchedAt == "2024-01-01T00:00:00Z")
        let error = try #require(cached.errors.first)
        #expect(try nativeTestField(error, "operation") == .string("download"))
        #expect(try nativeTestField(error, "domain") == .string(NSURLErrorDomain))
        #expect(try nativeTestField(error, "code") == .number(.int(Int64(NSURLErrorTimedOut))))

        let uncachedPage = try await NativeCrashData.load(key: cacheKey(page: 1), source: .networkWithCacheFallback, store: store) {
            throw failure
        }
        #expect(uncachedPage.value == nil)
        #expect(uncachedPage.source == nil)
        let query = NativeCrashQuery(bundleIdentifier: "com.example.app", platformIdentifier: "com.apple.platform.iphoneos",
            uploadPlatformIdentifier: "com.apple.platform.iphoneos", appVersion: nil, isBeta: nil,
            timePeriod: "last14Days", pageIndex: 0, pageSize: 25, collectsAllPages: true)
        let snapshot = try NativeCrashToolCorrection.snapshot(collection: .issues, query: query,
            issueID: nil, loaded: uncachedPage)
        #expect(!snapshot.sourceAvailable)
        #expect(!snapshot.isComplete)
        #expect(snapshot.errors == uncachedPage.errors)
    }

    @Test @MainActor func recoveredOrganizerSamplesDoNotReplaceTheExactServerFallback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeCrashStore(root: root)
        let key = cacheKey()
        let original: JSONValue = .object(["distribution": .object(["body": .object([
            "timeSeriesDistribution": .object(["timeDistributionMetaDatas": .array([
                .object(["timePeriod": .string("last14Days"), "subTotal": .number(.int(12))]),
            ])]),
        ])]), "logDirectory": .string(root.appendingPathComponent("Logs").path)])
        let originalTime = "2024-01-01T00:00:00Z"
        let cachedError = NativeCrashData.diagnostic(NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError),
            operation: "organizerLogRead")
        let entry = try store.write(original, key: key, fetchedAt: originalTime, errors: [cachedError])
        let originalEnvelope = try Data(contentsOf: URL(fileURLWithPath: entry.path))
        let pointURL = root.appendingPathComponent("PointInfo.json")
        let logDirectory = root.appendingPathComponent("Logs")
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: false)
        try Data("saved sample".utf8).write(to: logDirectory.appendingPathComponent("saved.crash"))
        let saved = NativeOrganizerCrashCache.IssueSnapshot(pointInfo: .object([:]), pointInfoURL: pointURL,
            distribution: nil, distributionURL: root.appendingPathComponent("DistributionInfo.json"), fetchedAt: nil,
            logDirectory: logDirectory)
        let recovered = try NativeOrganizerCrashService.recoverIssue(.init(snapshot: saved),
            after: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut))

        let fallback = try await NativeCrashData.load(key: key, source: .networkWithCacheFallback, store: store) { recovered }

        #expect(fallback.source == "cache")
        #expect(fallback.value == original)
        #expect(fallback.fetchedAt == originalTime)
        #expect(fallback.errors == recovered.errors + [cachedError])
        #expect(fallback.isComplete)
        #expect(fallback.recovery?.value == recovered.value)
        #expect(fallback.recovery?.source == "organizerCache")
        #expect(fallback.recovery?.fetchedAt == nil)
        #expect(try Data(contentsOf: URL(fileURLWithPath: entry.path)) == originalEnvelope)

        let network = try await NativeCrashData.load(key: key, source: .network, store: store) { recovered }
        #expect(network.value == recovered.value)
        #expect(network.source == "organizerCache")
        #expect(network.fetchedAt == nil)
        #expect(network.cachePath == nil)
        #expect(network.errors == recovered.errors)
        #expect(!network.isComplete)
        #expect(try Data(contentsOf: URL(fileURLWithPath: entry.path)) == originalEnvelope)

        let emptyStore = NativeCrashStore(root: root.appendingPathComponent("empty"))
        let uncached = try await NativeCrashData.load(key: key, source: .networkWithCacheFallback, store: emptyStore) { recovered }
        #expect(uncached.source == "organizerCache")
        #expect(uncached.value == recovered.value)
        #expect(uncached.fetchedAt == nil)
        #expect(uncached.errors == recovered.errors)
        #expect(!uncached.isComplete)
        #expect(try emptyStore.read(key: key)?.value == recovered.value)
    }

    @Test @MainActor func partialAllPageRefreshKeepsTheCompleteCachedCollectionAndNewAttempt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeCrashStore(root: root)
        let query = NativeCrashQuery(bundleIdentifier: "example.App", platformIdentifier: "com.apple.platform.iphoneos",
            uploadPlatformIdentifier: "com.apple.platform.iphoneos", appVersion: nil, isBeta: nil,
            timePeriod: "last14Days", pageIndex: 0, pageSize: 25, collectsAllPages: true)
        let key = query.json(issueID: nil)
        let first: JSONValue = .object(["analyticsPointIdentifier": .string("first-issue"), "analyticsPointName": .string("First.crash()")])
        let last: JSONValue = .object(["analyticsPointIdentifier": .string("last-issue"), "analyticsPointName": .string("Last.crash()")])
        let original: JSONValue = .object(["points": .array([first, last])])
        let originalTime = "2024-01-01T00:00:00Z"
        _ = try store.write(original, key: key, fetchedAt: originalTime)
        let page: JSONValue = .object(["query": query.withPage(0).json(issueID: nil), "status": .string("complete")])
        let partial = try NativeOrganizerCrashService.collectionAfterFailure(.init(query: query, adamIdentifier: "123"),
            points: [first], pages: [page], copiedPages: [page], fetchedAt: "2024-01-02T00:00:00Z", failedPage: 1,
            errors: [], error: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut))

        let fallback = try await NativeCrashData.load(key: key, source: .networkWithCacheFallback, store: store) {
            partial
        }

        #expect(fallback.value == original)
        #expect(fallback.fetchedAt == originalTime)
        #expect(fallback.source == "cache")
        #expect(fallback.errors == partial.errors)
        #expect(fallback.recovery?.value == partial.value)
        #expect(fallback.recovery?.source == "organizer")
        #expect(fallback.recovery?.fetchedAt == "2024-01-02T00:00:00Z")
        #expect(try store.read(key: key)?.value == original)
        #expect(try store.read(key: key)?.fetchedAt == originalTime)
    }

    @Test @MainActor func cacheWriteFailurePreservesTheDownloadedData() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("Cache")
        let occupied = Data("existing file".utf8)
        try occupied.write(to: root)
        let downloaded: JSONValue = .object(["issues": .array([.string("downloaded-issue")])])

        let result = try await NativeCrashData.load(key: cacheKey(), source: .networkWithCacheFallback,
                                                   store: NativeCrashStore(root: root)) {
            NativeCrashData.Fetched(value: downloaded, fetchedAt: "2024-01-04T00:00:00Z")
        }

        #expect(result.value == downloaded)
        #expect(result.source == "organizer")
        #expect(result.fetchedAt != nil)
        #expect(result.cachePath == nil)
        #expect(result.isComplete)
        let error = try #require(result.errors.first)
        #expect(try nativeTestField(error, "operation") == .string("cacheWrite"))
        #expect(try Data(contentsOf: root) == occupied)
    }

    @Test @MainActor func aFailedPageCanBeRetriedWithoutLosingThePreviousPage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeCrashStore(root: root)
        let firstPage: JSONValue = .object(["issues": .array([.string("first-issue")])])
        let secondPage: JSONValue = .object(["issues": .array([.string("second-issue")])])
        let first = try await NativeCrashData.load(key: cacheKey(), source: .network, store: store) {
            NativeCrashData.Fetched(value: firstPage, fetchedAt: "2024-01-04T00:00:00Z")
        }

        let failed = try await NativeCrashData.load(key: cacheKey(page: 1), source: .network, store: store) {
            throw NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        }

        #expect(first.value == firstPage)
        #expect(failed.value == nil)
        let error = try #require(failed.errors.first)
        #expect(try nativeTestField(error, "operation") == .string("download"))
        #expect(try store.read(key: cacheKey())?.value == firstPage)
        #expect(try store.read(key: cacheKey(page: 1)) == nil)

        let retried = try await NativeCrashData.load(key: cacheKey(page: 1), source: .network, store: store) {
            NativeCrashData.Fetched(value: secondPage, fetchedAt: "2024-01-05T00:00:00Z")
        }

        #expect(retried.value == secondPage)
        #expect(retried.errors.isEmpty)
        #expect(try store.read(key: cacheKey())?.value == firstPage)
        #expect(try store.read(key: cacheKey())?.fetchedAt == first.fetchedAt)
        #expect(try store.read(key: cacheKey(page: 1))?.value == secondPage)
    }

    @Test @MainActor func aCachedPartialDownloadRetainsTheMissingSamplesAndOriginalFetchTime() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeCrashStore(root: root)
        let failure = NativeCrashData.diagnostic(NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError), operation: "organizerLogRead")
        let value: JSONValue = .object(["logDirectory": .string(root.appendingPathComponent("Logs").path)])
        let fetched = try await NativeCrashData.load(key: cacheKey(), source: .network, store: store) {
            NativeCrashData.Fetched(value: value, fetchedAt: "2024-01-04T00:00:00Z", errors: [failure], isComplete: false)
        }
        let cached = try await NativeCrashData.load(key: cacheKey(), source: .cache, store: store) {
            Issue.record("A cache-only read must not operate Organizer")
            throw CancellationError()
        }
        #expect(cached.value == fetched.value)
        #expect(cached.errors == [failure])
        #expect(cached.fetchedAt == "2024-01-04T00:00:00Z")
        #expect(!cached.isComplete)
    }

    @Test(arguments: [false, true])
    func advertisedCrashContractsUseInputsThatTheRequestDecoderAccepts(read: Bool) throws {
        let tool = NativeCrashContract.describe(read ? .read : .sync)
        let properties = try nativeTestObject(nativeTestField(tool.descriptor, "inputSchema", "properties"))
        var arguments: [String: JSONValue] = read ? ["cursor": .string("read-cursor")]
            : ["bundle_id": .string("example.App"), "platform": .string("iOS"), "issue_id": .string("stable-issue")]
        for (name, descriptor) in properties {
            if let value = try nativeTestObject(descriptor)["default"] { arguments[name] = value }
        }
        #expect(Set(arguments.keys).isSubset(of: Set(properties.keys)))
        #expect(tool.name == (read ? "ReadCrashChanges" : "SyncCrashReports"))
        #expect(try nativeTestField(tool.descriptor, "inputSchema", "required") == .array([]))
        let data = try NativeCrashStore.encode(.object(arguments))
        if read {
            let request = try JSONDecoder().decode(NativeCrashReadRequest.self, from: data)
            #expect(request.cursor == "read-cursor")
            #expect(request.collection == nil)
            #expect(request.order == nil)
            #expect(request.limit == 25)
            #expect(request.maxBytes == 256 * 1024)
            #expect(properties["workspaceIdentifier"] == nil)
        } else {
            let request = try JSONDecoder().decode(NativeCrashSyncRequest.self, from: data)
            #expect(request.query.bundleIdentifier == "example.App")
            #expect(request.query.issueID == "stable-issue")
            #expect(request.source == .network)
            #expect(request.maxRecords == 100)
            #expect(request.maxBytes == 64 * 1024 * 1024)
        }
        let output = try nativeTestObject(nativeTestField(tool.descriptor, "outputSchema", "properties"))
        #expect(output["errors"] != nil)
        #expect(output["collection"] != nil)
    }

    @Test func aCacheEnvelopeWithAnotherRequestIsNeverReturned() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeCrashStore(root: root)
        let entry = try store.write(.object(["issues": .array([])]), key: cacheKey(), fetchedAt: "2024-01-01T00:00:00Z")
        let mismatched: JSONValue = .object([
            "query": cacheKey(page: 2), "value": .object(["issues": .array([.string("wrong-page")])]),
            "fetchedAt": .string("2024-01-02T00:00:00Z"),
        ])
        try NativeCrashStore.encode(mismatched).write(to: URL(fileURLWithPath: entry.path))

        #expect(throws: NativeRuntimeError.self) { try store.read(key: cacheKey()) }
    }

    @Test func symbolicationChangesTheDisplayNameWithoutChangingIssueIdentity() throws {
        let identifier = "stable-issue"
        let before = try NativeCrashData.issue(nativeIssue(id: identifier, name: "App + 128"))
        let after = try NativeCrashData.issue(nativeIssue(id: identifier, name: "App.start() + 32"))

        #expect(try nativeTestField(before, "issueId") == .string(identifier))
        #expect(try nativeTestField(after, "issueId") == .string(identifier))
        #expect(try nativeTestField(before, "name") == .string("App + 128"))
        #expect(try nativeTestField(after, "name") == .string("App.start() + 32"))
        #expect(try nativeTestField(after, "uniqueDeviceCount") == .number(.int(4)))
        #expect(try nativeTestField(after, "uniqueDeviceCountLast24Hours") == .number(.int(1)))
    }

    @Test func timeSeriesRetainsGapsAndTheDeduplicatedPeriodCount() throws {
        let intervals: JSONValue = .array([
            .object(["startDate": .string("2024-01-01T00:00:00Z"), "endDate": .string("2024-01-02T00:00:00Z"), "value": .number(.int(3))]),
            .object(["startDate": .string("2024-01-03T00:00:00Z"), "endDate": .string("2024-01-04T00:00:00Z"), "value": .number(.int(3))]),
        ])
        let period: JSONValue = .object([
            "timePeriod": .string("last14Days"), "startDate": .string("2024-01-01T00:00:00Z"),
            "endDate": .string("2024-01-15T00:00:00Z"), "subTotalBreakByTimePeriod": .number(.int(1)),
            "uniqueDeviceCountForTimePeriod": .number(.int(4)), "timeDistributionDatas": intervals,
        ])
        let otherPeriod: JSONValue = .object([
            "timePeriod": .string("last24Hours"), "uniqueDeviceCountForTimePeriod": .number(.int(1)),
            "timeDistributionDatas": .array([]),
        ])
        let nativeSeries: JSONValue = .object([
            "timeDistributionMetaDatas": .array([otherPeriod, period]),
        ])
        let distribution: JSONValue = .object(["body": .object(["timeSeriesDistribution": nativeSeries])])

        let series = try NativeCrashData.timeSeries(distribution, timePeriod: "last14Days")

        #expect(try nativeTestField(series, "timeDistributionDatas") == intervals)
        #expect(try nativeTestField(series, "startDate") == .string("2024-01-01T00:00:00Z"))
        #expect(try nativeTestField(series, "endDate") == .string("2024-01-15T00:00:00Z"))
        #expect(try nativeTestField(series, "uniqueDeviceCountForTimePeriod") == .number(.int(4)))
        #expect(try nativeTestField(series, "metric") == .string("uniqueDevices"))
        #expect(try nativeTestField(series, "nativeGranularity") == .number(.int(1)))
        #expect(try nativeTestField(series, "granularity") == .string("day"))
    }

    @Test func aMissingRequestedPeriodDoesNotUseAnotherPeriod() throws {
        let distribution: JSONValue = .object(["body": .object(["timeSeriesDistribution": .object([
            "timeDistributionMetaDatas": .array([.object([
                "timePeriod": .string("last24Hours"), "timeDistributionDatas": .array([]),
            ])]),
        ])])])

        #expect(throws: NativeRuntimeError.self) {
            try NativeCrashData.timeSeries(distribution, timePeriod: "last14Days")
        }
    }

    @Test func diagnosticsPreserveTheUnderlyingFailureAndRecoveryInformation() throws {
        let transport = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut,
                                userInfo: [NSLocalizedDescriptionKey: "The analytics request timed out"])
        let native = NSError(domain: "Analytics", code: 7, userInfo: [
            NSLocalizedDescriptionKey: "Could not load crash samples", NSUnderlyingErrorKey: transport,
            NSLocalizedFailureReasonErrorKey: "The sample request did not finish",
            NSLocalizedRecoverySuggestionErrorKey: "Retry the samples request",
        ])

        let diagnostic = NativeCrashData.diagnostic(native, operation: "samples")

        #expect(try nativeTestField(diagnostic, "operation") == .string("samples"))
        #expect(try nativeTestField(diagnostic, "domain") == .string("Analytics"))
        #expect(try nativeTestField(diagnostic, "code") == .number(.int(7)))
        #expect(try nativeTestField(diagnostic, "message") == .string("Could not load crash samples"))
        #expect(try nativeTestField(diagnostic, "failureReason") == .string("The sample request did not finish"))
        #expect(try nativeTestField(diagnostic, "recoverySuggestion") == .string("Retry the samples request"))
        #expect(try nativeTestField(diagnostic, "underlyingError", "domain") == .string(NSURLErrorDomain))
        #expect(try nativeTestField(diagnostic, "underlyingError", "code") == .number(.int(Int64(NSURLErrorTimedOut))))
        #expect(try nativeTestField(diagnostic, "underlyingError", "message") == .string("The analytics request timed out"))
    }

    @Test func diagnosticsPreserveFailuresStoredInSwiftEnumAssociatedValues() throws {
        let aggregation = CrashAccountFailure.allAccountsFailed(usernameToError: [
            "first": NSError(domain: "AccountCredentials", code: 401),
            "second": NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut),
        ], jobUserDescription: "Downloading crash analytics")

        let diagnostic = NativeCrashData.diagnostic(aggregation, operation: "download")

        guard case .array(let errors) = try nativeTestField(diagnostic, "underlyingErrors") else {
            Issue.record("An account failure must retain its original errors")
            return
        }
        let failures = try errors.map { error in
            JSONValue.object(["domain": try nativeTestField(error, "domain"), "code": try nativeTestField(error, "code")])
        }
        #expect(failures.count == 2)
        #expect(failures.contains(.object(["domain": .string("AccountCredentials"), "code": .number(.int(401))])))
        #expect(failures.contains(.object(["domain": .string(NSURLErrorDomain), "code": .number(.int(Int64(NSURLErrorTimedOut)))])))
    }

    @Test func aRefreshTimeoutRetainsStructuredCacheReadCauses() throws {
        let cause: JSONValue = .object(["domain": .string(NSCocoaErrorDomain), "code": .number(.int(260)),
            "message": .string("Cache read failed"), "path": .string("/tmp/Organizer/DistributionInfo.json"),
            "underlyingError": .object(["domain": .string(NSPOSIXErrorDomain), "code": .number(.int(13))])])
        let failure = NSError(domain: "XcodeMCPKit.Organizer", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Organizer did not refresh", "XcodeMCPKit.CrashDiagnostics": [cause.foundationObject],
        ])
        let diagnostic = NativeCrashData.diagnostic(failure, operation: "download")
        #expect(try nativeTestField(diagnostic, "cacheErrors") == .array([cause]))
    }

    @Test func nativeRuntimeFailuresRetainTheirActionableMessage() throws {
        let value = NativeCrashData.diagnostic(NativeRuntimeError.unavailable("Reload Organizer is disabled"), operation: "download")
        #expect(try nativeTestField(value, "message") == .string("Reload Organizer is disabled"))
    }

    private func cacheKey(page: Int = 0, version: String = "2.0", period: String = "last14Days") -> JSONValue {
        .object(["bundleId": .string("example.App"), "platform": .string("iOS"), "appVersion": .string(version),
                 "isBeta": .bool(false), "timePeriod": .string(period), "page": .number(.int(Int64(page))),
                 "pageSize": .number(.int(25))])
    }

    private func nativeIssue(id: String, name: String) -> JSONValue {
        .object(["analyticsPointIdentifier": .string(id), "analyticsPointName": .string(name),
                 "uniqueDeviceCountFilteredWithTimePeriod": .number(.int(4)),
                 "uniqueDeviceCountFilteredForLast24Hours": .number(.int(1))])
    }
}

private enum CrashAccountFailure: Error {
    case allAccountsFailed(usernameToError: [String: any Error], jobUserDescription: String)
}
