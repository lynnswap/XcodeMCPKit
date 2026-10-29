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
    var issueID: String?
    var source = Source.network
    var specifiedFields: Set<String> = []

    enum Source: String, Decodable, Sendable {
        case network, cache, networkWithCacheFallback
    }

    private enum CodingKeys: String, CodingKey {
        case workspaceIdentifier, platform, source
        case uploadPlatform = "upload_platform"
        case bundleIdentifier = "bundle_id", appVersion = "app_version", isBeta = "is_beta"
        case timePeriod = "time_period", issueID = "issue_id"
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        specifiedFields = Set(values.allKeys.map(\.rawValue))
        workspaceIdentifier = try values.decodeIfPresent(String.self, forKey: .workspaceIdentifier)
        bundleIdentifier = try values.decodeIfPresent(String.self, forKey: .bundleIdentifier)
        platform = try values.decodeIfPresent(String.self, forKey: .platform)
        uploadPlatform = try values.decodeIfPresent(String.self, forKey: .uploadPlatform)
        appVersion = try values.decodeIfPresent(String.self, forKey: .appVersion)
        isBeta = try values.decodeIfPresent(Bool.self, forKey: .isBeta)
        timePeriod = try values.decodeIfPresent(String.self, forKey: .timePeriod) ?? timePeriod
        issueID = try values.decodeIfPresent(String.self, forKey: .issueID)
        source = try values.decodeIfPresent(Source.self, forKey: .source) ?? source
        guard ["last24Hours", "last14Days", "last365Days"].contains(timePeriod) else {
            throw NativeRuntimeError.invalidRequest("Unsupported time_period: \(timePeriod)")
        }
    }
}

enum NativeCrashCollection: String, Codable, Sendable {
    case issues, logs
}

enum NativeCrashReadOrder: String, Codable, Sendable {
    case observedNewestFirst, occurredAtDescending
}

struct NativeCrashSyncRequest: Decodable, Sendable {
    let query: NativeCrashRequest
    let collection: NativeCrashCollection?
    let cursor: String?
    let maxRecords: Int
    let maxBytes: Int
    let specifiedFields: Set<String>

    var source: NativeCrashRequest.Source { query.source }

    private enum CodingKeys: String, CodingKey {
        case collection, cursor
        case maxRecords = "max_records", maxBytes = "max_bytes"
    }

    init(from decoder: any Decoder) throws {
        query = try NativeCrashRequest(from: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        specifiedFields = Set(values.allKeys.map(\.rawValue))
        collection = try values.decodeIfPresent(NativeCrashCollection.self, forKey: .collection)
        cursor = try values.decodeIfPresent(String.self, forKey: .cursor)
        maxRecords = try values.decodeIfPresent(Int.self, forKey: .maxRecords) ?? 100
        maxBytes = try values.decodeIfPresent(Int.self, forKey: .maxBytes) ?? 64 * 1024 * 1024
        guard maxRecords > 0, maxBytes > 0 else {
            throw NativeRuntimeError.invalidRequest("max_records and max_bytes must be positive")
        }
    }
}

struct NativeCrashJobIDRequest: Decodable, Sendable {
    let jobID: String

    private enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
    }
}

struct NativeCrashJobWaitRequest: Decodable, Sendable {
    let jobID: String
    let waitSeconds: Double
    let afterRevision: Int64?

    private enum CodingKeys: String, CodingKey {
        case jobID = "job_id", waitSeconds = "wait_seconds", afterRevision = "after_revision"
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        jobID = try values.decode(String.self, forKey: .jobID)
        waitSeconds = try values.decodeIfPresent(Double.self, forKey: .waitSeconds) ?? 1
        afterRevision = try values.decodeIfPresent(Int64.self, forKey: .afterRevision)
        guard (0...30).contains(waitSeconds) else {
            throw NativeRuntimeError.invalidRequest("wait_seconds must be between 0 and 30")
        }
        if let afterRevision, afterRevision < 0 {
            throw NativeRuntimeError.invalidRequest("after_revision must be nonnegative")
        }
    }
}

struct NativeCrashReadRequest: Decodable, Sendable {
    let query: NativeCrashRequest
    let collection: NativeCrashCollection?
    let checkpoint: String?
    let cursor: String?
    let limit: Int
    let maxBytes: Int
    let order: NativeCrashReadOrder?
    let specifiedFields: Set<String>

    private enum CodingKeys: String, CodingKey {
        case collection, checkpoint, cursor, limit, order
        case maxBytes = "max_bytes"
    }

