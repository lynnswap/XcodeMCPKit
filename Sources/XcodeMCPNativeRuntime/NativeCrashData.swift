import ABIBridge
import CryptoKit
import Foundation
import XcodeMCPWire

struct NativeCrashRequest: Decodable, Sendable {
    var workspaceIdentifier: String?
    var bundleIdentifier: String?
    var platform: String?
    var uploadPlatform: String?
    var appVersion: String?
    var isBeta: Bool?
    var timePeriod = "last14Days"
    var pageIndex = 0
    var pageSize = 25
    var issueID: String?
    var source = Source.network

    enum Source: String, Decodable, Sendable {
        case network, cache, networkWithCacheFallback
    }

    private enum CodingKeys: String, CodingKey {
        case workspaceIdentifier, platform, source
        case uploadPlatform = "upload_platform"
        case bundleIdentifier = "bundle_id", appVersion = "app_version", isBeta = "is_beta"
        case timePeriod = "time_period", pageIndex = "page", pageSize = "page_size", issueID = "issue_id"
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        workspaceIdentifier = try values.decodeIfPresent(String.self, forKey: .workspaceIdentifier)
        bundleIdentifier = try values.decodeIfPresent(String.self, forKey: .bundleIdentifier)
        platform = try values.decodeIfPresent(String.self, forKey: .platform)
        uploadPlatform = try values.decodeIfPresent(String.self, forKey: .uploadPlatform)
        appVersion = try values.decodeIfPresent(String.self, forKey: .appVersion)
        isBeta = try values.decodeIfPresent(Bool.self, forKey: .isBeta)
        timePeriod = try values.decodeIfPresent(String.self, forKey: .timePeriod) ?? timePeriod
        pageIndex = try values.decodeIfPresent(Int.self, forKey: .pageIndex) ?? pageIndex
        pageSize = try values.decodeIfPresent(Int.self, forKey: .pageSize) ?? pageSize
        issueID = try values.decodeIfPresent(String.self, forKey: .issueID)
        source = try values.decodeIfPresent(Source.self, forKey: .source) ?? source
        guard ["last24Hours", "last14Days", "last365Days"].contains(timePeriod) else {
            throw NativeRuntimeError.invalidRequest("Unsupported time_period: \(timePeriod)")
        }
        guard pageIndex >= 0, pageSize == 25 else {
            throw NativeRuntimeError.invalidRequest("page must be nonnegative; Organizer uses a fixed page_size of 25")
        }
    }
}

