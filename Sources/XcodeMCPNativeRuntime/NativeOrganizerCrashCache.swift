import Darwin
import Foundation
import Synchronization
import XcodeMCPWire

/// Reads the exact Organizer request that produced a cached crash response.
struct NativeOrganizerCrashCache: Sendable {
    struct Read<Snapshot: Sendable>: Sendable {
        var snapshot: Snapshot?
        var errors: [JSONValue] = []
    }

    struct PageSnapshot: Sendable {
        let native: JSONValue
        let fetchedAt: Date
        let cacheURL: URL
        let points: [JSONValue]
        let pageIndex: Int
        let pageSize: Int
        let key: JSONValue
    }

    struct IssueSnapshot: Sendable {
        let pointInfo: JSONValue
        let pointInfoURL: URL
        let distribution: JSONValue?
        let distributionURL: URL
        let fetchedAt: Date?
        let logDirectory: URL

        var cacheURL: URL { distributionURL }
    }

    let productsRoot: URL

    init(productsRoot: URL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Developer/Xcode/Products", directoryHint: .isDirectory)) {
        self.productsRoot = productsRoot
    }

    func readPage(_ request: NativeCrashServiceQuery) -> Read<PageSnapshot> {
        let read = readPages(request, pageIndex: request.query.pageIndex)
        return Read(snapshot: read.snapshot?[request.query.pageIndex], errors: read.errors)
    }

    func readPages(_ request: NativeCrashServiceQuery) -> Read<[Int: PageSnapshot]> {
        readPages(request, pageIndex: nil)
    }

    private func readPages(_ request: NativeCrashServiceQuery, pageIndex: Int?) -> Read<[Int: PageSnapshot]> {
        let url = listURL(request)
        var result = Read<[Int: PageSnapshot]>(snapshot: [:])
        do {
            guard let root = try optionalObject(at: url) else { return result }
            guard case .array(let items) = root["recentItems"], items.count.isMultiple(of: 2) else {
                throw NativeRuntimeError.unsupportedContract("Organizer's crash list has no keyed LRU entries")
            }
            // Codable represents a dictionary with native struct keys as alternating keys and values.
            for index in stride(from: 0, to: items.count, by: 2) {
                guard case .object(let key) = items[index], let page = Self.fields(key["page"]),
                      case .number(.int(let number)) = page["pageIndex"], let selected = Int(exactly: number),
                      selected >= 0, pageIndex == nil || pageIndex == selected,
                      matchesPage(key, query: request.withPage(selected)) else { continue }
                do {
                    guard let dated = Self.fields(items[index + 1]),
                          let value = dated["value"], let native = Self.fields(value),
                          let header = Self.fields(native["header"]),
                          header["adamIdentifier"] == .string(request.adamIdentifier),
                          header["timePeriod"] == .string(request.query.timePeriod),
                          let fetchedAt = Self.date(header["refreshDate"]),
                          case .array(let points) = native["crashPoints"] else {
                        throw NativeRuntimeError.unsupportedContract("Organizer's matching crash page has an invalid header or points")
                    }
                    guard points.allSatisfy({ point in
                        guard let fields = Self.fields(point) else { return false }
                        return fields["bundleIdentifier"] == .string(request.query.bundleIdentifier)
                            && fields["platformSDKIdentifier"] == .string(request.query.platformIdentifier)
                            && fields["uploadPlatformSDKIdentifier"] == .string(request.query.uploadPlatformIdentifier)
                    }) else {
                        throw NativeRuntimeError.unsupportedContract("Organizer's matching crash page contains another product or platform")
                    }
                    let snapshot = PageSnapshot(native: value, fetchedAt: fetchedAt, cacheURL: url,
                        points: points, pageIndex: selected, pageSize: request.query.pageSize, key: items[index])
                    if result.snapshot?[selected].map({ $0.fetchedAt < fetchedAt }) ?? true {
                        result.snapshot?[selected] = snapshot
                    }
                } catch { result.errors.append(Self.diagnostic(error, operation: "organizerPageRead", url: url)) }
            }
        } catch { result.errors.append(Self.diagnostic(error, operation: "organizerPageRead", url: url)) }
        return result
    }

    /// Reload refreshes already loaded pages together, while Xcode retains only
    /// a small LRU on disk. Capture writes off the AX/main actor before eviction.
    final class PageCapture: Sendable {
        private struct State {
            var pages: [Int: PageSnapshot] = [:]
            var readErrors: [JSONValue] = []
            var watchErrors: [NSError] = []
            var directorySource: (any DispatchSourceFileSystemObject)?
            var fileSource: (any DispatchSourceFileSystemObject)?
            var stopped = false
        }

