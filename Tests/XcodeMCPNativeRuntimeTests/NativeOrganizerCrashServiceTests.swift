import Foundation
import Testing
import XcodeMCPWire
@testable import XcodeMCPNativeRuntime

@Suite
@MainActor
struct NativeOrganizerCrashServiceTests {
    @Test func aSinglePagePrefixFailureUsesTheOriginalRequestedCache() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeCrashStore(root: root)
        let query = NativeCrashServiceQuery(query: NativeCrashQuery(bundleIdentifier: "example.App",
            platformIdentifier: "com.apple.platform.iphoneos", uploadPlatformIdentifier: "com.apple.platform.iphoneos",
            appVersion: nil, isBeta: nil, timePeriod: "last14Days", pageIndex: 2, pageSize: 25), adamIdentifier: "1234567890")
        let requestedKey = query.query.json(issueID: nil)
        let prefixKey = query.withPage(0).query.json(issueID: nil)
        let requested: JSONValue = .object(["points": .array([.object([
            "analyticsPointIdentifier": .string("requested-issue"), "analyticsPointName": .string("Requested.crash()"),
        ])])])
        let prefix: JSONValue = .object(["points": .array([.object([
            "analyticsPointIdentifier": .string("prefix-issue"), "analyticsPointName": .string("Prefix.crash()"),
        ])])])
        let cachedFailure: JSONValue = .object(["operation": .string("cacheWrite"), "message": .string("A previous partial result")])
        let originalTime = "2024-01-01T00:00:00Z"
        _ = try store.write(requested, key: requestedKey, fetchedAt: originalTime, errors: [cachedFailure])
        _ = try store.write(prefix, key: prefixKey, fetchedAt: "2024-01-02T00:00:00Z")

        let loaded = try await NativeCrashData.load(key: requestedKey, source: .networkWithCacheFallback, store: store) {
            try NativeOrganizerCrashService.collectionAfterFailure(query, points: [], pages: [],
                copiedPages: [.object(["query": prefixKey, "status": .string("complete")])],
                fetchedAt: "2024-01-02T00:00:00Z", failedPage: 1, errors: [],
                error: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut))
        }

        #expect(loaded.source == "cache")
        #expect(loaded.value == requested)
        #expect(loaded.fetchedAt == originalTime)
        #expect(loaded.errors.contains(cachedFailure))
        #expect(loaded.errors.count == 2)
        let retained = try #require(try store.read(key: requestedKey))
        #expect(retained.value == requested)
        #expect(retained.fetchedAt == originalTime)
        #expect(retained.errors == [cachedFailure])
        #expect(try store.read(key: prefixKey)?.value == prefix)
    }

    @Test func allPageAndSinglePageCachesRemainSeparate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeCrashStore(root: root)
        let single = NativeCrashQuery(bundleIdentifier: "example.App",
            platformIdentifier: "com.apple.platform.iphoneos", uploadPlatformIdentifier: "com.apple.platform.iphoneos",
            appVersion: nil, isBeta: nil, timePeriod: "last14Days", pageIndex: 0, pageSize: 25)
        var batch = single
        batch.collectsAllPages = true
        let singleKey = single.json(issueID: nil)
        let batchKey = batch.json(issueID: nil)
        _ = try store.write(.string("single-page"), key: singleKey, fetchedAt: "2024-01-01T00:00:00Z")
        _ = try store.write(.string("all-pages"), key: batchKey, fetchedAt: "2024-01-01T00:00:00Z")

        #expect(try store.read(key: singleKey)?.value == .string("single-page"))
        #expect(try store.read(key: batchKey)?.value == .string("all-pages"))
        #expect(batch.withPage(0).json(issueID: nil) == singleKey)
    }

    @Test func refreshedIdlePageIsReadyWithoutMatchingDisplayedIssueNames() {
        let began = Date(timeIntervalSince1970: 1_000)
        let page = NativeOrganizerCrashCache.PageSnapshot(native: .null, fetchedAt: began,
            cacheURL: URL(filePath: "/unused/ListablePoints.json"), points: [.object([
                "analyticsPointIdentifier": .string("same-issue"),
                "analyticsPointName": .string("UIKitCore: 0x180000000 + 1234"),
            ])], pageIndex: 0, pageSize: 25, key: .null)
        let idle = NativeOrganizerAccessibility.Snapshot(busyMessages: [], listStatusMessages: [])

        #expect(NativeOrganizerCrashService.isReady(page, since: began, snapshot: idle))
        #expect(!NativeOrganizerCrashService.isReady(page, since: began.addingTimeInterval(1), snapshot: idle))
        let loading = NativeOrganizerAccessibility.Snapshot(busyMessages: ["Loading"], listStatusMessages: [])
        #expect(!NativeOrganizerCrashService.isReady(page, since: began, snapshot: loading))
    }

    @Test func listURLKeepsStoreAndExecutionPlatformsDistinctAndEscapesFilters() throws {
        let version = "2.0+beta & build/1?#"
        let query = NativeCrashServiceQuery(query: NativeCrashQuery(bundleIdentifier: "example.App",
            platformIdentifier: "com.apple.platform.macosx", uploadPlatformIdentifier: "com.apple.platform.iphoneos",
            appVersion: version, isBeta: true, timePeriod: "last365Days", pageIndex: 2, pageSize: 25), adamIdentifier: "1234567890")

        let url = try NativeOrganizerCrashService.url(query, issueID: nil)

        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "xcode")
        #expect(components.host == "organizer")
        #expect(components.path == "/crashes/listPoints")
        let values = try Dictionary(uniqueKeysWithValues: try #require(components.queryItems).map {
            ($0.name, try #require($0.value))
        })
        #expect(values == ["adamId": "1234567890", "bundleId": "example.App", "platformId": "iOS",
                           "installPlatformId": "macOS", "timePeriod": "last365Days", "appVersion": version,
                           "releaseHistory": "testFlight"])
    }

    @Test func detailURLSelectsTheStableIssueWithoutClaimingListFilters() throws {
        let query = NativeCrashServiceQuery(query: NativeCrashQuery(bundleIdentifier: "example.App",
            platformIdentifier: "com.apple.platform.macosx", uploadPlatformIdentifier: "com.apple.platform.iphoneos",
            appVersion: "2.0", isBeta: false, timePeriod: "last14Days", pageIndex: 0, pageSize: 25), adamIdentifier: "1234567890")

        let url = try NativeOrganizerCrashService.url(query, issueID: "stable-issue-ID")

        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.path == "/crashes/downloadPoint")
        let values = try Dictionary(uniqueKeysWithValues: try #require(components.queryItems).map {
            ($0.name, try #require($0.value))
        })
        #expect(values == ["adamId": "1234567890", "bundleId": "example.App", "platformId": "iOS",
                           "installPlatformId": "macOS", "analyticsPointId": "stable-issue-ID"])
    }
}
