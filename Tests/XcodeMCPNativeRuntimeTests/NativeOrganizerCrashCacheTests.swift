import Foundation
import Testing
import XcodeMCPWire
@testable import XcodeMCPNativeRuntime

@Suite
struct NativeOrganizerCrashCacheTests {
    @Test func pageSelectionUsesTheCompleteRequestAndRefreshDate() throws {
        let root = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = NativeOrganizerCrashCache(productsRoot: root)
        let requested = query()
        var mixedProducts = try object(pageKey(requested))
        var parameters = try object(mixedProducts["pageAgnosticParameters"])
        guard case .array(let products) = parameters["indexedSelectedProductVersions"] else { throw FixtureError.invalidObject }
        parameters["indexedSelectedProductVersions"] = .array(products + products)
        mixedProducts["pageAgnosticParameters"] = .object(parameters)
        try write(.object(["recentItems": .array([
            pageKey(requested), datedPage(requested, count: 4, refreshed: "2024-01-01T00:00:00Z"),
            .object(mixedProducts), datedPage(requested, count: 8, refreshed: "2024-01-04T00:00:00Z"),
            pageKey(query(page: 1)), datedPage(requested, count: 25, refreshed: "2024-01-03T00:00:00Z"),
            pageKey(query(period: "last365Days")), datedPage(requested, count: 99, refreshed: "2024-01-02T00:00:00Z"),
        ])]), to: listURL(root))

        let read = cache.readPage(requested)
        let snapshot = try #require(read.snapshot)

        #expect(read.errors.isEmpty)
        #expect(snapshot.points.count == 1)
        #expect(try object(snapshot.points[0])["uniqueDeviceCountFilteredWithTimePeriod"] == .number(.int(4)))
        #expect(snapshot.fetchedAt == ISO8601DateFormatter().date(from: "2024-01-01T00:00:00Z"))
        #expect(snapshot.pageIndex == 0)
        #expect(snapshot.pageSize == 25)
        #expect(snapshot.key == pageKey(requested))
    }

    @Test func selectedVersionChannelAndUploadPlatformCannotSelectAnotherCachedRequest() throws {
        let root = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let requested = query(platform: "com.apple.platform.macosx", version: "2.0", beta: true)
        let anotherVersion = query(platform: "com.apple.platform.macosx", version: "3.0", beta: true)
        let anotherChannel = query(platform: "com.apple.platform.macosx", version: "2.0", beta: false)
        let anotherUpload = query(platform: "com.apple.platform.macosx", upload: "com.apple.platform.macosx", version: "2.0", beta: true)
        try write(.object(["recentItems": .array([
            pageKey(requested), datedPage(requested, count: 4, refreshed: "2024-01-01T00:00:00Z"),
            pageKey(anotherVersion), datedPage(anotherVersion, count: 99, refreshed: "2024-01-04T00:00:00Z"),
            pageKey(anotherChannel), datedPage(anotherChannel, count: 98, refreshed: "2024-01-03T00:00:00Z"),
            pageKey(anotherUpload), datedPage(anotherUpload, count: 97, refreshed: "2024-01-02T00:00:00Z"),
        ])]), to: listURL(root))

        let read = NativeOrganizerCrashCache(productsRoot: root).readPage(requested)
        let snapshot = try #require(read.snapshot)

        #expect(read.errors.isEmpty)
        #expect(try object(snapshot.points[0])["uniqueDeviceCountFilteredWithTimePeriod"] == .number(.int(4)))
        #expect(snapshot.key == pageKey(requested))
    }

