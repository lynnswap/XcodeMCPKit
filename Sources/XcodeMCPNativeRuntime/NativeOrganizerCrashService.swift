import AppKit
import ApplicationServices
import Darwin
import Foundation
import XcodeMCPWire

/// Lets the signed Xcode process perform authenticated downloads, then reads
/// only the cache entry identified by the complete request.
@safe
@MainActor
final class NativeOrganizerCrashService {
    private let installation: NativeXcodeInstallation
    private let cache: NativeOrganizerCrashCache
    private let timeout: Duration = .seconds(90)

    init(installation: NativeXcodeInstallation, cache: NativeOrganizerCrashCache = .init()) {
        self.installation = installation
        self.cache = cache
    }

    func fetchIssues(_ query: NativeCrashServiceQuery, store: NativeCrashStore) async throws -> NativeCrashData.Fetched {
        try await withOrganizerAccess(query, issueID: nil) { driver, began in
            try await self.waitForList(driver)
            var errors: [JSONValue] = []
            var filters: [String]?
            var precedingNames: [String] = []
            var points: [JSONValue] = []
            var pages: [JSONValue] = []
            var copiedPages: [JSONValue] = []
            var fetchedAt = Self.date(began)
            var index = 0
            while true {
                let pageQuery = query.withPage(index)
                do {
                    let (page, selection) = try await self.waitForPage(pageQuery, began: began, driver: driver,
                        filters: filters, precedingNames: precedingNames)
                    precedingNames += try Self.names(page.points)
                    filters = selection
                    fetchedAt = Self.date(page.fetchedAt)
                    var descriptor: [String: JSONValue] = ["query": pageQuery.json(issueID: nil),
                        "status": .string("complete"), "source": .string("organizer"), "fetchedAt": .string(fetchedAt),
                        "returnedCount": .number(.int(Int64(page.points.count))),
                        "organizerCachePath": .string(page.cacheURL.path),
                        "organizerSelection": .array(selection.map(JSONValue.string))]
                    let fetched = Self.page(page, query: pageQuery)
                    do {
                        let saved = try store.write(fetched.value, key: pageQuery.json(issueID: nil), fetchedAt: fetchedAt)
                        descriptor["cachePath"] = .string(saved.path)
                    } catch {
                        let failure = NativeCrashData.diagnostic(error, operation: "cacheWrite")
                        errors.append(failure)
                        descriptor["status"] = .string("partial")
                        descriptor["errors"] = .array([failure])
                    }
                    copiedPages.append(.object(descriptor))
                    if query.collectsAllPages || index == query.pageIndex {
                        points += page.points
                        pages.append(.object(descriptor))
                    }
                    let terminal = page.points.isEmpty
                    if terminal || (!query.collectsAllPages && index == query.pageIndex) {
                        return Self.collection(query, points: points, pages: pages, copiedPages: copiedPages,
                            fetchedAt: fetchedAt, nextPage: terminal ? nil : index + 1, terminal: terminal,
                            terminalPage: terminal ? index : nil, errors: errors)
                    }
                    index += 1
                    try await driver.scrollToBottom()
                } catch {
                    try Task.checkCancellation()
                    return try Self.collectionAfterFailure(query, points: points, pages: pages, copiedPages: copiedPages,
                        fetchedAt: fetchedAt, failedPage: index, errors: errors, error: error)
                }
            }
        }
    }