enum NativeCrashContract {
    static func describe(_ native: NativeTool, detail: Bool) -> NativeTool {
        func property(_ type: String, _ description: String) -> JSONValue {
            .object(["type": .string(type), "description": .string(description)])
        }
        var inputs: [String: JSONValue] = [
            "workspaceIdentifier": property("string", "Optional saved workspace used to infer the app and platform."),
            "bundle_id": property("string", "App bundle identifier. Inferred from the active scheme when omitted."),
            "platform": property("string", "App platform: iOS, macOS, watchOS, tvOS, or visionOS."),
            "upload_platform": property("string", "Original app upload platform. Specify iOS for an iOS app running on macOS or visionOS. Defaults to platform."),
            "app_version": property("string", "Filter by app version. Omit for all versions."),
            "is_beta": property("boolean", "Filter by TestFlight (true) or App Store (false). Omit for both."),
            "time_period": .object(["type": .string("string"), "enum": .array([.string("last24Hours"), .string("last14Days"), .string("last365Days")]),
                "default": .string("last14Days"), "description": .string("Native aggregation period; interval boundaries are returned without filling gaps.")]),
            "source": .object(["type": .string("string"), "enum": .array([.string("network"), .string("cache"), .string("networkWithCacheFallback")]),
                "default": .string("network"), "description": .string("Network operates Organizer in the selected Xcode and verifies a refreshed, exact-query cache entry. Requires running Xcode and Accessibility access. Cache reads only this server's exact saved request. A fallback preserves the refresh error and original fetch time.")]),
        ]
        if detail {
            inputs.removeValue(forKey: "is_beta")
            inputs.removeValue(forKey: "app_version")
            inputs["issue_id"] = property("string", "Stable issueId from ListCrashIssues; independent of the displayed crash name.")
        } else {
            inputs["page"] = .object(["type": .string("integer"), "minimum": .number(.int(0)), "default": .number(.int(0)),
                "description": .string("Zero-based page. Repeat with pagination.nextPage until it is null; save each response before continuing.")])
            inputs["page_size"] = .object(["type": .string("integer"), "enum": .array([.number(.int(25))]), "default": .number(.int(25)),
                "description": .string("Organizer's fixed page size of 25. Keep the filters unchanged when following nextPage.")])
        }
        var outputs: [String: JSONValue] = [
            "status": .object(["type": .string("string"), "enum": .array([.string("complete"), .string("partial"), .string("failed")])]),
            "query": property("object", "Resolved app, platform, filters, period, and page used for this response."),
            "provenance": property("object", "Network or exact-match cache, original fetch time, source update time when available, and persisted response path."),
            "errors": .object(["type": .string("array"), "items": property("object", "Failed operation and original error domain, code, reason, and underlying errors.")]),
            "responsePath": property("string", "Full structured response saved locally. Existing pages and successful downloads survive a later failure."),
            "native": property("object", "Original source metadata and available update information."),
        ]
        if detail {
            outputs["issueId"] = property("string", "Stable native issue identifier.")
            outputs["timeSeries"] = property("object", "Native period and interval unique-device counts, boundaries, and granularity. Missing intervals remain unknown; counts are not additive.")
            outputs["logs"] = .object(["type": .string("array"), "items": property("object", "Sample log ID and local file path. Sample count is not a crash occurrence or device count.")])
            outputs["sampleLogCount"] = property("integer", "Number of successfully saved sample log files; not crash occurrences or affected devices.")
            outputs["logFilters"] = property("object", "Effective log filters and native filtering limitations.")
        } else {
            outputs["issues"] = .object(["type": .string("array"), "items": property("object", "Stable issueId, display name, uniqueDeviceCount, and original source metadata.")])
            outputs["pagination"] = property("object", "Requested page, returned count, nextPage, and hasMore. Nonempty pages require probing the next page because the service provides no total.")
        }
        let name = detail ? "GetCrashIssue" : "ListCrashIssues"
        return NativeTool(name: name, descriptor: .object([
            "name": .string(name),
            "description": .string(detail ? "Operate Xcode Organizer to download a crash issue by stable ID, including device trends and saved sample logs. Selection is automatic." : "Operate Xcode Organizer to list crash issues one page at a time with stable IDs, query scope, timestamps, and exact cache provenance."),
            "annotations": .object(["readOnlyHint": .bool(true)]),
            "inputSchema": .object(["type": .string("object"), "properties": .object(inputs), "required": .array(detail ? [.string("issue_id")] : [])]),
            "outputSchema": .object(["type": .string("object"), "properties": .object(outputs),
                "required": .array([.string("status"), .string("query"), .string("provenance"), .string("errors")])]),
        ]), workspaceScoped: native.workspaceScoped)
    }
}

/// Cache entries belong to a complete native request, including its page. They
/// never use Organizer's most-recent LRU item as a substitute for that request.
struct NativeCrashStore {
    let root: URL

    struct Entry {
        let value: JSONValue
        let fetchedAt: String
        let path: String
        var errors: [JSONValue] = []
    }

    func read(key: JSONValue) throws -> Entry? {
        let url = try location(key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let envelope = try Self.object(Data(contentsOf: url))
        guard envelope["query"] == key, let value = envelope["value"],
              case .string(let fetchedAt) = envelope["fetchedAt"] else {
            throw NativeRuntimeError.unsupportedContract("Crash cache does not match its request: \(url.path)")
        }
        let errors: [JSONValue]
        if case .array(let failures) = envelope["errors"] { errors = failures }
        else { errors = [] }
        return Entry(value: value, fetchedAt: fetchedAt, path: url.path, errors: errors)
    }

    func write(_ value: JSONValue, key: JSONValue, fetchedAt: String, errors: [JSONValue] = []) throws -> Entry {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = try location(key)
        let envelope: JSONValue = .object(["query": key, "value": value, "fetchedAt": .string(fetchedAt), "errors": .array(errors)])
        try Self.encode(envelope).write(to: url, options: .atomic)
        return Entry(value: value, fetchedAt: fetchedAt, path: url.path, errors: errors)
    }

    private func location(_ key: JSONValue) throws -> URL {
        let digest = SHA256.hash(data: try Self.encode(key)).hexString
        return root.appendingPathComponent(digest + ".json")
    }

    static func encode(_ value: JSONValue) throws -> Data {
        try JSONSerialization.data(withJSONObject: value.foundationObject, options: [.sortedKeys, .fragmentsAllowed])
    }

    static func object(_ data: Data) throws -> [String: JSONValue] {
        guard let value = JSONValue(any: try JSONSerialization.jsonObject(with: data)), case .object(let fields) = value else {
            throw NativeRuntimeError.unsupportedContract("Native crash data is not a JSON object")
        }
        return fields
    }
}

enum NativeCrashData {
    struct Fetched {
        let value: JSONValue
        let fetchedAt: String
        var source = "organizer"
        var errors: [JSONValue] = []
    }