        private let state = Mutex(State())
        private let queue = DispatchQueue(label: "XcodeMCPKit.OrganizerPageCapture")
        private let closing = DispatchGroup()
        private let cache: NativeOrganizerCrashCache
        private let request: NativeCrashServiceQuery
        private let since: Date

        init(cache: NativeOrganizerCrashCache, request: NativeCrashServiceQuery, since: Date) throws {
            self.cache = cache
            self.request = request
            self.since = Date(timeIntervalSince1970: floor(since.timeIntervalSince1970))
            let path = cache.listURL(request).deletingLastPathComponent().path
            let descriptor = unsafe open(path, O_EVTONLY)
            guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            let directory = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            let source = makeSource(directory)
            source.setEventHandler { [weak self] in
                self?.watchFile()
                self?.capture()
            }
            state.withLock { $0.directorySource = source }
            source.activate()
            // Serialize registration with directory events, including a file
            // created or atomically replaced while the watcher is starting.
            queue.sync {
                watchFile()
                capture()
            }
        }

        deinit { cancel() }

        func readPage(_ index: Int) -> Read<PageSnapshot> {
            state.withLock { Read(snapshot: $0.pages[index], errors: $0.readErrors) }
        }

        func finish() async -> [NSError] {
            await withCheckedContinuation { continuation in
                queue.async {
                    self.cancel()
                    self.closing.notify(queue: self.queue) {
                        continuation.resume(returning: self.state.withLock { $0.watchErrors })
                    }
                }
            }
        }

        private func cancel() {
            let sources = state.withLock { value in
                value.stopped = true
                let sources = [value.directorySource, value.fileSource].compactMap { $0 }
                value.directorySource = nil
                value.fileSource = nil
                return sources
            }
            sources.forEach { $0.cancel() }
        }

        private func makeSource(_ file: FileHandle) -> any DispatchSourceFileSystemObject {
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: file.fileDescriptor,
                eventMask: [.write, .extend, .rename, .delete], queue: queue)
            let closing = closing
            closing.enter()
            source.setCancelHandler { [weak self] in
                defer { closing.leave() }
                do { try file.close() }
                catch { self?.state.withLock { $0.watchErrors.append(error as NSError) } }
            }
            return source
        }

        private func watchFile() {
            guard !state.withLock({ $0.stopped }) else { return }
            do {
                let file = try FileHandle(forReadingFrom: cache.listURL(request))
                let source = makeSource(file)
                source.setEventHandler { [weak self] in self?.capture() }
                let old = state.withLock { value in
                    let old = value.fileSource
                    value.fileSource = source
                    return old
                }
                source.activate()
                old?.cancel()
            } catch {
                if !NativeOrganizerCrashCache.isMissing(error) {
                    state.withLock { $0.watchErrors.append(error as NSError) }
                }
            }
        }

