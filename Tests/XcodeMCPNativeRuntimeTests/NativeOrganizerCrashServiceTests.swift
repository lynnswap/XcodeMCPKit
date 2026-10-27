import Foundation
import Testing
@testable import XcodeMCPNativeRuntime

@Suite
@MainActor
struct NativeOrganizerCrashServiceTests {
    @Test func equalCountIssuesCanMoveAcrossPageBoundariesWithoutChangingTheCollection() {
        let rows = ["other", "same", "first", "same"].map { NativeOrganizerAccessibility.Row(name: $0, displayText: $0) }
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
