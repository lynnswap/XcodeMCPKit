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

    func fetchPage(_ query: NativeCrashServiceQuery, store: NativeCrashStore) async throws -> NativeCrashData.Fetched {
        try await withOrganizerAccess { driver in
            let began = try await Self.refreshBoundary()
            try await self.open(Self.url(query, issueID: nil))
            // Opening the route selects the exact product and filters. Reload is
            // separate so an already selected, cached list is refreshed as well.
            try await self.waitForList(driver)
            try driver.prepareList()
            try await self.reload(driver)
            var last: NativeOrganizerCrashCache.PageSnapshot?
            var errors: [JSONValue] = []
            var filters: [String]?
            var precedingNames: [String] = []
            for index in 0...query.pageIndex {
                let pageQuery = query.withPage(index)
                let (page, selection) = try await self.waitForPage(pageQuery, began: began, driver: driver, filters: filters, precedingNames: precedingNames)
                precedingNames += try Self.names(page.points)
                filters = selection
                last = page
                var fetched = Self.page(page, query: pageQuery)
                if case .object(var value) = fetched.value {
                    value["organizerSelection"] = .array(selection.map(JSONValue.string))
                    fetched = NativeCrashData.Fetched(value: .object(value), fetchedAt: fetched.fetchedAt)
                }
                do { _ = try store.write(fetched.value, key: pageQuery.json(issueID: nil), fetchedAt: fetched.fetchedAt) }
                catch { errors.append(NativeCrashData.diagnostic(error, operation: "cacheWrite")) }
                fetched.errors += errors
                if index == query.pageIndex { return fetched }
                if page.points.isEmpty {
                    return NativeCrashData.Fetched(value: .object([
                        "points": .array([]), "terminalPage": .number(.int(Int64(index))),
                        "organizerCache": page.native, "organizerCachePath": .string(page.cacheURL.path),
                    ]), fetchedAt: Self.date(page.fetchedAt), errors: errors)
                }
                try driver.scrollToBottom()
            }
            throw NativeRuntimeError.unavailable("Organizer did not return the requested crash page after \(last?.pageIndex ?? -1)")
        }
    }

    func fetchIssue(_ query: NativeCrashServiceQuery, issueID: String) async throws -> NativeCrashData.Fetched {
        try await withOrganizerAccess { driver in
            let began = try await Self.refreshBoundary()
            try await self.open(Self.url(query, issueID: issueID))
            try await self.waitForList(driver)
            try driver.prepareList()
            try await self.reload(driver)
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: self.timeout)
            var lastErrors: [JSONValue] = []
            repeat {
                try Task.checkCancellation()
                let read = self.cache.readIssue(query, issueID: issueID)
                lastErrors = read.errors
                if let issue = read.snapshot, let fetchedAt = issue.fetchedAt,
                   fetchedAt >= Self.second(began) {
                    var value: [String: JSONValue] = [
                        "pointInfo": issue.pointInfo,
                        "organizerCachePath": .string(issue.pointInfoURL.path),
                        "logs": .array(issue.logs.map { .object([
                            "data": .string($0.data.base64EncodedString()), "sourcePath": .string($0.url.path),
                        ]) }),
                    ]
                    if let distribution = issue.distribution { value["distribution"] = distribution }
                    value["distributionCachePath"] = .string(issue.distributionURL.path)
                    let ui = try await self.snapshot(driver, until: deadline)
                    try Self.checkFailure(ui)
                    if ui.busyMessages.isEmpty {
                        return NativeCrashData.Fetched(value: .object(value), fetchedAt: Self.date(fetchedAt), errors: read.errors)
                    }
                }
                let ui = try await self.snapshot(driver, until: deadline)
                try Self.checkFailure(ui)
                try await Task.sleep(for: .milliseconds(250))
            } while clock.now < deadline
            throw Self.timeoutError("Organizer did not refresh crash issue \(issueID)", errors: lastErrors)
        }
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
            try Self.checkFailure(ui)
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

    static func displays(_ names: [String], rows: [NativeOrganizerAccessibility.Row]) -> Bool {
        let expected = Dictionary(names.map { ($0, 1) }, uniquingKeysWith: +)
        let visible = Dictionary(rows.map { ($0.name, 1) }, uniquingKeysWith: +)
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

    private func waitForList(_ driver: NativeOrganizerAccessibility) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var failure: (any Error)?
        repeat {
            try Task.checkCancellation()
            do {
                let snapshot = try driver.snapshot()
                try Self.checkFailure(snapshot)
                if snapshot.busyMessages.isEmpty { return }
            }
            catch { failure = error }
            try await Task.sleep(for: .milliseconds(250))
        } while clock.now < deadline
        throw failure ?? NativeRuntimeError.unavailable("Organizer did not open its crash list")
    }

    private func open(_ url: URL) async throws {
        let options = NSWorkspace.OpenConfiguration()
        options.activates = false
        _ = try await NSWorkspace.shared.open([url], withApplicationAt: installation.contentsDirectory.deletingLastPathComponent(), configuration: options)
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

    private func reload(_ driver: NativeOrganizerAccessibility) async throws {
        let deadline = ContinuousClock().now.advanced(by: timeout)
        repeat {
            try Task.checkCancellation()
            do { try driver.reload(); return }
            catch where Self.isTransientAccessibility(error) {
                guard ContinuousClock().now < deadline else { throw error }
                try await Task.sleep(for: .milliseconds(250))
            }
        } while true
    }

    private static func isTransientAccessibility(_ error: any Error) -> Bool {
        let error = error as NSError
        return error.domain == "XcodeMCPKit.OrganizerAccessibility"
            && [Int(ApplicationServices.AXError.invalidUIElement.rawValue), Int(ApplicationServices.AXError.cannotComplete.rawValue)].contains(error.code)
    }

    private func withOrganizerAccess(_ operation: (NativeOrganizerAccessibility) async throws -> NativeCrashData.Fetched) async throws -> NativeCrashData.Fetched {
        let driver = try NativeOrganizerAccessibility(installation: installation)
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/XcodeMCPKit/Organizer", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("\(driver.processIdentifier).lock")
        if !FileManager.default.fileExists(atPath: path.path) { FileManager.default.createFile(atPath: path.path, contents: Data()) }
        let file = try FileHandle(forUpdating: path)
        // A single GUI Organizer is shared by all native hosts, including hosts
        // owned by other proxy processes. Closing the descriptor releases flock.
        do {
            while flock(file.fileDescriptor, LOCK_EX | LOCK_NB) != 0 {
                let code = errno
                guard code == EWOULDBLOCK else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
                try await Task.sleep(for: .milliseconds(100))
            }
            try Task.checkCancellation()
            var result = try await operation(driver)
            do { try file.close() }
            catch { result.errors.append(NativeCrashData.diagnostic(error, operation: "organizerLockRelease")) }
            return result
        } catch {
            let original = error
            do { try file.close() }
            catch {
                throw NSError(domain: "XcodeMCPKit.Organizer", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Organizer collection failed and its lock could not be closed",
                               NSMultipleUnderlyingErrorsKey: [original as NSError, error as NSError]])
            }
            throw original
        }
    }

    private static func checkFailure(_ snapshot: NativeOrganizerAccessibility.Snapshot) throws {
        guard snapshot.errorMessages.isEmpty else {
            throw NativeRuntimeError.unavailable("Organizer: " + snapshot.errorMessages.joined(separator: "\n"))
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
