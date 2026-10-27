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
        let query = NativeCrashServiceQuery(adamIdentifier: "1234567890", bundleIdentifier: "example.App",
            platformIdentifier: "com.apple.platform.iphoneos", uploadPlatformIdentifier: "com.apple.platform.iphoneos",
            appVersion: nil, isBeta: nil, timePeriod: "last14Days", pageIndex: 2, pageSize: 25)
        let requestedKey = query.json(issueID: nil)
        let prefixKey = query.withPage(0).json(issueID: nil)
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
        let single = NativeCrashServiceQuery(adamIdentifier: "1234567890", bundleIdentifier: "example.App",
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

    @Test func equalCountIssuesCanMoveAcrossPageBoundariesWithoutChangingTheCollection() {
        let rows = ["other", "same", "first", "same"]
        #expect(NativeOrganizerCrashService.displays(["first", "same", "same", "other"], rows: rows))
        #expect(!NativeOrganizerCrashService.displays(["same", "same", "same"], rows: rows))
    }
    @Test func listURLKeepsStoreAndExecutionPlatformsDistinctAndEscapesFilters() throws {
        let version = "2.0+beta & build/1?#"
        let query = NativeCrashServiceQuery(adamIdentifier: "1234567890", bundleIdentifier: "example.App",
            platformIdentifier: "com.apple.platform.macosx", uploadPlatformIdentifier: "com.apple.platform.iphoneos",
            appVersion: version, isBeta: true, timePeriod: "last365Days", pageIndex: 2, pageSize: 25)

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
        let query = NativeCrashServiceQuery(adamIdentifier: "1234567890", bundleIdentifier: "example.App",
            platformIdentifier: "com.apple.platform.macosx", uploadPlatformIdentifier: "com.apple.platform.iphoneos",
            appVersion: "2.0", isBeta: false, timePeriod: "last14Days", pageIndex: 0, pageSize: 25)

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