    @Test @MainActor func issueIdentityAndLogDirectoryAreExactWithoutReadingSamples() throws {
        let root = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = NativeOrganizerCrashCache(productsRoot: root)
        let requested = query(version: "2.0")
        let filters = root.appending(path: "example.App/Crashes/Points/stable-issue.xccrashpoint/Filters")
        let selected = filters.appending(component: "selected-version")
        let unfiltered = filters.appending(component: "another-filter")
        try write(pointInfo(requested), to: selected.appending(component: "PointInfo.json"))
        try write(pointInfo(query()), to: unfiltered.appending(component: "PointInfo.json"))
        try write(distribution(bundle: "another.App"), to: selected.appending(component: "DistributionInfo.json"))
        try write(distribution(), to: unfiltered.appending(component: "DistributionInfo.json"))

        let partial = cache.readIssue(requested, issueID: "stable-issue")
        let snapshot = try #require(partial.snapshot)

        #expect(snapshot.pointInfoURL.resolvingSymlinksInPath()
            == selected.appending(component: "PointInfo.json").resolvingSymlinksInPath())
        #expect(snapshot.distribution == nil)
        #expect(snapshot.fetchedAt == nil)
        #expect(snapshot.logDirectory.path
            == snapshot.pointInfoURL.deletingLastPathComponent().appending(component: "Logs").path)
        #expect(partial.errors.count == 1)
        #expect(partial.errors.contains { (try? object($0)["operation"]) == .string("organizerDistributionRead") })
        #expect(cache.readIssue(requested, issueID: "another-issue").snapshot == nil)

        let refreshFailure = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        let recovered = try NativeOrganizerCrashService.recoverIssue(partial, after: refreshFailure)
        #expect(recovered.source == "organizerCache")
        #expect(recovered.fetchedAt == nil)
        #expect(recovered.errors.count == 2)
        #expect(!recovered.isComplete)
        let recoveredValue = try object(recovered.value)
        #expect(recoveredValue["distribution"] == nil)
        #expect(recoveredValue["sampleFreshness"] == .string("unverifiedSavedSamples"))
        #expect(recoveredValue["logDirectory"] == .string(snapshot.logDirectory.path))
        #expect(recoveredValue["logs"] == nil)

        try write(distribution(), to: selected.appending(component: "DistributionInfo.json"))
        let refreshed = cache.readIssue(requested, issueID: "stable-issue")
        #expect(refreshed.snapshot?.fetchedAt == ISO8601DateFormatter().date(from: "2024-01-02T00:00:00Z"))
        #expect(refreshed.snapshot?.distribution != nil)
        #expect(refreshed.snapshot?.logDirectory == snapshot.logDirectory)
        #expect(refreshed.errors.isEmpty)

        let staleRecovery = try NativeOrganizerCrashService.recoverIssue(refreshed, after: refreshFailure)
        let staleValue = try object(staleRecovery.value)
        #expect(staleValue["distribution"] == nil)
        #expect(staleValue["cachedDistribution"] != nil)
        #expect(staleRecovery.fetchedAt == nil)
    }

    @Test func sampleReferencesRetainIdentityWhenLocalSymbolicationChangesTheBytes() throws {
        let root = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let raw = root.appending(component: "2024-01-02_03-04-05.1250_+0900-" + String(repeating: "a", count: 40) + ".crash")
        try Data("raw stack".utf8).write(to: raw)
        let original = try NativeCrashLogSource.inspect(rawURL: raw)
        #expect(original.variant == "raw")
        #expect(original.url == raw)
        #expect(original.occurredAt == Date(timeIntervalSince1970: 1_704_132_245.125))

        let symbolicated = root.appending(component: "LocallySymbolicated").appending(component: raw.lastPathComponent)
        try FileManager.default.createDirectory(at: symbolicated.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("symbolicated stack".utf8).write(to: symbolicated)
        let updated = try NativeCrashLogSource.inspect(rawURL: raw)
        #expect(updated.nativeID == original.nativeID)
        #expect(updated.variant == "locallySymbolicated")
        #expect(updated.url == symbolicated)
        #expect(updated.occurredAt == original.occurredAt)
        #expect(updated.byteCount == 18)
        #expect(!NativeCrashLogSource.matchesFingerprint(original.fingerprint, updated.fingerprint))

        let fallback = root.appending(component: "older-format.crash")
        try Data("Date/Time: 2024-01-02 03:04:05.1250 +0900\n".utf8).write(to: fallback)
        #expect(try NativeCrashLogSource.inspect(rawURL: fallback).occurredAt == original.occurredAt)

        let bounded = root.appending(component: "no-date-in-header.crash")
        try Data((String(repeating: "x", count: 16 * 1024) + "\nDate/Time: 2024-01-02 03:04:05.1250 +0900\n").utf8).write(to: bounded)
        #expect(try NativeCrashLogSource.inspect(rawURL: bounded).occurredAt == nil)
    }

    @Test func aColdCacheIsAbsentWhileAnUnreadableCacheRetainsItsFailure() throws {
        let root = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = NativeOrganizerCrashCache(productsRoot: root)
        let absent = cache.readPage(query())
        #expect(absent.snapshot == nil)
        #expect(absent.errors.isEmpty)
        let url = listURL(root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("invalid JSON".utf8).write(to: url)

        let failed = cache.readPage(query())

        #expect(failed.snapshot == nil)
        let error = try #require(failed.errors.first)
        #expect(try object(error)["path"] == .string(url.path))
        #expect(try object(error)["domain"] != nil)
        #expect(try object(error)["code"] != nil)
    }

    private func query(platform: String = "com.apple.platform.iphoneos", upload: String = "com.apple.platform.iphoneos",
                       version: String? = nil, beta: Bool? = nil, period: String = "last14Days", page: Int = 0) -> NativeCrashServiceQuery {
        NativeCrashServiceQuery(query: NativeCrashQuery(bundleIdentifier: "example.App", platformIdentifier: platform,
            uploadPlatformIdentifier: upload, appVersion: version, isBeta: beta, timePeriod: period, pageIndex: page, pageSize: 25), adamIdentifier: "123")
    }

    private func pageKey(_ query: NativeCrashServiceQuery) -> JSONValue {
        .object(["page": .object(["pageIndex": .number(.int(Int64(query.query.pageIndex))), "pageSize": .number(.int(25))]),
            "pageAgnosticParameters": .object(["adamIdentifier": .string(query.adamIdentifier), "timePeriod": .string(query.query.timePeriod),
                "releaseHistory": .string(query.query.isBeta.map { $0 ? "testFlight" : "appStore" } ?? "all"),
                "indexedSelectedProductVersions": .array([
                    .object(["platformIdentifier": .string(query.query.platformIdentifier), "bundleIdentifier": .string(query.query.bundleIdentifier)]),
                    .object(["adamIdentifier": .string(query.adamIdentifier), "bundleIdentifier": .string(query.query.bundleIdentifier),
                        "platformIdentifier": .string(query.query.platformIdentifier), "uploadPlatformIdentifier": .string(query.query.uploadPlatformIdentifier),
                        "appType": .object(["type": .string("app")]), "build": .object(["type": .string("allBuilds")]),
                        "version": query.query.appVersion.map { .object(["type": .string("version"), "version": .string($0)]) }
                            ?? .object(["type": .string("allVersions")])]),
                ])])])
    }

    private func datedPage(_ query: NativeCrashServiceQuery, count: Int64, refreshed: String) -> JSONValue {
        .object(["lastAccess": .string("2030-01-01T00:00:00Z"), "value": .object([
            "header": .object(["refreshDate": .string(refreshed), "adamIdentifier": .string(query.adamIdentifier), "timePeriod": .string(query.query.timePeriod)]),
            "crashPoints": .array([.object(["analyticsPointIdentifier": .string("stable-issue"), "analyticsPointName": .string("Fixture.crash()"),
                "bundleIdentifier": .string(query.query.bundleIdentifier), "platformSDKIdentifier": .string(query.query.platformIdentifier),
                "uploadPlatformSDKIdentifier": .string(query.query.uploadPlatformIdentifier), "uniqueDeviceCountFilteredWithTimePeriod": .number(.int(count))])]),
        ])])
    }

    private func pointInfo(_ query: NativeCrashServiceQuery) -> JSONValue {
        var selectable: [String: JSONValue] = ["reportTypeIdentifier": .string("Xcode.Analytics.ReportType.CrashPoint"),
            "analyticsPointIdentifier": .string("stable-issue"), "adamIdentifier": .string(query.adamIdentifier),
            "bundleIdentifier": .string(query.query.bundleIdentifier), "platformSDKIdentifier": .string(query.query.platformIdentifier)]
        if let version = query.query.appVersion { selectable["appVersion"] = .string(version) }
        return .object(["pointIdentifier": .object(["selectableAnalyticsPointIdentifier": .object(selectable),
            "uploadPlatformSDKIdentifier": .string(query.query.uploadPlatformIdentifier)])])
    }

    private func distribution(bundle: String = "example.App") -> JSONValue {
        .object(["header": .object(["analyticsPointIdentifier": .string("stable-issue"), "adamIdentifier": .string("123"),
            "bundleIdentifier": .string(bundle), "lastRefresh": .string("2024-01-02T00:00:00Z")]),
            "body": .object(["timeSeriesDistribution": .object(["timeDistributionMetaDatas": .array([])])])])
    }

    private func listURL(_ root: URL) -> URL { root.appending(path: "example.App/Crashes/ListablePoints.json") }

    private func write(_ value: JSONValue, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try NativeCrashStore.encode(value).write(to: url, options: .atomic)
    }

    private func object(_ value: JSONValue?) throws -> [String: JSONValue] {
        guard case .object(let fields) = value else { throw FixtureError.invalidObject }
        return fields
    }

    private enum FixtureError: Error { case invalidObject }
}