    init(from decoder: any Decoder) throws {
        query = try NativeCrashRequest(from: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        specifiedFields = Set(values.allKeys.map(\.rawValue))
        collection = try values.decodeIfPresent(NativeCrashCollection.self, forKey: .collection)
        checkpoint = try values.decodeIfPresent(String.self, forKey: .checkpoint)
        cursor = try values.decodeIfPresent(String.self, forKey: .cursor)
        limit = try values.decodeIfPresent(Int.self, forKey: .limit) ?? 25
        maxBytes = try values.decodeIfPresent(Int.self, forKey: .maxBytes) ?? 256 * 1024
        order = try values.decodeIfPresent(NativeCrashReadOrder.self, forKey: .order)
        guard limit > 0, maxBytes > 0 else {
            throw NativeRuntimeError.invalidRequest("limit and max_bytes must be positive")
        }
        guard checkpoint == nil || cursor == nil else {
            throw NativeRuntimeError.invalidRequest("Use checkpoint to start a change window or cursor to continue one, not both")
        }
    }
}

enum NativeCrashContract {
    static func describe(_ kind: NativeCrashToolCorrection.Kind) -> NativeTool {
        func property(_ type: String, _ description: String) -> JSONValue {
            .object(["type": .string(type), "description": .string(description)])
        }
        func positiveInteger(_ defaultValue: Int64, _ description: String) -> JSONValue {
            .object(["type": .string("integer"), "minimum": .number(.int(1)),
                "default": .number(.int(defaultValue)), "description": .string(description)])
        }
        if kind == .wait || kind == .cancel || kind == .resume {
            var inputs = ["job_id": property("string", "Job identifier returned by StartCrashSync or ResumeCrashSync.")]
            if kind == .wait {
                inputs["wait_seconds"] = .object(["type": .string("number"),
                    "minimum": .number(.int(0)), "maximum": .number(.int(30)), "default": .number(.int(1)),
                    "description": .string("Maximum seconds to wait for a job update or terminal state. Defaults to 1; 0 returns immediately. Reaching this limit or disconnecting does not cancel the job.")])
                inputs["after_revision"] = .object(["type": .string("integer"), "minimum": .number(.int(0)),
                    "description": .string("Revision from the previous StartCrashSync, ResumeCrashSync, or WaitForCrashSync response. Return when the job has a newer revision, reaches a terminal state, or the wait limit expires. Omit to use the revision at the start of this wait.")])
            }
            let description: String
            if kind == .wait {
                description = "Wait briefly for a crash sync job update or terminal state. A wait timeout or client disconnect leaves the job running. A failed job is returned as job state with its diagnostics."
            } else if kind == .resume {
                description = "Resume an interrupted, failed, or cancelled crash sync as a new job with the saved conditions. Recover saved pages and pending imports, then rescan network sources from the first page. Active and completed jobs cannot be resumed."
            } else {
                description = "Request cancellation of a crash sync job and return promptly. Use WaitForCrashSync to confirm cancellation and Organizer cleanup have finished."
            }
            return describeJob(kind, description: description, inputs: inputs, required: ["job_id"])
        }
        var inputs: [String: JSONValue] = [
            "bundle_id": property("string", "App bundle identifier. Required with platform when no token supplies the query; Sync can infer it from a saved workspace."),
            "platform": property("string", "Execution platform: iOS, macOS, watchOS, tvOS, or visionOS."),
            "upload_platform": property("string", "Original upload platform. Specify iOS for an iOS app running on macOS or visionOS. Defaults to platform for a new query."),
            "app_version": property("string", "Issues collection only: filter by app version. Omit for all versions."),
            "is_beta": property("boolean", "Issues collection only: TestFlight (true) or App Store (false). Omit for both."),
            "time_period": .object(["type": .string("string"),
                "enum": .array([.string("last24Hours"), .string("last14Days"), .string("last365Days")]),
                "description": .string("Aggregation period. Defaults to last14Days for a new query; omitted token continuations retain their scope. Logs and their native distributions cover all versions and release channels.")]),
            "collection": .object(["type": .string("string"), "enum": .array([.string("issues"), .string("logs")]),
                "description": .string("Collection to synchronize or read. A token supplies its collection. For a new query, defaults to logs when issue_id is supplied, otherwise issues.")]),
            "issue_id": property("string", "Stable native issue identifier, required for a new logs query. Display names are not identifiers."),
        ]
        switch kind {
        case .sync, .start:
            if kind == .sync {
                inputs["workspaceIdentifier"] = property("string", "Optional saved workspace for inferring the app and platform. An explicit bundle_id and platform do not require a workspace.")
            }
            inputs["source"] = .object(["type": .string("string"),
                "enum": .array([.string("network"), .string("cache"), .string("networkWithCacheFallback")]),
                "default": .string("network"),
                "description": .string("Applies when starting acquisition. Network starts an owned Xcode Organizer instance using the existing Xcode account and Accessibility permission. Cache imports exact saved data without GUI; explicit bundle_id and platform also bypass product inventory. Fallback preserves failures and the cached data's original provenance.")])
            if kind == .sync {
                inputs["cursor"] = property("string", "Local import continuation returned by SyncCrashReports; does not fetch from the network again. Its budgets are retained, and any explicitly repeated budgets must match. Read cursors and checkpoints belong to ReadCrashChanges.")
            }
            inputs["max_records"] = positiveInteger(100, "Maximum records to import in this acquisition batch.")
            inputs["max_bytes"] = positiveInteger(64 * 1024 * 1024, "Import byte budget. One oversized log file may be streamed alone so acquisition can advance; this is not the response JSON budget.")
        case .read:
            inputs["checkpoint"] = property("string", "Completed ReadCrashChanges checkpoint used as the baseline for a new fixed change window. Omit on the initial read.")
            inputs["cursor"] = property("string", "ReadCrashChanges cursor for the next page of the same fixed window. Retrying the same cursor is stable, including after restart. Do not combine with checkpoint.")
            inputs["limit"] = positiveInteger(25, "Maximum changed records in this response.")
            inputs["max_bytes"] = positiveInteger(256 * 1024, "Maximum encoded structured result bytes, including result metadata and cursors, before MCP/JSON-RPC wrapping. Log bodies are referenced by saved blob paths. A budget smaller than the minimum result fails with the required size. A continuation that has not returned a successful page can increase this budget; saved pages retain their original budget.")
            inputs["order"] = .object(["type": .string("string"),
                "enum": .array([.string("observedNewestFirst"), .string("occurredAtDescending")]),
                "description": .string("Defaults to observedNewestFirst for a new window. A continuation retains its order. occurredAtDescending applies to logs and uses their actual occurrence date when available; it does not substitute observation or file times.")])
        case .wait, .cancel, .resume: break
        }
        if kind == .start {
            inputs["bundle_id"] = property("string", "App bundle identifier. Required for a new job.")
            return describeJob(kind,
                description: "Start crash acquisition and local import as a host-owned job and return promptly. Supply bundle_id and platform explicitly, then use WaitForCrashSync to observe progress and ReadCrashChanges to read committed records.",
                inputs: inputs, required: ["bundle_id", "platform"])
        }
        func token(_ description: String) -> JSONValue {
            .object(["type": .array([.string("string"), .string("null")]), "description": .string(description)])
        }
        var outputs: [String: JSONValue] = [
            "status": .object(["type": .string("string"), "enum": .array([.string("complete"), .string("partial"), .string("failed")]),
                "description": .string("Failed when acquisition has no usable source, including a cache miss; partial when usable source data remains alongside errors. A successful empty source is complete.")]),
            "query": property("object", "Resolved query scope, retained with every continuation; only known requested fields are included if a failure prevents scope resolution."),
            "collection": .object(["type": .array([.string("string"), .string("null")]),
                "description": .string("The issues or logs collection belonging to this query; null when a failure prevents resolving the token's scope.")]),
            "errors": .object(["type": .string("array"), "items": property("object", "Failed operation, original cause, and usable partial-state diagnostics.")]),
            "cursor": token("The immutable acquisition batch or fixed reader page represented by this response."),
            "nextCursor": token("Continuation for the same operation. Retry a cursor without advancing its recorded response; acquisition and reader cursors are different token types."),
            "responsePath": property("string", "Saved complete structured response. Blob and payload paths refer to reusable persistent content."),
        ]
        switch kind {
        case .sync:
            outputs["metadataPath"] = property("string", "Persisted acquisition source metadata, including its original provenance and distributions.")
            outputs["cacheInfo"] = property("object", "Acquisition state: syncId, capturedCount, processedCount, pendingCount, reusedCount, newCount, updatedCount, storedBytes, sourceAvailable, acquisitionComplete, sourceComplete, and nextSyncCursor. sourceAvailable distinguishes a successful empty source from a missing or failed source. Finishing local import does not establish complete upstream coverage.")
        case .read:
            outputs["changes"] = .object(["type": .string("array"), "items": property("object", "New or updated record with itemId, contentId, revision, and change. Logs have logical logId, nativeLogId, reusable blob path, bytes, variant and optional actual occurredAt. Issues have issueId, name, counts and a payloadPath to native JSON.")])
            outputs["checkpoint"] = token("Baseline for a later change window, issued only at the end of this fixed reader window. It tracks locally observed records and is independent of pending acquisition.")
            outputs["cacheInfo"] = property("object", "Reader state: baselineSequence, snapshotSequence, returnedCount, totalChanges, readOffset, readComplete, order, and latestSync with its separate acquisition/source completeness.")
        case .start, .wait, .cancel, .resume: break
        }
        return NativeTool(name: kind.toolName, descriptor: .object([
            "name": .string(kind.toolName),
            "description": .string(kind == .sync
                ? "Import crash issues or saved crash logs into persistent snapshots and reusable content blobs, in bounded acquisition batches. Use ReadCrashChanges to read new or changed records."
                : "Read only new or changed crash records from a fixed local change window, with restart-safe cursors, checkpoints, and a bounded JSON response. Does not operate Xcode or access the network."),
            "annotations": .object(["readOnlyHint": .bool(true)]),
            "inputSchema": .object(["type": .string("object"), "properties": .object(inputs), "required": .array([])]),
            "outputSchema": .object(["type": .string("object"), "properties": .object(outputs),
                "required": .array([.string("status"), .string("query"), .string("collection"), .string("errors")])]),
        ]), workspaceScoped: kind == .sync)
    }

