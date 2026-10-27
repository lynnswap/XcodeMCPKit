import CryptoKit
import Foundation
import Testing
import XcodeMCPWire
@testable import XcodeMCPNativeRuntime

@Suite
struct NativeCrashDataTests {
    @Test func crashRequestsDecodeThePublishedSelectionAndPagingInputs() throws {
        let input = Data(#"{"workspaceIdentifier":"workspace","bundle_id":"example.App","platform":"iOS","app_version":"2.0","is_beta":false,"time_period":"last365Days","page":2,"page_size":50,"issue_id":"stable-issue","source":"cache"}"#.utf8)
        let request = try JSONDecoder().decode(NativeCrashRequest.self, from: input)
        #expect(request.workspaceIdentifier == "workspace")
        #expect(request.bundleIdentifier == "example.App")
        #expect(request.platform == "iOS")
        #expect(request.appVersion == "2.0")
        #expect(request.isBeta == false)
        #expect(request.timePeriod == "last365Days")
        #expect(request.pageIndex == 2)
        #expect(request.pageSize == 50)
        #expect(request.issueID == "stable-issue")
        #expect(request.source == .cache)
    }

    @Test func aMinimalRequestStartsAtTheFirstPageWithNativePeriodDefaults() throws {
        let request = try JSONDecoder().decode(NativeCrashRequest.self, from: Data(#"{"bundle_id":"example.App","platform":"iOS"}"#.utf8))
        #expect(request.timePeriod == "last14Days")
        #expect(request.pageIndex == 0)
        #expect(request.pageSize == 25)
        #expect(request.source == .network)
        #expect(request.appVersion == nil)
        #expect(request.isBeta == nil)
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
            try NativeCrashStore.encode(downloaded)
        }

        #expect(result.value == downloaded)
        #expect(result.source == "network")
        #expect(result.fetchedAt != nil)
        #expect(result.cachePath == nil)
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
            try NativeCrashStore.encode(firstPage)
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
            try NativeCrashStore.encode(secondPage)
        }

        #expect(retried.value == secondPage)
        #expect(retried.errors.isEmpty)
        #expect(try store.read(key: cacheKey())?.value == firstPage)
        #expect(try store.read(key: cacheKey())?.fetchedAt == first.fetchedAt)
        #expect(try store.read(key: cacheKey(page: 1))?.value == secondPage)
    }

    @Test(arguments: [false, true])
    func advertisedCrashContractsUseInputsThatTheRequestDecoderAccepts(detail: Bool) throws {
        let oldDescriptor: JSONValue = .object(["name": .string("LegacyCrashTool")])
        let native = NativeTool(name: "LegacyCrashTool", descriptor: oldDescriptor, workspaceScoped: false)
        let tool = NativeCrashContract.describe(native, detail: detail)
        let properties = try nativeTestObject(nativeTestField(tool.descriptor, "inputSchema", "properties"))
        var arguments: [String: JSONValue] = ["bundle_id": .string("example.App"), "platform": .string("iOS")]
        for (name, descriptor) in properties {
            if let value = try nativeTestObject(descriptor)["default"] { arguments[name] = value }
        }
        arguments[detail ? "issue_id" : "page"] = detail ? .string("stable-issue") : .number(.int(2))
        #expect(Set(arguments.keys).isSubset(of: Set(properties.keys)))

        let request = try JSONDecoder().decode(NativeCrashRequest.self, from: NativeCrashStore.encode(.object(arguments)))

        #expect(tool.name == (detail ? "GetCrashIssue" : "ListCrashIssues"))
        #expect(try nativeTestField(tool.descriptor, "inputSchema", "required") == .array(detail ? [.string("issue_id")] : []))
        #expect(request.bundleIdentifier == "example.App")
        #expect(request.timePeriod == "last14Days")
        #expect(request.source == .network)
        if detail { #expect(request.issueID == "stable-issue") }
        else {
            #expect(request.pageIndex == 2)
            #expect(request.pageSize == 25)
        }
        let output = try nativeTestObject(nativeTestField(tool.descriptor, "outputSchema", "properties"))
        #expect(output[detail ? "timeSeries" : "pagination"] != nil)
        #expect(output[detail ? "logs" : "issues"] != nil)
        #expect(output["errors"] != nil)
        #expect(output["provenance"] != nil)
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

    @Test(arguments: [false, true])
    func timeSeriesRetainsGapsAndTheDeduplicatedPeriodCount(fromOrganizerCache: Bool) throws {
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
        let distribution: JSONValue = fromOrganizerCache
            ? .object(["body": .object(["timeSeriesDistribution": nativeSeries])])
            : .object(["timeDistribution": nativeSeries])

        let series = try NativeCrashData.timeSeries(distribution, timePeriod: "last14Days")

        #expect(try nativeTestField(series, "timeDistributionDatas") == intervals)
        #expect(try nativeTestField(series, "startDate") == .string("2024-01-01T00:00:00Z"))
        #expect(try nativeTestField(series, "endDate") == .string("2024-01-15T00:00:00Z"))
        #expect(try nativeTestField(series, "uniqueDeviceCountForTimePeriod") == .number(.int(4)))
        #expect(try nativeTestField(series, "metric") == .string("uniqueDevices"))
        #expect(try nativeTestField(series, "nativeGranularity") == .number(.int(1)))
    }

    @Test func aSampleWriteFailureDoesNotDiscardSuccessfullySavedPlainTextLogs() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let text = "Exception Type: EXC_BAD_ACCESS\nThread 0 Crashed:\n0   アプリ.start() + 32\n"
        let unwritableText = "Exception Type: EXC_CRASH\nThread 1 Crashed:\n0   App.launch() + 64\n"
        let blockedPath = directory.appendingPathComponent(SHA256.hash(data: Data(unwritableText.utf8)).hexString + ".crash")
        try FileManager.default.createDirectory(at: blockedPath, withIntermediateDirectories: false)
        let response: [String: JSONValue] = ["logListContainer": .object(["crashPointLogList": .object([
            "logDatas": .array([
                .object(["data": .object(["data": .string(text)])]),
                .object(["data": .object(["data": .string(unwritableText)])]),
            ]),
        ])])]

        let result = NativeCrashData.saveLogs(response, directory: directory)

        #expect(result.logs.count == 1)
        #expect(result.errors.count == 1)
        let log = try #require(result.logs.first)
        guard case .string(let path) = try nativeTestField(log, "path") else {
            Issue.record("A saved sample must provide its local path")
            return
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data(text.utf8))
        let failure = try #require(result.errors.first)
        #expect(try nativeTestField(failure, "operation") == .string("logWrite"))
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