    func fetchIssue(_ query: NativeCrashServiceQuery, issueID: String) async throws -> NativeCrashData.Fetched {
        try await withOrganizerAccess(query, issueID: issueID) { driver, began in
            do {
                try await self.waitForList(driver, prepare: false)
                let clock = ContinuousClock()
                let deadline = clock.now.advanced(by: self.timeout)
                var lastErrors: [JSONValue] = []
                repeat {
                    try Task.checkCancellation()
                    let read = self.cache.readIssue(query, issueID: issueID)
                    lastErrors = read.errors
                    if let issue = read.snapshot, let fetchedAt = issue.fetchedAt,
                       fetchedAt >= Self.second(began) {
                        let ui = try await self.snapshot(driver, until: deadline)
                        try self.checkFailure(ui)
                        if ui.busyMessages.isEmpty {
                            return NativeCrashData.Fetched(value: .object(Self.issueValue(issue)),
                                fetchedAt: Self.date(fetchedAt), errors: read.errors)
                        }
                    }
                    let ui = try await self.snapshot(driver, until: deadline)
                    try self.checkFailure(ui)
                    try await Task.sleep(for: .milliseconds(250))
                } while clock.now < deadline
                throw Self.timeoutError("Organizer did not refresh crash issue \(issueID)", errors: lastErrors)
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                return try Self.recoverIssue(self.cache.readIssue(query, issueID: issueID), after: error)
            }
        }
    }

    static func recoverIssue(_ read: NativeOrganizerCrashCache.Read<NativeOrganizerCrashCache.IssueSnapshot>,
                             after error: any Error) throws -> NativeCrashData.Fetched {
        guard let issue = read.snapshot, !issue.logs.isEmpty else { throw error }
        var value = issueValue(issue)
        // Saved samples remain useful after a refresh failure, but their native
        // directory does not establish when each sample was downloaded.
        value["sampleFreshness"] = .string("unverifiedSavedSamples")
        value["cachedDistribution"] = value.removeValue(forKey: "distribution")
        value["cachedDistributionFetchedAt"] = issue.fetchedAt.map { .string(Self.date($0)) } ?? .null
        return NativeCrashData.Fetched(value: .object(value), fetchedAt: nil, source: "organizerCache",
            errors: read.errors + [NativeCrashData.diagnostic(error, operation: "organizerIssueRefresh")])
    }

    private static func issueValue(_ issue: NativeOrganizerCrashCache.IssueSnapshot) -> [String: JSONValue] {
        var value: [String: JSONValue] = [
            "pointInfo": issue.pointInfo, "organizerCachePath": .string(issue.pointInfoURL.path),
            "logs": .array(issue.logs.map { .object([
                "data": .string($0.data.base64EncodedString()), "sourcePath": .string($0.url.path),
            ]) }), "distributionCachePath": .string(issue.distributionURL.path),
        ]
        if let distribution = issue.distribution { value["distribution"] = distribution }
        return value
    }