    private static func describeJob(_ kind: NativeCrashToolCorrection.Kind, description: String, inputs: [String: JSONValue],
                                    required: [String]) -> NativeTool {
        let outputs: [String: JSONValue] = [
            "jobId": .object(["type": .string("string"), "description": .string("Persistent crash sync job identifier.")]),
            "previousJobId": .object(["type": .array([.string("string"), .string("null")]),
                "description": .string("Job whose saved conditions and partial results were used to create this resumed job. Null for a new StartCrashSync job; the earlier job and its result remain unchanged.")]),
            "state": .object(["type": .string("string"), "enum": .array([
                "queued", "running", "cancelling", "completed", "failed", "cancelled", "interrupted",
            ].map(JSONValue.string))]),
            "revision": .object(["type": .string("integer"), "description": .string("Job revision, incremented when the saved state or progress changes.")]),
            "createdAt": .object(["type": .string("string")]),
            "updatedAt": .object(["type": .string("string")]),
            "startedAt": .object(["type": .array([.string("string"), .string("null")])]),
            "finishedAt": .object(["type": .array([.string("string"), .string("null")])]),
            "progress": .object(["type": .string("object"),
                "description": .string("Latest phase, capturedPages, capturedRecords, resolved query, import cacheInfo, and recoveredImports with saved response paths, and recoveryErrors for unavailable saved acquisition snapshots. Phases include queued, recovering, waitingForOrganizer, acquiring, and importing.")]),
            "result": .object(["type": .array([.string("object"), .string("null")]),
                "description": .string("Latest SyncCrashReports response, including cumulative cacheInfo, responsePath, and metadataPath. Record import failures stop automatic processing and retain nextCursor for an explicit retry. Source-only errors still allow importing acquired data. Null while no result has been committed.")]),
            "errors": .object(["type": .string("array"), "items": .object(["type": .string("object")]),
                "description": .string("Job failures and cleanup diagnostics. A failed job state does not make a successful status query an MCP error.")]),
        ]
        var requiredOutputs = ["jobId", "state", "revision", "createdAt", "updatedAt", "progress", "result", "errors"]
        if kind == .resume { requiredOutputs.append("previousJobId") }
        return NativeTool(name: kind.toolName, descriptor: .object([
            "name": .string(kind.toolName), "description": .string(description),
            "annotations": .object(["readOnlyHint": .bool(kind == .wait)]),
            "inputSchema": .object(["type": .string("object"), "properties": .object(inputs),
                "required": .array(required.map(JSONValue.string))]),
            "outputSchema": .object(["type": .string("object"), "properties": .object(outputs),
                "required": .array(requiredOutputs.map(JSONValue.string))]),
        ]), workspaceScoped: false)
    }
}

/// Cache entries belong to a complete native request, including its page. They
/// never use Organizer's most-recent LRU item as a substitute for that request.
struct NativeCrashStore {
    let root: URL