        private func capture() {
            guard !state.withLock({ $0.stopped }) else { return }
            let read = cache.readPages(request)
            state.withLock { value in
                value.readErrors = read.errors
                for (index, page) in read.snapshot ?? [:] where page.fetchedAt >= since {
                    if value.pages[index].map({ $0.fetchedAt <= page.fetchedAt }) ?? true { value.pages[index] = page }
                }
            }
        }
    }

    /// `appVersion` selects a downloaded log filter; distribution bodies cover all versions and channels.
    /// This reads the request metadata only. Saved sample files are observed separately;
    /// a refreshed distribution does not establish that the provider has finished saving all samples.
    func readIssue(_ request: NativeCrashServiceQuery, issueID: String) -> Read<IssueSnapshot> {
        let filters = crashDirectory(request).appending(component: "Points")
            .appending(component: issueID + ".xccrashpoint").appending(component: "Filters")
        var result = Read<IssueSnapshot>()
        let directories: [URL]
        do { directories = try FileManager.default.contentsOfDirectory(at: filters, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) }
        catch {
            if !Self.isMissing(error) { result.errors.append(Self.diagnostic(error, operation: "organizerIssueRead", url: filters)) }
            return result
        }
        for directory in directories.sorted(by: { $0.path < $1.path }) {
            let pointURL = directory.appending(component: "PointInfo.json")
            do {
                guard let point = try optionalObject(at: pointURL), matchesIssue(point, query: request, issueID: issueID) else { continue }
                let distributionURL = directory.appending(component: "DistributionInfo.json")
                var distribution: JSONValue?
                var fetchedAt: Date?
                do {
                    guard let value = try optionalObject(at: distributionURL),
                          let header = Self.fields(value["header"]),
                          header["analyticsPointIdentifier"] == .string(issueID),
                          header["adamIdentifier"] == .string(request.adamIdentifier),
                          header["bundleIdentifier"] == .string(request.query.bundleIdentifier),
                          let refresh = Self.date(header["lastRefresh"]), Self.fields(value["body"]) != nil else {
                        throw NativeRuntimeError.unsupportedContract("Organizer's matching crash issue has no valid distribution header")
                    }
                    distribution = .object(value)
                    fetchedAt = refresh
                } catch { result.errors.append(Self.diagnostic(error, operation: "organizerDistributionRead", url: distributionURL)) }
                // A failed distribution read must not discard the exact saved sample scope.
                let snapshot = IssueSnapshot(pointInfo: .object(point), pointInfoURL: pointURL,
                    distribution: distribution, distributionURL: distributionURL, fetchedAt: fetchedAt,
                    logDirectory: directory.appending(component: "Logs"))
                if result.snapshot.map({ ($0.fetchedAt ?? .distantPast) < (fetchedAt ?? .distantPast) }) ?? true {
                    result.snapshot = snapshot
                }
            } catch { result.errors.append(Self.diagnostic(error, operation: "organizerPointRead", url: pointURL)) }
        }
        return result
    }

    private func crashDirectory(_ request: NativeCrashServiceQuery) -> URL {
        productsRoot.appending(component: request.query.bundleIdentifier).appending(component: "Crashes")
    }

    private func listURL(_ request: NativeCrashServiceQuery) -> URL {
        crashDirectory(request).appending(component: "ListablePoints.json")
    }

    private func matchesPage(_ key: [String: JSONValue], query request: NativeCrashServiceQuery) -> Bool {
        guard let page = Self.fields(key["page"]),
              page["pageIndex"] == .number(.int(Int64(request.query.pageIndex))),
              page["pageSize"] == .number(.int(Int64(request.query.pageSize))),
              let parameters = Self.fields(key["pageAgnosticParameters"]),
              parameters["adamIdentifier"] == .string(request.adamIdentifier),
              parameters["timePeriod"] == .string(request.query.timePeriod),
              parameters["releaseHistory"] == .string(request.query.isBeta.map { $0 ? "testFlight" : "appStore" } ?? "all"),
              case .array(let products) = parameters["indexedSelectedProductVersions"], products.count == 2,
              products[0] == .object(["bundleIdentifier": .string(request.query.bundleIdentifier),
                  "platformIdentifier": .string(request.query.platformIdentifier)]),
              let product = Self.fields(products[1]) else { return false }
        let version: JSONValue = request.query.appVersion.map { .object(["type": .string("version"), "version": .string($0)]) }
            ?? .object(["type": .string("allVersions")])
        return product["adamIdentifier"] == .string(request.adamIdentifier)
            && product["bundleIdentifier"] == .string(request.query.bundleIdentifier)
            && product["platformIdentifier"] == .string(request.query.platformIdentifier)
            && product["uploadPlatformIdentifier"] == .string(request.query.uploadPlatformIdentifier)
            && product["version"] == version
            && product["build"] == .object(["type": .string("allBuilds")])
    }

    private func matchesIssue(_ point: [String: JSONValue], query request: NativeCrashServiceQuery, issueID: String) -> Bool {
        guard let identifier = Self.fields(point["pointIdentifier"]),
              identifier["uploadPlatformSDKIdentifier"] == .string(request.query.uploadPlatformIdentifier),
              let selectable = Self.fields(identifier["selectableAnalyticsPointIdentifier"]) else { return false }
        return selectable["reportTypeIdentifier"] == .string("Xcode.Analytics.ReportType.CrashPoint")
            && selectable["analyticsPointIdentifier"] == .string(issueID)
            && selectable["adamIdentifier"] == .string(request.adamIdentifier)
            && selectable["bundleIdentifier"] == .string(request.query.bundleIdentifier)
            && selectable["platformSDKIdentifier"] == .string(request.query.platformIdentifier)
            && (selectable["appVersion"] ?? .null) == (request.query.appVersion.map(JSONValue.string) ?? .null)
            && (selectable["appBuild"] ?? .null) == .null
    }

    private func optionalObject(at url: URL) throws -> [String: JSONValue]? {
        do { return try NativeCrashStore.object(Data(contentsOf: url)) }
        catch {
            if Self.isMissing(error) { return nil }
            throw error
        }
    }

    private static func fields(_ value: JSONValue?) -> [String: JSONValue]? {
        if case .object(let fields) = value { return fields }
        return nil
    }

    private static func date(_ value: JSONValue?) -> Date? {
        guard case .string(let string) = value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions.insert(.withFractionalSeconds)
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions.remove(.withFractionalSeconds)
        return formatter.date(from: string)
    }

    private static func isMissing(_ error: any Error) -> Bool {
        let error = error as NSError
        return error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code)
    }

    private static func diagnostic(_ error: any Error, operation: String, url: URL) -> JSONValue {
        guard case .object(var fields) = NativeCrashData.diagnostic(error, operation: operation) else { return .null }
        fields["path"] = .string(url.path)
        return .object(fields)
    }
}