    static func url(_ query: NativeCrashServiceQuery, issueID: String?) throws -> URL {
        func platform(_ value: String) throws -> String {
            guard let name = ["com.apple.platform.iphoneos": "iOS", "com.apple.platform.macosx": "macOS",
                "com.apple.platform.watchos": "watchOS", "com.apple.platform.appletvos": "tvOS",
                "com.apple.platform.xros": "visionOS"][value] else {
                throw NativeRuntimeError.unsupportedContract("No Organizer URL platform maps to \(value)")
            }
            return name
        }
        var components = URLComponents()
        components.scheme = "xcode"
        components.host = "organizer"
        components.path = "/crashes/" + (issueID == nil ? "listPoints" : "downloadPoint")
        var parameters = ["adamId": query.adamIdentifier, "bundleId": query.bundleIdentifier,
            "platformId": try platform(query.uploadPlatformIdentifier), "installPlatformId": try platform(query.platformIdentifier)]
        if let issueID { parameters["analyticsPointId"] = issueID }
        else {
            parameters["timePeriod"] = query.timePeriod
            parameters["appVersion"] = query.appVersion
            parameters["releaseHistory"] = query.isBeta.map { $0 ? "testFlight" : "appStore" } ?? "all"
        }
        components.queryItems = parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw NativeRuntimeError.invalidRequest("Could not form the Organizer crash URL") }
        return url
    }

    private static func page(_ page: NativeOrganizerCrashCache.PageSnapshot, query: NativeCrashServiceQuery) -> NativeCrashData.Fetched {
        NativeCrashData.Fetched(value: .object(["points": .array(page.points), "organizerCache": page.native,
            "organizerCachePath": .string(page.cacheURL.path), "organizerCacheKey": page.key,
        ]), fetchedAt: date(page.fetchedAt))
    }

    static func collectionAfterFailure(_ query: NativeCrashServiceQuery, points: [JSONValue], pages: [JSONValue],
                                       copiedPages: [JSONValue], fetchedAt: String, failedPage: Int,
                                       errors: [JSONValue], error: any Error) throws -> NativeCrashData.Fetched {
        let failure = NativeCrashData.diagnostic(error, operation: "organizerPage\(failedPage)")
        let failures = errors + [failure]
        // Prefix pages are saved separately; they cannot satisfy a request for
        // a later single page or replace its existing cached result.
        guard query.collectsAllPages, !copiedPages.isEmpty else {
            throw timeoutError("Organizer could not collect crash issues", errors: failures)
        }
        let failed: JSONValue = .object(["query": query.withPage(failedPage).json(issueID: nil),
            "status": .string("failed"), "errors": .array([failure])])
        return collection(query, points: points, pages: pages + [failed], copiedPages: copiedPages,
            fetchedAt: fetchedAt, nextPage: failedPage, terminal: false, errors: failures)
    }

    private static func collection(_ query: NativeCrashServiceQuery, points: [JSONValue], pages: [JSONValue],
                                   copiedPages: [JSONValue], fetchedAt: String, nextPage: Int?, terminal: Bool,
                                   terminalPage: Int? = nil, errors: [JSONValue]) -> NativeCrashData.Fetched {
        NativeCrashData.Fetched(value: .object(["points": .array(points), "pages": .array(pages),
            "copiedPages": .array(copiedPages), "pagination": .object([
                "mode": .string(query.collectsAllPages ? "allPages" : "singlePage"),
                "page": .number(.int(Int64(query.pageIndex))), "pageSize": .number(.int(Int64(query.pageSize))),
                "returnedCount": .number(.int(Int64(points.count))), "endReached": .bool(terminal),
                "terminalPage": terminalPage.map { .number(.int(Int64($0))) } ?? .null,
                "hasMore": terminal ? .bool(false) : .null,
                "nextPage": nextPage.map { .number(.int(Int64($0))) } ?? .null,
                "continuationRequiresProbe": .bool(!terminal),
            ])]), fetchedAt: fetchedAt, errors: errors)
    }

    private func waitForPage(_ query: NativeCrashServiceQuery, began: Date,
                             driver: NativeOrganizerAccessibility, filters: [String]?, precedingNames: [String]) async throws -> (NativeOrganizerCrashCache.PageSnapshot, [String]) {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var lastErrors: [JSONValue] = []
        repeat {
            try Task.checkCancellation()
            let read = cache.readPage(query)
            lastErrors = read.errors
            let ui = try await snapshot(driver, until: deadline)
            try checkFailure(ui)
            if let filters, filters != ui.filterValues {
                throw NativeRuntimeError.unavailable("Organizer's filters changed while collecting crash pages; retry the requested page")
            }
            if let page = read.snapshot, page.fetchedAt >= Self.second(began), ui.busyMessages.isEmpty {
                // Organizer re-sorts equal-count issues, including ties across
                // page boundaries. Compare cumulative multiplicities, not ranks.
                if Self.displays(precedingNames + (try Self.names(page.points)), rows: ui.rows) {
                    return (page, ui.filterValues)
                }
            }
            try await Task.sleep(for: .milliseconds(250))
        } while clock.now < deadline
        throw Self.timeoutError("Organizer did not refresh the requested crash page \(query.pageIndex)", errors: lastErrors)
    }

    static func displays(_ names: [String], rows: [String]) -> Bool {
        let expected = Dictionary(names.map { ($0, 1) }, uniquingKeysWith: +)
        let visible = Dictionary(rows.map { ($0, 1) }, uniquingKeysWith: +)
        return expected.allSatisfy { visible[$0.key, default: 0] >= $0.value }
    }

    private static func names(_ points: [JSONValue]) throws -> [String] {
        try points.map { point in
            guard case .object(let fields) = point, case .string(let name) = fields["analyticsPointName"] else {
                throw NativeRuntimeError.unsupportedContract("An Organizer crash point has no analyticsPointName")
            }
            return name
        }
    }

    private func waitForList(_ driver: NativeOrganizerAccessibility, prepare: Bool = true) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var failure: (any Error)?
        repeat {
            try Task.checkCancellation()
            do {
                let snapshot = try driver.snapshot()
                try checkFailure(snapshot)
                if snapshot.busyMessages.isEmpty {
                    if prepare { try driver.prepareList() }
                    return
                }
            }
            catch { failure = error }
            try await Task.sleep(for: .milliseconds(250))
        } while clock.now < deadline
        throw failure ?? NativeRuntimeError.unavailable("Organizer did not open its crash list")
    }

    private func snapshot(_ driver: NativeOrganizerAccessibility, until deadline: ContinuousClock.Instant) async throws -> NativeOrganizerAccessibility.Snapshot {
        repeat {
            try Task.checkCancellation()
            do { return try driver.snapshot() }
            catch where Self.isTransientAccessibility(error) {
                guard ContinuousClock().now < deadline else { throw error }
                try await Task.sleep(for: .milliseconds(250))
            }
        } while true
    }

    private static func isTransientAccessibility(_ error: any Error) -> Bool {
        if error is NativeOrganizerAccessibility.ViewUpdating { return true }
        let error = error as NSError
        guard error.domain == "XcodeMCPKit.OrganizerAccessibility" else { return false }
        // Xcode also reports illegalArgument for previously valid AX elements
        // while replacing its SwiftUI rows. Re-resolve the entire read snapshot;
        // a repeated failure still reaches the operation's deadline.
        if error.code == Int(ApplicationServices.AXError.illegalArgument.rawValue) {
            return error.userInfo["AXAttribute"] is String
        }
        return [Int(ApplicationServices.AXError.invalidUIElement.rawValue), Int(ApplicationServices.AXError.cannotComplete.rawValue)].contains(error.code)
    }

    private func withOrganizerAccess(_ query: NativeCrashServiceQuery, issueID: String?,
        _ operation: (NativeOrganizerAccessibility, Date) async throws -> NativeCrashData.Fetched) async throws -> NativeCrashData.Fetched {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/XcodeMCPKit/Organizer", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("products.lock")
        if !FileManager.default.fileExists(atPath: path.path) { FileManager.default.createFile(atPath: path.path, contents: Data()) }
        let file = try FileHandle(forUpdating: path)
        // Every Xcode instance shares the Products disk cache. Serialize our
        // collectors across processes, and release the lock after GUI shutdown.
        var owned: NativeOrganizerApplication?
        let outcome: Result<NativeCrashData.Fetched, any Error>
        do {
            while flock(file.fileDescriptor, LOCK_EX | LOCK_NB) != 0 {
                let code = errno
                guard code == EWOULDBLOCK else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
                try await Task.sleep(for: .milliseconds(100))
            }
            try Task.checkCancellation()
            let began = try await Self.refreshBoundary()
            let application = try await NativeOrganizerApplication.launch(installation: installation, url: Self.url(query, issueID: issueID))
            owned = application
            try Task.checkCancellation()
            let driver = try NativeOrganizerAccessibility(installation: installation, application: application.application)
            outcome = .success(try await operation(driver, began))
        } catch { outcome = .failure(error) }
        var cleanup: [NSError] = []
        if let owned {
            // An unstructured cleanup task finishes even when the request was cancelled.
            let shutdown = Task { @MainActor in try await owned.shutdown() }
            do { try await shutdown.value }
            catch { cleanup.append(error as NSError) }
        }
        do { try file.close() }
        catch { cleanup.append(error as NSError) }
        if Task.isCancelled, !cleanup.isEmpty {
            let original: any Error
            if case .failure(let failure) = outcome { original = failure }
            else { original = CancellationError() }
            let failure = Self.cleanupFailure(original, cleanup: cleanup)
            NativeExecutionOperations.scope?.recordFailure(failure)
            try? FileHandle.standardError.write(contentsOf: Data("Organizer cleanup after cancellation: \(failure)\n".utf8))
        }
        switch outcome {
        case .success(var result):
            result.errors += cleanup.map { NativeCrashData.diagnostic($0, operation: "organizerCleanup") }
            if let owned, case .object(var value) = result.value {
                value["organizerProcessId"] = .number(.int(Int64(owned.processIdentifier)))
                value["organizerTerminated"] = .bool(owned.application.isTerminated)
                result = NativeCrashData.Fetched(value: .object(value), fetchedAt: result.fetchedAt,
                    source: result.source, errors: result.errors)
            }
            return result
        case .failure(let original):
            guard !cleanup.isEmpty else { throw original }
            throw Self.cleanupFailure(original, cleanup: cleanup)
        }
    }

    private static func cleanupFailure(_ original: any Error, cleanup: [NSError]) -> NSError {
        NSError(domain: "XcodeMCPKit.Organizer", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Organizer collection and cleanup failed",
                       NSMultipleUnderlyingErrorsKey: [original as NSError] + cleanup])
    }

    private func checkFailure(_ snapshot: NativeOrganizerAccessibility.Snapshot) throws {
        guard snapshot.errorMessages.isEmpty else {
            throw NativeRuntimeError.unavailable("Organizer: " + snapshot.errorMessages.joined(separator: "\n"))
        }
        guard snapshot.busyMessages.isEmpty, !snapshot.listStatusMessages.isEmpty else { return }
        let url = installation.framework("DVTAnalytics", in: "SharedFrameworks").deletingLastPathComponent()
            .appendingPathComponent("Resources/DVTAnalytics.xcplugindata")
        guard let root = try unsafe PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any],
              let plugin = root["plug-in"] as? [String: Any], let extensions = plugin["extensions"] as? [String: Any],
              let report = extensions["Xcode.Analytics.ReportType.CrashPoint"] as? [String: Any] else {
            throw NativeRuntimeError.unsupportedContract("Xcode does not provide its crash-list status descriptions")
        }
        let normal = Set(["emptyContentString", "noLogsForFilterSelectionDescription", "noLogsDescription", "previousTopPointsDescription"]
            .compactMap { report[$0] as? String })
        let failures = snapshot.listStatusMessages.filter { !normal.contains($0) }
        guard failures.isEmpty else {
            throw NativeRuntimeError.unavailable("Organizer crash-list status: " + failures.joined(separator: "\n"))
        }
    }

    private static func second(_ date: Date) -> Date { Date(timeIntervalSince1970: floor(date.timeIntervalSince1970)) }
    private static func refreshBoundary() async throws -> Date {
        // Organizer serializes refresh dates to whole seconds. Begin in a new
        // second so an unchanged entry cannot look like this operation's result.
        let boundary = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) + 1)
        try await Task.sleep(for: .seconds(max(0, boundary.timeIntervalSinceNow)))
        return boundary
    }
    private static func date(_ value: Date) -> String { ISO8601DateFormatter().string(from: value) }
    private static func timeoutError(_ message: String, errors: [JSONValue]) -> NSError {
        return NSError(domain: "XcodeMCPKit.Organizer", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message, "XcodeMCPKit.CrashDiagnostics": errors.map(\.foundationObject)])
    }
}

extension NativeCrashServiceQuery {
    func withPage(_ page: Int) -> Self {
        Self(adamIdentifier: adamIdentifier, bundleIdentifier: bundleIdentifier, platformIdentifier: platformIdentifier,
             uploadPlatformIdentifier: uploadPlatformIdentifier, appVersion: appVersion, isBeta: isBeta,
             timePeriod: timePeriod, pageIndex: page, pageSize: pageSize)
    }
}
