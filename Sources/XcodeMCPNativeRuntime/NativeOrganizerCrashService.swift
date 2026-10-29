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
    private let organizerRoot: URL?
    private let launchOrganizer: (NativeXcodeInstallation) async throws -> NativeOrganizerApplication
    private let recoverApplication: (JSONValue) async throws -> Void
    private var owner: Owner?

    private struct Owner {
        let application: NativeOrganizerApplication
        let directory: URL
        let lease: FileHandle
        var requestedURLs: Set<URL> = []
        var reusable = true
    }

    init(installation: NativeXcodeInstallation, cache: NativeOrganizerCrashCache = .init(),
         organizerRoot: URL? = nil,
         launchOrganizer: @escaping (NativeXcodeInstallation) async throws -> NativeOrganizerApplication = {
             try await NativeOrganizerApplication.launch(installation: $0)
         },
         recoverApplication: @escaping (JSONValue) async throws -> Void = {
             try await NativeOrganizerApplication.shutdownRecovered($0)
         }) {
        self.installation = installation
        self.cache = cache
        self.organizerRoot = organizerRoot
        self.launchOrganizer = launchOrganizer
        self.recoverApplication = recoverApplication
    }

    typealias Observer = @MainActor ([String: JSONValue]) throws -> Void

    func fetchIssues(_ request: NativeCrashServiceQuery, store: NativeCrashStore,
                     observe: Observer? = nil) async throws -> NativeCrashData.Fetched {
        try await withOrganizerAccess(request, issueID: nil, observe: observe) { driver, began in
            try await self.waitForList(driver)
            var errors: [JSONValue] = []
            var points: [JSONValue] = []
            var pages: [JSONValue] = []
            var copiedPages: [JSONValue] = []
            var fetchedAt = Self.date(began)
            var index = 0
            while true {
                let pageQuery = request.withPage(index)
                do {
                    let page = try await self.waitForPage(pageQuery, began: began, driver: driver)
                    fetchedAt = Self.date(page.fetchedAt)
                    var descriptor: [String: JSONValue] = ["query": pageQuery.query.json(issueID: nil),
                        "status": .string("complete"), "source": .string("organizer"), "fetchedAt": .string(fetchedAt),
                        "returnedCount": .number(.int(Int64(page.points.count))),
                        "organizerCachePath": .string(page.cacheURL.path)]
                    let fetched = Self.page(page)
                    do {
                        let saved = try store.write(fetched.value, key: pageQuery.query.json(issueID: nil), fetchedAt: fetchedAt)
                        descriptor["cachePath"] = .string(saved.path)
                    } catch {
                        let failure = NativeCrashData.diagnostic(error, operation: "cacheWrite")
                        errors.append(failure)
                        descriptor["status"] = .string("partial")
                        descriptor["errors"] = .array([failure])
                    }
                    copiedPages.append(.object(descriptor))
                    if request.query.collectsAllPages || index == request.query.pageIndex {
                        points += page.points
                        pages.append(.object(descriptor))
                    }
                    let terminal = page.points.isEmpty
                    try observe?(["phase": .string("acquiring"),
                        "capturedPages": .number(.int(Int64(copiedPages.count))),
                        "capturedRecords": .number(.int(Int64(points.count))),
                        "pages": .array(copiedPages)])
                    if terminal || (!request.query.collectsAllPages && index == request.query.pageIndex) {
                        return Self.collection(request.query, points: points, pages: pages, copiedPages: copiedPages,
                            fetchedAt: fetchedAt, nextPage: terminal ? nil : index + 1, terminal: terminal,
                            terminalPage: terminal ? index : nil, errors: errors)
                    }
                    index += 1
                } catch {
                    if Task.isCancelled || error is CancellationError { throw error }
                    return try Self.collectionAfterFailure(request, points: points, pages: pages, copiedPages: copiedPages,
                        fetchedAt: fetchedAt, failedPage: index, errors: errors, error: error)
                }
            }
        }
    }

    func fetchIssue(_ request: NativeCrashServiceQuery, issueID: String,
                    observe: Observer? = nil) async throws -> NativeCrashData.Fetched {
        try await withOrganizerAccess(request, issueID: issueID, observe: observe) { driver, began in
            do {
                try await self.waitForList(driver, prepare: false)
                let clock = ContinuousClock()
                let deadline = clock.now.advanced(by: self.timeout)
                var lastErrors: [JSONValue] = []
                repeat {
                    try Task.checkCancellation()
                    let read = self.cache.readIssue(request, issueID: issueID)
                    lastErrors = read.errors
                    if let issue = read.snapshot, let fetchedAt = issue.fetchedAt,
                       fetchedAt >= Self.second(began) {
                        let ui = try await self.withStableAccessibility(until: deadline) { try driver.snapshot() }
                        try self.checkFailure(ui)
                        if ui.busyMessages.isEmpty {
                            return NativeCrashData.Fetched(value: .object(Self.issueValue(issue)),
                                fetchedAt: Self.date(fetchedAt), errors: read.errors, isComplete: read.errors.isEmpty)
                        }
                    }
                    let ui = try await self.withStableAccessibility(until: deadline) { try driver.snapshot() }
                    try self.checkFailure(ui)
                    try await Task.sleep(for: .milliseconds(250))
                } while clock.now < deadline
                throw Self.timeoutError("Organizer did not refresh crash issue \(issueID)", errors: lastErrors)
            } catch {
                if Task.isCancelled || error is CancellationError { throw error }
                return try Self.recoverIssue(self.cache.readIssue(request, issueID: issueID), after: error)
            }
        }
    }

    func savedIssue(_ request: NativeCrashServiceQuery, issueID: String,
                    after error: any Error) throws -> NativeCrashData.Fetched {
        try Self.recoverIssue(cache.readIssue(request, issueID: issueID), after: error)
    }

    func savedIssueIfAvailable(_ request: NativeCrashServiceQuery, issueID: String,
                               after error: any Error) throws -> NativeCrashData.Fetched? {
        let read = cache.readIssue(request, issueID: issueID)
        if read.snapshot != nil { return try Self.recoverIssue(read, after: error) }
        guard !read.errors.isEmpty else { return nil }
        throw NSError(domain: "XcodeMCPKit.Organizer", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Saved crash samples could not be recovered",
            NSUnderlyingErrorKey: error as NSError,
            "XcodeMCPKit.CrashDiagnostics": read.errors.map(\.foundationObject),
        ])
    }

    static func savedPages(_ request: NativeCrashQuery, store: NativeCrashStore,
                           descriptors: [JSONValue], after error: any Error) throws -> NativeCrashData.Fetched? {
        guard !descriptors.isEmpty else { return nil }
        var points: [JSONValue] = []
        var errors = [NativeCrashData.diagnostic(error, operation: "organizerAcquisition")]
        var fetchedAt: String?
        var retained: [JSONValue] = []
        for (index, descriptor) in descriptors.enumerated() {
            let query = request.withPage(index).json(issueID: nil)
            guard case .object(let fields) = descriptor, fields["query"] == query else {
                throw NativeRuntimeError.unsupportedContract("A saved crash acquisition page belongs to another query")
            }
            if case .array(let failures) = fields["errors"] { errors += failures }
            do {
                guard let saved = try store.read(key: query), case .object(let value) = saved.value,
                      case .array(let pagePoints) = value["points"] else {
                    throw NativeRuntimeError.unavailable("A captured crash page is not available in its job source store")
                }
                points += pagePoints
                fetchedAt = saved.fetchedAt ?? fetchedAt
                errors += saved.errors
                retained.append(descriptor)
            } catch { errors.append(NativeCrashData.diagnostic(error, operation: "jobPageRecovery")) }
        }
        guard !retained.isEmpty else { throw timeoutError("No captured crash pages could be recovered", errors: errors) }
        return collection(request, points: points, pages: retained, copiedPages: retained,
            fetchedAt: fetchedAt, nextPage: descriptors.count, terminal: false, errors: errors)
    }

    static func recoverIssue(_ read: NativeOrganizerCrashCache.Read<NativeOrganizerCrashCache.IssueSnapshot>,
                             after error: any Error) throws -> NativeCrashData.Fetched {
        guard let issue = read.snapshot else { throw error }
        var value = issueValue(issue)
        // Saved samples remain useful after a refresh failure, but their native
        // directory does not establish when each sample was downloaded.
        value["sampleFreshness"] = .string("unverifiedSavedSamples")
        value["cachedDistribution"] = value.removeValue(forKey: "distribution")
        value["cachedDistributionFetchedAt"] = issue.fetchedAt.map { .string(Self.date($0)) } ?? .null
        return NativeCrashData.Fetched(value: .object(value), fetchedAt: nil, source: "organizerCache",
            errors: read.errors + [NativeCrashData.diagnostic(error, operation: "organizerIssueRefresh")], isComplete: false)
    }

    private static func issueValue(_ issue: NativeOrganizerCrashCache.IssueSnapshot) -> [String: JSONValue] {
        var value: [String: JSONValue] = [
            "pointInfo": issue.pointInfo, "organizerCachePath": .string(issue.pointInfoURL.path),
            "logDirectory": .string(issue.logDirectory.path),
            "distributionCachePath": .string(issue.distributionURL.path),
        ]
        if let distribution = issue.distribution { value["distribution"] = distribution }
        return value
    }

    static func url(_ request: NativeCrashServiceQuery, issueID: String?) throws -> URL {
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
        var parameters = ["adamId": request.adamIdentifier, "bundleId": request.query.bundleIdentifier,
            "platformId": try platform(request.query.uploadPlatformIdentifier), "installPlatformId": try platform(request.query.platformIdentifier)]
        if let issueID { parameters["analyticsPointId"] = issueID }
        else {
            parameters["timePeriod"] = request.query.timePeriod
            parameters["appVersion"] = request.query.appVersion
            parameters["releaseHistory"] = request.query.isBeta.map { $0 ? "testFlight" : "appStore" } ?? "all"
        }
        components.queryItems = parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw NativeRuntimeError.invalidRequest("Could not form the Organizer crash URL") }
        return url
    }

    private static func page(_ page: NativeOrganizerCrashCache.PageSnapshot) -> NativeCrashData.Fetched {
        NativeCrashData.Fetched(value: .object(["points": .array(page.points), "organizerCache": page.native,
            "organizerCachePath": .string(page.cacheURL.path), "organizerCacheKey": page.key,
        ]), fetchedAt: date(page.fetchedAt))
    }

    static func collectionAfterFailure(_ request: NativeCrashServiceQuery, points: [JSONValue], pages: [JSONValue],
                                       copiedPages: [JSONValue], fetchedAt: String, failedPage: Int,
                                       errors: [JSONValue], error: any Error) throws -> NativeCrashData.Fetched {
        let failure = NativeCrashData.diagnostic(error, operation: "organizerPage\(failedPage)")
        let failures = errors + [failure]
        // Prefix pages are saved separately; they cannot satisfy a request for
        // a later single page or replace its existing cached result.
        guard request.query.collectsAllPages, !copiedPages.isEmpty else {
            throw timeoutError("Organizer could not collect crash issues", errors: failures)
        }
        let failed: JSONValue = .object(["query": request.withPage(failedPage).query.json(issueID: nil),
            "status": .string("failed"), "errors": .array([failure])])
        return collection(request.query, points: points, pages: pages + [failed], copiedPages: copiedPages,
            fetchedAt: fetchedAt, nextPage: failedPage, terminal: false, errors: failures)
    }

    private static func collection(_ request: NativeCrashQuery, points: [JSONValue], pages: [JSONValue],
                                   copiedPages: [JSONValue], fetchedAt: String?, nextPage: Int?, terminal: Bool,
                                   terminalPage: Int? = nil, errors: [JSONValue]) -> NativeCrashData.Fetched {
        NativeCrashData.Fetched(value: .object(["points": .array(points), "pages": .array(pages),
            "copiedPages": .array(copiedPages), "pagination": .object([
                "mode": .string(request.collectsAllPages ? "allPages" : "singlePage"),
                "page": .number(.int(Int64(request.pageIndex))), "pageSize": .number(.int(Int64(request.pageSize))),
                "returnedCount": .number(.int(Int64(points.count))), "endReached": .bool(terminal),
                "terminalPage": terminalPage.map { .number(.int(Int64($0))) } ?? .null,
                "hasMore": terminal ? .bool(false) : .null,
                "nextPage": nextPage.map { .number(.int(Int64($0))) } ?? .null,
                "continuationRequiresProbe": .bool(!terminal),
            ])]), fetchedAt: fetchedAt, errors: errors, isComplete: !request.collectsAllPages || terminal)
    }

    private func waitForPage(_ request: NativeCrashServiceQuery, began: Date,
                             driver: NativeOrganizerAccessibility) async throws -> NativeOrganizerCrashCache.PageSnapshot {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var lastErrors: [JSONValue] = []
        repeat {
            try Task.checkCancellation()
            let read = cache.readPage(request)
            lastErrors = read.errors
            let ui = try await withStableAccessibility(until: deadline) { try driver.snapshot() }
            try checkFailure(ui)
            if let page = read.snapshot, Self.isReady(page, since: began, snapshot: ui) { return page }
            if request.query.pageIndex > 0, ui.busyMessages.isEmpty {
                // Cache writes can precede the table's layout. Re-resolve the
                // scrollbar as appended rows make the next page scrollable.
                try await withStableAccessibility(until: deadline) { try driver.scrollToBottom() }
            }
            try await Task.sleep(for: .milliseconds(250))
        } while clock.now < deadline
        throw Self.timeoutError("Organizer did not refresh the requested crash page \(request.query.pageIndex)", errors: lastErrors)
    }

    static func isReady(_ page: NativeOrganizerCrashCache.PageSnapshot, since began: Date,
                        snapshot: NativeOrganizerAccessibility.Snapshot) -> Bool {
        // The exact-query cache identifies the page. AXHelp is presentation text;
        // unsymbolicated addresses can differ from the same issue's cached name.
        page.fetchedAt >= second(began) && snapshot.busyMessages.isEmpty
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

    private func withStableAccessibility<Value>(until deadline: ContinuousClock.Instant,
                                                 _ operation: () async throws -> Value) async throws -> Value {
        repeat {
            try Task.checkCancellation()
            do { return try await operation() }
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

    func shutdown() async throws {
        guard owner != nil else { return }
        let file = try await productsLock()
        let outcome: Result<Void, any Error>
        do { try await shutdownOwned(); outcome = .success(()) }
        catch { outcome = .failure(error) }
        do { try file.close() }
        catch {
            if case .failure(let original) = outcome { throw Self.cleanupFailure(original, cleanup: [error as NSError]) }
            throw error
        }
        try outcome.get()
    }

    // The caller holds the shared Products lock while opening a route.
    func organizerApplication(for url: URL, previousFetch: Date? = nil) async throws -> NativeOrganizerApplication {
        try await recoverAbandonedOwners()
        if let owner {
            let prefetched = owner.application.application.launchDate.map { launchDate in
                previousFetch.map { $0 >= Self.second(launchDate) } ?? false
            } ?? false
            if !owner.reusable || owner.application.application.isTerminated || owner.requestedURLs.contains(url) || prefetched {
                // Organizer also prefetches unvisited issues. A cache refreshed
                // during this owner's lifetime may already be held in memory.
                try await shutdownOwned()
            }
        }
        if owner == nil {
            let directory = try ownerDirectory().appending(component: UUID().uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let lease = try lockFile(directory.appending(component: "owner.lock"))
            guard flock(lease.fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
                let error = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                do { try lease.close() }
                catch let cleanup { throw Self.cleanupFailure(error, cleanup: [cleanup as NSError]) }
                throw error
            }
            let application: NativeOrganizerApplication
            do { application = try await launchOrganizer(installation) }
            catch {
                let original = error
                var cleanup: [NSError] = []
                do { try lease.close() } catch { cleanup.append(error as NSError) }
                do { try FileManager.default.removeItem(at: directory) } catch { cleanup.append(error as NSError) }
                if !cleanup.isEmpty { throw Self.cleanupFailure(original, cleanup: cleanup) }
                throw original
            }
            owner = Owner(application: application, directory: directory, lease: lease)
            do { try saveOwner() }
            catch {
                let original = error
                let cleanup = Task { @MainActor in try await self.shutdownOwned() }
                do { try await cleanup.value }
                catch { throw Self.cleanupFailure(original, cleanup: [error as NSError]) }
                throw original
            }
        }
        guard let application = owner?.application else {
            throw NativeRuntimeError.unavailable("The owned Organizer application is unavailable")
        }
        try application.open(url)
        owner?.requestedURLs.insert(url)
        return application
    }

    private func saveOwner() throws {
        guard let owner else { return }
        try NativeCrashStore.encode(Self.identity(owner.application))
            .write(to: owner.directory.appending(component: "owner.json"), options: .atomic)
    }

    private func shutdownOwned() async throws {
        guard let owned = owner else { return }
        try await owned.application.shutdown()
        var cleanup: [NSError] = []
        do { try saveOwner() } catch { cleanup.append(error as NSError) }
        do {
            try owned.lease.close()
            owner = nil
            do { try FileManager.default.removeItem(at: owned.directory) }
            catch { cleanup.append(error as NSError) }
        } catch { cleanup.append(error as NSError) }
        if let original = cleanup.first {
            if cleanup.count == 1 { throw original }
            throw Self.cleanupFailure(original, cleanup: Array(cleanup.dropFirst()))
        }
    }

    private func ownerDirectory() throws -> URL {
        if let organizerRoot { return organizerRoot.appending(component: "Owners", directoryHint: .isDirectory) }
        // Recovery records must survive host exits and cache eviction.
        return try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true).appending(path: "XcodeMCPKit/Organizer/Owners", directoryHint: .isDirectory)
    }

    private func recoverAbandonedOwners() async throws {
        let directory = try ownerDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for folder in try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
            let lease = try lockFile(folder.appending(component: "owner.lock"))
            let acquired = flock(lease.fileDescriptor, LOCK_EX | LOCK_NB) == 0
            let code = errno
            let outcome: Result<Void, any Error>
            do {
                if acquired {
                    let record = folder.appending(component: "owner.json")
                    if FileManager.default.fileExists(atPath: record.path) {
                        let identity = try NativeCrashStore.object(Data(contentsOf: record))
                        let cleanup = Task { @MainActor in try await self.recoverApplication(.object(identity)) }
                        try await cleanup.value
                    }
                } else if code != EWOULDBLOCK {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
                }
                outcome = .success(())
            } catch { outcome = .failure(error) }
            do { try lease.close() }
            catch {
                if case .failure(let original) = outcome { throw Self.cleanupFailure(original, cleanup: [error as NSError]) }
                throw error
            }
            try outcome.get()
            if acquired { try FileManager.default.removeItem(at: folder) }
        }
    }

    private func productsLock() async throws -> FileHandle {
        // Keep the established lock path so hosts on earlier versions still coordinate.
        let root = organizerRoot ?? FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Caches/XcodeMCPKit/Organizer", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = try lockFile(root.appending(component: "products.lock"))
        do {
            while flock(file.fileDescriptor, LOCK_EX | LOCK_NB) != 0 {
                let code = errno
                guard code == EWOULDBLOCK else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
                try await Task.sleep(for: .milliseconds(100))
            }
            return file
        } catch {
            let original = error
            do { try file.close() }
            catch { throw Self.cleanupFailure(original, cleanup: [error as NSError]) }
            throw original
        }
    }

    private func lockFile(_ url: URL) throws -> FileHandle {
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: Data()) }
        return try FileHandle(forUpdating: url)
    }

    private func withOrganizerAccess(_ request: NativeCrashServiceQuery, issueID: String?, observe: Observer? = nil,
        _ operation: (NativeOrganizerAccessibility, Date) async throws -> NativeCrashData.Fetched) async throws -> NativeCrashData.Fetched {
        try observe?(["phase": .string("waitingForOrganizer")])
        let file = try await productsLock()
        var owned: NativeOrganizerApplication?
        var ownerLeasePath: String?
        let outcome: Result<NativeCrashData.Fetched, any Error>
        do {
            try Task.checkCancellation()
            let began = try await Self.refreshBoundary()
            let previousFetch: Date?
            if let issueID { previousFetch = cache.readIssue(request, issueID: issueID).snapshot?.fetchedAt }
            else { previousFetch = cache.readPage(request).snapshot?.fetchedAt }
            let application = try await organizerApplication(for: Self.url(request, issueID: issueID), previousFetch: previousFetch)
            owned = application
            ownerLeasePath = owner?.directory.appending(component: "owner.lock").path
            try observe?(["phase": .string("acquiring"),
                "organizer": Self.identity(application, ownerLeasePath: ownerLeasePath)])
            try Task.checkCancellation()
            let driver = try NativeOrganizerAccessibility(installation: installation, application: application.application)
            outcome = .success(try await operation(driver, began))
        } catch { outcome = .failure(error) }
        var cleanup: [NSError] = []
        let failed: Bool
        switch outcome {
        case .failure: failed = true
        case .success(let result): failed = !result.isComplete || !result.errors.isEmpty
        }
        if failed || Task.isCancelled {
            owner?.reusable = false
            let shutdown = Task { @MainActor in try await self.shutdownOwned() }
            do { try await shutdown.value }
            catch { cleanup.append(error as NSError) }
        }
        if let owned {
            do { try observe?(["organizer": Self.identity(owned, ownerLeasePath: ownerLeasePath)]) }
            catch { cleanup.append(error as NSError) }
        }
        if !cleanup.isEmpty, !failed, !Task.isCancelled {
            owner?.reusable = false
            let shutdown = Task { @MainActor in try await self.shutdownOwned() }
            do { try await shutdown.value }
            catch { cleanup.append(error as NSError) }
        }
        do { try file.close() }
        catch {
            cleanup.append(error as NSError)
            if !failed, !Task.isCancelled {
                owner?.reusable = false
                let shutdown = Task { @MainActor in try await self.shutdownOwned() }
                do { try await shutdown.value }
                catch { cleanup.append(error as NSError) }
            }
        }
        if Task.isCancelled, !cleanup.isEmpty {
            let original: any Error
            if case .failure(let failure) = outcome { original = failure }
            else { original = CancellationError() }
            let failure = Self.cleanupFailure(original, cleanup: cleanup)
            NativeExecutionOperations.scope?.recordFailure(failure)
            NativeHostDiagnostic.report("Organizer cleanup after cancellation: \(failure)")
        }
        switch outcome {
        case .success(var result):
            result.errors += cleanup.map { NativeCrashData.diagnostic($0, operation: "organizerCleanup") }
            if let owned, case .object(var value) = result.value {
                value["organizerProcessId"] = .number(.int(Int64(owned.processIdentifier)))
                value["organizerTerminated"] = .bool(owned.application.isTerminated)
                result = NativeCrashData.Fetched(value: .object(value), fetchedAt: result.fetchedAt,
                    source: result.source, errors: result.errors, isComplete: result.isComplete)
            }
            return result
        case .failure(let original):
            guard !cleanup.isEmpty else { throw original }
            throw Self.cleanupFailure(original, cleanup: cleanup)
        }
    }

    private static func identity(_ owned: NativeOrganizerApplication, ownerLeasePath: String? = nil) -> JSONValue {
        var fields: [String: JSONValue] = ["processId": .number(.int(Int64(owned.processIdentifier))),
            "appPath": owned.application.bundleURL.map { .string($0.resolvingSymlinksInPath().path) } ?? .null,
            "launchDate": owned.application.launchDate.map { .number(.double($0.timeIntervalSince1970)) } ?? .null,
            "terminated": .bool(owned.application.isTerminated)]
        if let ownerLeasePath { fields["ownerLeasePath"] = .string(ownerLeasePath) }
        return .object(fields)
    }

    private static func cleanupFailure(_ original: any Error, cleanup: [NSError]) -> NSError {
        NSError(domain: "XcodeMCPKit.Organizer", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Organizer collection and cleanup failed",
                       NSMultipleUnderlyingErrorsKey: [original as NSError] + cleanup])
    }

    private func checkFailure(_ snapshot: NativeOrganizerAccessibility.Snapshot) throws {
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