    struct Loaded {
        var value: JSONValue?
        var source: String?
        var fetchedAt: String?
        var cachePath: String?
        var errors: [JSONValue] = []

        var provenance: JSONValue {
            .object(["source": source.map(JSONValue.string) ?? .null,
                "fetchedAt": fetchedAt.map(JSONValue.string) ?? .null,
                "cachePath": cachePath.map(JSONValue.string) ?? .null,
                "sourceUpdatedAt": .null,
                "changeDetection": .string("refetch"),
                "changeDetectionReason": .string("The native service provides no update timestamp or conditional change token.")])
        }
    }

    @MainActor
    static func load(key: JSONValue, source: NativeCrashRequest.Source, store: NativeCrashStore,
                     fetch: () async throws -> Fetched) async throws -> Loaded {
        var result = Loaded()
        if source != .cache {
            do {
                let fetched = try await fetch()
                try Task.checkCancellation()
                result.value = fetched.value
                result.source = fetched.source
                result.fetchedAt = fetched.fetchedAt
                result.errors = fetched.errors
                do {
                    let entry = try store.write(fetched.value, key: key, fetchedAt: fetched.fetchedAt, errors: fetched.errors)
                    result.cachePath = entry.path
                } catch { result.errors.append(diagnostic(error, operation: "cacheWrite")) }
                return result
            } catch {
                try Task.checkCancellation()
                result.errors.append(diagnostic(error, operation: "download"))
                if source == .network { return result }
            }
        }
        do {
            if let entry = try store.read(key: key) {
                result.value = entry.value
                result.source = "cache"
                result.fetchedAt = entry.fetchedAt
                result.cachePath = entry.path
                result.errors += entry.errors
            } else {
                result.errors.append(.object(["operation": .string("cacheRead"), "domain": .string("XcodeMCPKit.CrashCache"),
                    "code": .number(.int(1)), "message": .string("No cached response matches this complete request. Fetch from the network first.")]))
            }
        } catch { result.errors.append(diagnostic(error, operation: "cacheRead")) }
        return result
    }

    static func diagnostic(_ error: any Error, operation: String) -> JSONValue {
        if let wrapped = error as? NativeSwiftError {
            return wrapped.withUnderlyingError { diagnostic($0, operation: operation) }
        }
        var seen: [NSError] = []
        func containedErrors(_ value: Any) -> [any Error] {
            if let error = value as? any Error { return [error] }
            let mirror = Mirror(reflecting: value)
            switch mirror.displayStyle {
            case .enum, .tuple, .dictionary, .collection, .set, .optional:
                return mirror.children.flatMap { containedErrors($0.value) }
            default: return []
            }
        }
        func describe(_ error: any Error) -> JSONValue {
            if let wrapped = error as? NativeSwiftError { return wrapped.withUnderlyingError(describe) }
            let native = error as NSError
            var fields: [String: JSONValue] = ["domain": .string(native.domain), "code": .number(.int(Int64(native.code))),
                "message": .string(native.localizedDescription), "type": .string(String(reflecting: type(of: error)))]
            guard !seen.contains(where: { $0 === native }) else { return .object(fields) }
            seen.append(native)
            if let reason = native.localizedFailureReason { fields["failureReason"] = .string(reason) }
            if let recovery = native.localizedRecoverySuggestion { fields["recoverySuggestion"] = .string(recovery) }
            if let path = native.userInfo[NSFilePathErrorKey] as? String { fields["path"] = .string(path) }
            if let diagnostics = native.userInfo["XcodeMCPKit.CrashDiagnostics"], let value = JSONValue(any: diagnostics) {
                fields["cacheErrors"] = value
            }
            if let underlying = native.userInfo[NSUnderlyingErrorKey] as? any Error { fields["underlyingError"] = describe(underlying) }
            var multiple = native.userInfo[NSMultipleUnderlyingErrorsKey] as? [any Error] ?? []
            // NSError bridging omits Swift enum payloads such as Xcode's
            // allAccountsFailed(usernameToError:jobUserDescription:).
            let mirror = Mirror(reflecting: error)
            if mirror.displayStyle == .enum || mirror.displayStyle == .struct {
                multiple += mirror.children.flatMap { containedErrors($0.value) }
            }
            if !multiple.isEmpty { fields["underlyingErrors"] = .array(multiple.map(describe)) }
            return .object(fields)
        }
        guard case .object(var fields) = describe(error) else { return .null }
        fields["operation"] = .string(operation)
        return .object(fields)
    }

