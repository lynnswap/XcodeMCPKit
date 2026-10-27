import Foundation
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

    struct Log: Sendable {
        let url: URL
        let data: Data
    }

    struct IssueSnapshot: Sendable {
        let pointInfo: JSONValue
        let pointInfoURL: URL
        let distribution: JSONValue?
        let distributionURL: URL
        let fetchedAt: Date?
        let logs: [Log]

        var cacheURL: URL { distributionURL }
        var logURLs: [URL] { logs.map(\.url) }
    }

    let productsRoot: URL

    init(productsRoot: URL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Developer/Xcode/Products", directoryHint: .isDirectory)) {
        self.productsRoot = productsRoot
    }

    func readPage(_ request: NativeCrashServiceQuery) -> Read<PageSnapshot> {
        let url = crashDirectory(request).appending(component: "ListablePoints.json")
        var result = Read<PageSnapshot>()
        do {
            guard let root = try optionalObject(at: url) else { return result }
            guard case .array(let items) = root["recentItems"], items.count.isMultiple(of: 2) else {
                throw NativeRuntimeError.unsupportedContract("Organizer's crash list has no keyed LRU entries")
            }
            // Codable represents a dictionary with native struct keys as alternating keys and values.
            for index in stride(from: 0, to: items.count, by: 2) {
                guard case .object(let key) = items[index], matchesPage(key, query: request) else { continue }
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
                        points: points, pageIndex: request.query.pageIndex, pageSize: request.query.pageSize, key: items[index])
                    if result.snapshot.map({ $0.fetchedAt < fetchedAt }) ?? true { result.snapshot = snapshot }
                } catch { result.errors.append(Self.diagnostic(error, operation: "organizerPageRead", url: url)) }
            }
        } catch { result.errors.append(Self.diagnostic(error, operation: "organizerPageRead", url: url)) }
        return result
    }

    /// `appVersion` selects a downloaded log filter; distribution bodies cover all versions and channels.
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
                // A failed distribution read must not discard available point information or log files.
                let logs = readLogs(directory.appending(component: "Logs"), errors: &result.errors)
                let snapshot = IssueSnapshot(pointInfo: .object(point), pointInfoURL: pointURL,
                    distribution: distribution, distributionURL: distributionURL, fetchedAt: fetchedAt, logs: logs)
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

    private func readLogs(_ directory: URL, errors: inout [JSONValue]) -> [Log] {
        do {
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            return files.filter { $0.pathExtension == "crash" }.sorted { $0.path < $1.path }.compactMap { url in
                do { return Log(url: url, data: try Data(contentsOf: url)) }
                catch {
                    errors.append(Self.diagnostic(error, operation: "organizerLogRead", url: url))
                    return nil
                }
            }
        } catch {
            // Native empty log collections return before creating a Logs directory.
            if !Self.isMissing(error) { errors.append(Self.diagnostic(error, operation: "organizerLogsRead", url: directory)) }
            return []
        }
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
