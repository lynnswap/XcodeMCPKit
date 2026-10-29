import Foundation
import Testing
import XcodeMCPWire
@testable import XcodeMCPNativeRuntime

@Suite
@MainActor
struct NativeOrganizerCrashServiceTests {
    @Test func missingSavedSamplesPermitARefreshWhileReadFailuresKeepBothDiagnostics() throws {
        let root = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = root.appending(path: "Xcode.app/Contents")
        try FileManager.default.createDirectory(at: contents.appending(path: "Frameworks/IDEFoundation.framework"),
                                               withIntermediateDirectories: true)
        let installation = try NativeXcodeInstallation(developerDirectory: contents.appending(component: "Developer"))
        let products = root.appending(component: "Products")
        let service = NativeOrganizerCrashService(installation: installation,
            cache: NativeOrganizerCrashCache(productsRoot: products))
        let request = NativeCrashServiceQuery(query: NativeCrashQuery(bundleIdentifier: "example.App",
            platformIdentifier: "com.apple.platform.iphoneos", uploadPlatformIdentifier: "com.apple.platform.iphoneos",
            appVersion: nil, isBeta: nil, timePeriod: "last14Days", pageIndex: 0, pageSize: 25), adamIdentifier: "123")
        let original = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        #expect(try service.savedIssueIfAvailable(request, issueID: "stable-issue", after: original) == nil)
        let point = products.appending(path: "example.App/Crashes/Points/stable-issue.xccrashpoint/Filters/all/PointInfo.json")
        try FileManager.default.createDirectory(at: point.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("invalid JSON".utf8).write(to: point)

        do {
            _ = try service.savedIssueIfAvailable(request, issueID: "stable-issue", after: original)
            Issue.record("An unreadable saved sample scope must retain its read failure")
        } catch {
            let failure = NativeCrashData.diagnostic(error, operation: "recovery")
            #expect(try nativeTestField(failure, "underlyingError", "domain") == .string(NSURLErrorDomain))
            #expect(try nativeTestField(failure, "underlyingError", "code") == .number(.int(Int64(NSURLErrorTimedOut))))
            guard case .array(let cacheErrors) = try nativeTestField(failure, "cacheErrors") else {
                Issue.record("Saved-sample recovery must preserve cache-read diagnostics")
                return
            }
            let readFailure = try #require(cacheErrors.first)
            #expect(try nativeTestField(readFailure, "operation") == .string("organizerPointRead"))
            guard case .string(let path) = try nativeTestField(readFailure, "path") else {
                Issue.record("Saved-sample diagnostics must identify the unreadable file")
                return
            }
            #expect(URL(filePath: path).resolvingSymlinksInPath() == point.resolvingSymlinksInPath())
        }
    }

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
    @Test func interruptedAcquisitionRetainsReadablePagesAndReportsMissingPages() throws {
        let root = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeCrashStore(root: root)
        let query = NativeCrashQuery(bundleIdentifier: "example.App", platformIdentifier: "com.apple.platform.iphoneos",
            uploadPlatformIdentifier: "com.apple.platform.iphoneos", appVersion: nil, isBeta: nil,
            timePeriod: "last365Days", pageIndex: 0, pageSize: 25, collectsAllPages: true)
        let request = NativeCrashServiceQuery(query: query, adamIdentifier: "123")
        let points: [JSONValue] = [.object(["analyticsPointIdentifier": .string("captured"),
            "analyticsPointName": .string("Example.crash()")])]
        _ = try store.write(.object(["points": .array(points)]), key: request.withPage(0).query.json(issueID: nil),
                            fetchedAt: "2024-01-01T00:00:00Z")
        let descriptors: [JSONValue] = (0...1).map { .object(["query": request.withPage($0).query.json(issueID: nil)]) }

        let recovered = try #require(try NativeOrganizerCrashService.savedPages(request.query, store: store,
            descriptors: descriptors, after: CancellationError()))

        #expect(!recovered.isComplete)
        #expect(try nativeTestField(recovered.value, "points") == .array(points))
        try #require(recovered.errors.count == 2)
        #expect(try nativeTestField(recovered.errors[0], "operation") == .string("organizerAcquisition"))
        #expect(try nativeTestField(recovered.errors[1], "operation") == .string("jobPageRecovery"))
        #expect(try nativeTestField(recovered.value, "pagination", "endReached") == .bool(false))
    }

    @Test func temporaryWindowHeightRestoresEveryOriginalBound() async throws {
        let original = NativeOrganizerAccessibility.WindowBounds(top: 100, left: 80, bottom: 900, right: 1280)
        var bounds = original

        try await NativeOrganizerAccessibility.withTemporaryWindowHeight(240, readBounds: { bounds },
            writeBounds: { bounds = $0 }, operation: {
                #expect(bounds == NativeOrganizerAccessibility.WindowBounds(top: 100, left: 80, bottom: 340, right: 1280))
            })

        #expect(bounds == original)
    }

    @Test func temporaryWindowHeightRetainsOperationAndRestoreFailures() async throws {
        let original = NativeOrganizerAccessibility.WindowBounds(top: 100, left: 80, bottom: 900, right: 1280)
        let operationFailure = NSError(domain: "OrganizerOperation", code: 7)
        let restoreFailure = NSError(domain: "OrganizerWindowRestore", code: 8)

        do {
            try await NativeOrganizerAccessibility.withTemporaryWindowHeight(240, readBounds: { original },
                writeBounds: { if $0 == original { throw restoreFailure } },
                operation: { throw operationFailure })
            Issue.record("Operation and window restoration failures must remain available together")
        } catch {
            let errors = try #require((error as NSError).userInfo[NSMultipleUnderlyingErrorsKey] as? [NSError])
            #expect(errors.count == 2)
            #expect(errors[0] === operationFailure)
            #expect(errors[1] === restoreFailure)
        }
    }

    @Test func temporaryWindowHeightRestoresBoundsAfterOperationCancellation() async throws {
        let original = NativeOrganizerAccessibility.WindowBounds(top: 100, left: 80, bottom: 900, right: 1280)
        var bounds = original
        let task = Task { @MainActor in
            try await NativeOrganizerAccessibility.withTemporaryWindowHeight(240, readBounds: { bounds },
                writeBounds: {
                    try Task.checkCancellation()
                    bounds = $0
                }, operation: {
                    unsafe withUnsafeCurrentTask { unsafe $0?.cancel() }
                    try Task.checkCancellation()
                })
        }

        do {
            try await task.value
            Issue.record("The operation cancellation must remain observable")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(bounds == original)
    }

}