    struct Entry {
        let value: JSONValue
        let fetchedAt: String?
        let path: String
        var errors: [JSONValue] = []
        var isComplete = true
    }

    func read(key: JSONValue) throws -> Entry? {
        let url = try location(key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let envelope = try Self.object(Data(contentsOf: url))
        guard envelope["query"] == key, let value = envelope["value"] else {
            throw NativeRuntimeError.unsupportedContract("Crash cache does not match its request: \(url.path)")
        }
        let fetchedAt: String?
        switch envelope["fetchedAt"] {
        case .string(let timestamp): fetchedAt = timestamp
        case .null: fetchedAt = nil
        default: throw NativeRuntimeError.unsupportedContract("Crash cache has no valid fetch time: \(url.path)")
        }
        let errors: [JSONValue]
        if case .array(let failures) = envelope["errors"] { errors = failures }
        else { errors = [] }
        let isComplete: Bool
        switch envelope["isComplete"] {
        case .bool(let complete): isComplete = complete
        case nil: isComplete = false
        default: throw NativeRuntimeError.unsupportedContract("Crash cache has no valid source completeness: \(url.path)")
        }
        return Entry(value: value, fetchedAt: fetchedAt, path: url.path, errors: errors, isComplete: isComplete)
    }

    func write(_ value: JSONValue, key: JSONValue, fetchedAt: String?, errors: [JSONValue] = [], isComplete: Bool = true) throws -> Entry {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = try location(key)
        let envelope: JSONValue = .object(["query": key, "value": value,
            "fetchedAt": fetchedAt.map(JSONValue.string) ?? .null, "errors": .array(errors), "isComplete": .bool(isComplete)])
        try Self.encode(envelope).write(to: url, options: .atomic)
        return Entry(value: value, fetchedAt: fetchedAt, path: url.path, errors: errors, isComplete: isComplete)
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
        let fetchedAt: String?
        var source = "organizer"
        var errors: [JSONValue] = []
        var isComplete = true
    }

    struct Loaded {
        var value: JSONValue?
        var source: String?
        var fetchedAt: String?
        var cachePath: String?
        var recovery: Fetched?
        var errors: [JSONValue] = []
        var isComplete = false

        var provenance: JSONValue {
            .object(["source": source.map(JSONValue.string) ?? .null,
                "fetchedAt": fetchedAt.map(JSONValue.string) ?? .null,
                "cachePath": cachePath.map(JSONValue.string) ?? .null,
                "sourceUpdatedAt": .null,
                "changeDetection": .string("refetch"),
                "changeDetectionReason": .string("Xcode provides a local cache refresh time, but no server revision or conditional change token.")])
        }
    }

    @MainActor
    static func load(key: JSONValue, source: NativeCrashRequest.Source, store: NativeCrashStore,
                     fetch: () async throws -> Fetched) async throws -> Loaded {
        var result = Loaded()
        if source != .cache {
            do {
                let fetched = try await fetch()
                if Task.isCancelled, !fetched.errors.isEmpty {
                    throw NSError(domain: "XcodeMCPKit.CrashAcquisition", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "Crash acquisition was cancelled with provider diagnostics",
                        NSUnderlyingErrorKey: CancellationError(),
                        "XcodeMCPKit.CrashDiagnostics": fetched.errors.map(\.foundationObject),
                    ])
                }
                try Task.checkCancellation()
                result.value = fetched.value
                result.source = fetched.source
                result.fetchedAt = fetched.fetchedAt
                result.errors = fetched.errors
                result.isComplete = fetched.isComplete
                if !fetched.isComplete {
                    do {
                        if let entry = try store.read(key: key) {
                            if source == .networkWithCacheFallback {
                                result.value = entry.value
                                result.source = "cache"
                                result.fetchedAt = entry.fetchedAt
                                result.cachePath = entry.path
                                result.recovery = fetched
                                result.errors += entry.errors
                                result.isComplete = entry.isComplete
                            }
                            return result
                        }
                    } catch { result.errors.append(diagnostic(error, operation: "cacheRead")) }
                }
                do {
                    let entry = try store.write(fetched.value, key: key, fetchedAt: fetched.fetchedAt,
                        errors: result.errors, isComplete: fetched.isComplete)
                    result.cachePath = entry.path
                } catch { result.errors.append(diagnostic(error, operation: "cacheWrite")) }
                return result
            } catch {
                if Task.isCancelled || error is CancellationError { throw error }
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
                result.isComplete = entry.isComplete
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
                "message": .string((error as? NativeRuntimeError)?.description ?? native.localizedDescription), "type": .string(String(reflecting: type(of: error)))]
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