    static func issue(_ value: JSONValue) throws -> JSONValue {
        guard case .object(let native) = value,
              case .string(let identifier) = native["analyticsPointIdentifier"],
              case .string(let name) = native["analyticsPointName"] else {
            throw NativeRuntimeError.unsupportedContract("Native crash issue has no identifier or name")
        }
        var fields: [String: JSONValue] = ["issueId": .string(identifier), "name": .string(name), "native": value]
        fields["uniqueDeviceCount"] = native["uniqueDeviceCountFilteredWithTimePeriod"] ?? .null
        fields["uniqueDeviceCountLast24Hours"] = native["uniqueDeviceCountFilteredForLast24Hours"] ?? .null
        return .object(fields)
    }

    static func saveLogs(_ native: [String: JSONValue], directory: URL) -> (logs: [JSONValue], errors: [JSONValue]) {
        guard case .array(let samples) = native["logs"] else {
            return ([], [.object(["operation": .string("logs"), "message": .string("Native response has no sample log list")])])
        }
        var logs: [JSONValue] = []
        var errors: [JSONValue] = []
        for (index, sample) in samples.enumerated() {
            guard case .object(let fields) = sample, case .string(let encoded) = fields["data"],
                  let data = Data(base64Encoded: encoded) else {
                errors.append(.object(["operation": .string("logDecode"), "sampleIndex": .number(.int(Int64(index))),
                    "message": .string("Saved Organizer sample has no valid encoded bytes; the raw cache retains the original value")]))
                continue
            }
            let digest = SHA256.hash(data: data).hexString
            let path = directory.appendingPathComponent(digest + ".crash")
            do {
                try data.write(to: path, options: .atomic)
                logs.append(.object(["logId": .string(digest), "idKind": .string("sha256OfContent"),
                    "bytes": .number(.int(Int64(data.count))), "path": .string(path.path)]))
            } catch { errors.append(diagnostic(error, operation: "logWrite")) }
        }
        return (logs, errors)
    }

    /// Retain native intervals and holes. Missing intervals are not zero devices,
    /// and unique device counts cannot be added across intervals.
    static func timeSeries(_ distribution: JSONValue, timePeriod: String) throws -> JSONValue {
        guard case .object(let root) = distribution else {
            throw NativeRuntimeError.unsupportedContract("Native crash distribution is not an object")
        }
        guard case .object(let body) = root["body"],
              case .object(let series) = body["timeSeriesDistribution"],
              case .array(let periods) = series["timeDistributionMetaDatas"] else {
            throw NativeRuntimeError.unsupportedContract("Native crash distribution has no time series")
        }
        guard let selected = periods.first(where: {
            if case .object(let fields) = $0 { return fields["timePeriod"] == .string(timePeriod) }
            return false
        }), case .object(let fields) = selected else {
            throw NativeRuntimeError.unavailable("Native crash distribution has no \(timePeriod) period")
        }
        var output = fields
        output["metric"] = .string("uniqueDevices")
        output["missingIntervals"] = .string("unknown; native intervals are preserved without filling gaps")
        output["nativeGranularity"] = fields["subTotalBreakByTimePeriod"] ?? .null
        let granularity: String?
        if case .number(.int(let raw)) = fields["subTotalBreakByTimePeriod"] {
            granularity = [0: "hour", 1: "day", 2: "month"][raw]
        } else { granularity = nil }
        output["granularity"] = granularity.map(JSONValue.string) ?? .null
        output["scope"] = .object(["appVersion": .null, "isBeta": .null])
        return .object(output)
    }
}

extension SHA256.Digest {
    var hexString: String {
        let alphabet = Array("0123456789abcdef".utf8)
        return String(decoding: flatMap { [alphabet[Int($0 >> 4)], alphabet[Int($0 & 15)]] }, as: UTF8.self)
    }
}
