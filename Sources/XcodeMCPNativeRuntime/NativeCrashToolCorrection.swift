import ABIBridge
import Foundation
import XcodeMCPWire

@safe
@MainActor
final class NativeCrashToolCorrection {
    enum Kind: String, CaseIterable {
        case sync = "SyncCrashReports"
        case read = "ReadCrashChanges"
        case start = "StartCrashSync"
        case wait = "WaitForCrashSync"
        case cancel = "CancelCrashSync"

        var toolName: String { rawValue }
    }

    private let runtime = ABIRuntime.shared
    private let installation: NativeXcodeInstallation
    private let service: NativeOrganizerCrashService
    private var jobOwners: [URL: NativeCrashSyncJobs] = [:]
    private var operations: [UUID: (request: URL?, task: Task<Void, Never>)] = [:]

    init(installation: NativeXcodeInstallation) {
        self.installation = installation
        service = NativeOrganizerCrashService(installation: installation)
    }

    func execute(_ kind: Kind, input: Data, context: NativeToolContext) throws -> AsyncStream<Data> {
        let operation: Operation
        do {
            switch kind {
            case .sync: operation = .sync(try JSONDecoder().decode(NativeCrashSyncRequest.self, from: input))
            case .read: operation = .read(try JSONDecoder().decode(NativeCrashReadRequest.self, from: input))
            case .start:
                let request = try JSONDecoder().decode(NativeCrashSyncRequest.self, from: input)
                guard request.cursor == nil else {
                    throw NativeRuntimeError.invalidRequest("Use SyncCrashReports to continue a local import cursor")
                }
                _ = try Self.explicitQuery(request.query)
                _ = try Self.collection(request.collection, input: request.query)
                operation = .start(request, .object(try NativeCrashStore.object(input)))
            case .wait: operation = .wait(try JSONDecoder().decode(NativeCrashJobWaitRequest.self, from: input))
            case .cancel: operation = .cancel(try JSONDecoder().decode(NativeCrashJobIDRequest.self, from: input))
            }
        } catch let error as DecodingError {
            throw NativeRuntimeError.invalidRequest(String(describing: error))
        }
        let result = AsyncStream<Data>.makeStream()
        let identifier = UUID()
        let task = Task { @MainActor in
            defer {
                operations[identifier] = nil
                result.continuation.finish()
            }
            do {
                try Task.checkCancellation()
                let payload: JSONValue
                switch operation {
                case .start(let request, let input):
                    let query = try Self.explicitQuery(request.query)
                    let collection = try Self.collection(request.collection, input: request.query)
                    payload = try jobs(at: context.crashCacheRoot).start(input: input) { [self] job in
                        try await runJob(request, query: query, collection: collection,
                            job: job, cacheRoot: context.crashCacheRoot)
                    }
                case .wait(let request):
                    payload = try await jobs(at: context.crashCacheRoot).wait(jobID: request.jobID, timeout: request.waitSeconds, afterRevision: request.afterRevision)
                case .cancel(let request):
                    payload = try jobs(at: context.crashCacheRoot).cancel(jobID: request.jobID)
                case .sync(let request):
                    let store = try NativeCrashSyncStore(root: context.crashCacheRoot)
                    if let cursor = request.cursor {
                        payload = try await store.resumeSync(cursor,
                            matching: Self.constraints(request.query, collection: request.collection,
                                options: request.specifiedFields.contains("max_records") ? ["max_records": request.maxRecords] : [:],
                                maxBytes: request.specifiedFields.contains("max_bytes") ? request.maxBytes : nil))
                    } else {
                        let collection = try Self.collection(request.collection, input: request.query)
                        let query: NativeCrashQuery
                        switch try await resolve(request.query) {
                        case .resolved(let value): query = value
                        case .selectionRequired(let identifiers):
                            throw NativeRuntimeError.invalidRequest("Specify bundle_id. Available apps: " + identifiers.joined(separator: ", "))
                        case .platformSelectionRequired(_, let platforms):
                            throw NativeRuntimeError.invalidRequest("Specify platform. Available platforms: " + platforms.joined(separator: ", "))
                        }
                        let sourceStore = NativeCrashStore(root: context.crashCacheRoot.appending(component: "SourceSnapshots"))
                        let loaded = try await NativeCrashData.load(key: query.json(issueID: collection == .logs ? request.query.issueID : nil),
                            source: request.source, store: sourceStore) { [self] in
                            let prepared = try await serviceQuery(query)
                            if collection == .issues { return try await service.fetchIssues(prepared, store: sourceStore) }
                            return try await service.fetchIssue(prepared, issueID: request.query.issueID!)
                        }
                        let snapshot = try Self.snapshot(collection: collection, query: query,
                            issueID: request.query.issueID, loaded: loaded)
                        payload = try await store.synchronize(snapshot, maxRecords: request.maxRecords, maxBytes: request.maxBytes)
                    }
                case .read(let request):
                    let store = try NativeCrashSyncStore(root: context.crashCacheRoot)
                    if let cursor = request.cursor {
                        payload = try await store.resumeRead(cursor,
                            matching: Self.constraints(request.query, collection: request.collection, order: request.order,
                                options: request.specifiedFields.contains("limit") ? ["limit": request.limit] : [:],
                                maxBytes: request.specifiedFields.contains("max_bytes") ? request.maxBytes : nil))
                    } else {
                        let query: JSONValue?
                        let collection: NativeCrashCollection?
                        if request.checkpoint != nil {
                            collection = request.collection
                            query = try Self.constraints(request.query, collection: request.collection)
                        } else {
                            let resolved = try Self.collection(request.collection, input: request.query)
                            collection = resolved
                            query = try Self.scope(Self.explicitQuery(request.query), collection: resolved,
                                issueID: request.query.issueID)
                        }
                        let order = request.order ?? .observedNewestFirst
                        if collection == .issues, order == .occurredAtDescending {
                            throw NativeRuntimeError.invalidRequest("occurredAtDescending is available only for logs")
                        }
                        payload = try await store.readChanges(collection: collection, query: query,
                            checkpoint: request.checkpoint, limit: request.limit, maxBytes: request.maxBytes, order: order)
                    }
                }
                try Task.checkCancellation()
                let failed: Bool
                if case .object(let fields) = payload { failed = fields["status"] == .string("failed") }
                else { failed = false }
                result.continuation.yield(try event(failed ? "error" : "completed", data: payload))
            } catch is CancellationError {
                return
            } catch {
                result.continuation.yield(errorEvent(error, operation: operation))
            }
        }
        operations[identifier] = (context.artifactsDirectory, task)
        result.continuation.onTermination = { _ in task.cancel() }
        return result.stream
    }

    private enum Operation {
        case sync(NativeCrashSyncRequest)
        case read(NativeCrashReadRequest)
        case start(NativeCrashSyncRequest, JSONValue)
        case wait(NativeCrashJobWaitRequest)
        case cancel(NativeCrashJobIDRequest)

        var query: NativeCrashRequest? {
            switch self {
            case .sync(let request), .start(let request, _): request.query
            case .read(let request): request.query
            case .wait, .cancel: nil
            }
        }

        var collection: NativeCrashCollection? {
            switch self {
            case .sync(let request), .start(let request, _):
                request.collection ?? (request.cursor == nil ? (request.query.issueID == nil ? .issues : .logs) : nil)
            case .read(let request):
                request.collection ?? (request.cursor == nil && request.checkpoint == nil
                    ? (request.query.issueID == nil ? .issues : .logs) : nil)
            case .wait, .cancel: nil
            }
        }
    }

    func cancelPendingOperations() {
        for operation in Array(operations.values) { operation.task.cancel() }
    }

    func shutdown() async {
        let pending = operations.values.map(\.task)
        for operation in pending { operation.cancel() }
        for operation in pending { await operation.value }
        for owner in jobOwners.values { await owner.shutdown() }
    }

    func finishExecution(request: URL) async {
        let pending = operations.values.filter { $0.request == request }.map(\.task)
        if Task.isCancelled { for task in pending { task.cancel() } }
        for task in pending { await task.value }
    }

    private func jobs(at root: URL) throws -> NativeCrashSyncJobs {
        if let owner = jobOwners[root] { return owner }
        let owner = try NativeCrashSyncJobs(root: root)
        jobOwners[root] = owner
        return owner
    }

    private func runJob(_ request: NativeCrashSyncRequest, query: NativeCrashQuery,
                        collection: NativeCrashCollection, job: NativeCrashSyncJobs.Context,
                        cacheRoot: URL) async throws -> JSONValue {
        try job.setInput(.object([
            "bundle_id": .string(query.bundleIdentifier),
            "platform": request.query.platform.map(JSONValue.string) ?? .null,
            "upload_platform": (request.query.uploadPlatform ?? request.query.platform).map(JSONValue.string) ?? .null,
            "app_version": query.appVersion.map(JSONValue.string) ?? .null,
            "is_beta": query.isBeta.map(JSONValue.bool) ?? .null,
            "issue_id": request.query.issueID.map(JSONValue.string) ?? .null,
            "collection": .string(collection.rawValue), "time_period": .string(query.timePeriod),
            "source": .string(request.source.rawValue),
            "max_records": .number(.int(Int64(request.maxRecords))),
            "max_bytes": .number(.int(Int64(request.maxBytes))),
        ]))
        try job.updateProgress(["phase": .string("acquiring"),
            "query": Self.scope(query, collection: collection, issueID: request.query.issueID)])
        let sourceStore = NativeCrashStore(root: cacheRoot.appending(component: "SourceSnapshots"))
        let pageStore = NativeCrashStore(root: job.directory.appending(component: "Pages"))
        let observe: NativeOrganizerCrashService.Observer = { fields in try job.updateProgress(fields) }
        var prepared: NativeCrashServiceQuery?
        let loaded: NativeCrashData.Loaded
        do {
            loaded = try await NativeCrashData.load(key: query.json(issueID: collection == .logs ? request.query.issueID : nil),
                source: request.source, store: sourceStore) { [self] in
                let serviceRequest = try await serviceQuery(query)
                prepared = serviceRequest
                if collection == .issues {
                    return try await service.fetchIssues(serviceRequest, store: pageStore, observe: observe)
                }
                return try await service.fetchIssue(serviceRequest, issueID: request.query.issueID!, observe: observe)
            }
        } catch {
            let original = error
            // Preserve captured data after cancellation in an independent cleanup task.
            let preservation = Task { @MainActor [self] in
                guard let prepared else { return }
                let recovered: NativeCrashData.Fetched?
                if collection == .issues {
                    let record = try NativeCrashStore.object(Data(contentsOf: job.directory.appending(component: "job.json")))
                    var descriptors: [JSONValue] = []
                    if case .object(let progress) = record["progress"], case .array(let pages) = progress["pages"] { descriptors = pages }
                    recovered = try NativeOrganizerCrashService.savedPages(prepared, store: pageStore,
                        descriptors: descriptors, after: original)
                } else {
                    recovered = try service.savedIssue(prepared, issueID: request.query.issueID!, after: original)
                }
                guard let recovered else { return }
                let saved = NativeCrashData.Loaded(value: recovered.value, source: recovered.source,
                    fetchedAt: recovered.fetchedAt, errors: recovered.errors, isComplete: false)
                let snapshot = try Self.snapshot(collection: collection, query: query, issueID: request.query.issueID, loaded: saved)
                let store = try NativeCrashSyncStore(root: cacheRoot)
                try job.updateProgress(["phase": .string("importing")])
                let result = try await store.synchronize(snapshot, maxRecords: request.maxRecords, maxBytes: request.maxBytes)
                try job.setResult(result)
                if case .object(let fields) = result, let info = fields["cacheInfo"] {
                    try job.updateProgress(["cacheInfo": info])
                }
            }
            do { try await preservation.value }
            catch {
                throw NSError(domain: "XcodeMCPKit.CrashSyncJob", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Crash acquisition and partial-result preservation failed",
                    NSMultipleUnderlyingErrorsKey: [original as NSError, error as NSError],
                ])
            }
            throw original
        }
        let snapshot = try Self.snapshot(collection: collection, query: query, issueID: request.query.issueID, loaded: loaded)
        let store = try NativeCrashSyncStore(root: cacheRoot)
        try job.updateProgress(["phase": .string("importing")])
        var result = try await store.synchronize(snapshot, maxRecords: request.maxRecords, maxBytes: request.maxBytes)
        while true {
            try job.setResult(result)
            if case .object(let fields) = result {
                try job.updateProgress(["phase": .string("importing"), "cacheInfo": fields["cacheInfo"] ?? .object([:])])
                if case .object(let info) = fields["cacheInfo"], case .number(.int(let failed)) = info["failedCount"], failed > 0 {
                    return result
                }
                guard case .string(let cursor) = fields["nextCursor"] else { return result }
                try Task.checkCancellation()
                result = try await store.resumeSync(cursor)
            } else { return result }
        }
    }

    private func serviceQuery(_ query: NativeCrashQuery) async throws -> NativeCrashServiceQuery {
        try await waitForProductInventory()
        let getter = try runtime.object(productManager()).resolveAndWait(.objc(.method("products", as: (() -> NSArray).self)))
        let products = try unsafe getter.unsafeInvoke()
        for value in products {
            let product = value as AnyObject
            guard let identifier = try object(product, selector: "identifier"),
                  let category = try object(identifier, selector: "productCategory"),
                  let platform = try object(category, selector: "platform") else { continue }
            let bundle = try runtime.object(identifier).resolveAndWait(.objc(.method("bundleIdentifier", as: (() -> String?).self)))
            let platformID = try runtime.object(platform).resolveAndWait(.objc(.method("identifier", as: (() -> String).self)))
            guard try unsafe bundle.unsafeInvoke() == query.bundleIdentifier,
                  try unsafe platformID.unsafeInvoke() == query.uploadPlatformIdentifier,
                  let adam = try object(product, selector: "adamId") else { continue }
            return NativeCrashServiceQuery(query: query, adamIdentifier: String(describing: adam))
        }
        throw NativeRuntimeError.unavailable("No App Store product matches \(query.bundleIdentifier) on upload platform \(query.uploadPlatformIdentifier)")
    }

    static func collection(_ explicit: NativeCrashCollection?, input: NativeCrashRequest) throws -> NativeCrashCollection {
        let collection = explicit ?? (input.issueID == nil ? .issues : .logs)
        if collection == .logs {
            guard let issueID = input.issueID, !issueID.isEmpty else {
                throw NativeRuntimeError.invalidRequest("Log synchronization and reading require issue_id from the issues collection")
            }
            guard input.appVersion == nil, input.isBeta == nil else {
                throw NativeRuntimeError.invalidRequest("Log samples cover all app versions and release channels; app_version and is_beta apply only to issues")
            }
        } else if input.issueID != nil {
            throw NativeRuntimeError.invalidRequest("issue_id identifies a logs collection; omit it for issues")
        }
        return collection
    }

    static func explicitQuery(_ input: NativeCrashRequest) throws -> NativeCrashQuery {
        guard let bundle = input.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines), !bundle.isEmpty,
              let platform = input.platform else {
            throw NativeRuntimeError.invalidRequest("ReadCrashChanges requires bundle_id and platform, or a saved cursor/checkpoint")
        }
        let execution = try NativeCrashQuery.platformIdentifier(for: platform)
        let upload = try input.uploadPlatform.map(NativeCrashQuery.platformIdentifier(for:)) ?? execution
        return NativeCrashQuery(bundleIdentifier: bundle, platformIdentifier: execution,
            uploadPlatformIdentifier: upload, appVersion: input.appVersion, isBeta: input.isBeta,
            timePeriod: input.timePeriod, pageIndex: 0, pageSize: 25, collectsAllPages: true)
    }

    static func scope(_ query: NativeCrashQuery, collection: NativeCrashCollection, issueID: String?) -> JSONValue {
        guard case .object(var fields) = query.json(issueID: collection == .logs ? issueID : nil) else { return .null }
        fields.removeValue(forKey: "page")
        fields.removeValue(forKey: "pageSize")
        fields.removeValue(forKey: "allPages")
        fields["collection"] = .string(collection.rawValue)
        return .object(fields)
    }

    static func constraints(_ input: NativeCrashRequest, collection: NativeCrashCollection?,
                            order: NativeCrashReadOrder? = nil, options: [String: Int] = [:],
                            maxBytes: Int? = nil) throws -> JSONValue? {
        var fields: [String: JSONValue] = [:]
        for key in input.specifiedFields {
            switch key {
            case "bundle_id": fields["bundleId"] = input.bundleIdentifier.map { .string($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? .null
            case "platform": fields["platform"] = try input.platform.map { .string(try NativeCrashQuery.platformIdentifier(for: $0)) } ?? .null
            case "upload_platform": fields["uploadPlatform"] = try input.uploadPlatform.map { .string(try NativeCrashQuery.platformIdentifier(for: $0)) } ?? .null
            case "app_version": fields["appVersion"] = input.appVersion.map(JSONValue.string) ?? .null
            case "is_beta": fields["isBeta"] = input.isBeta.map(JSONValue.bool) ?? .null
            case "time_period": fields["timePeriod"] = .string(input.timePeriod)
            case "issue_id": fields["issueId"] = input.issueID.map(JSONValue.string) ?? .null
            default: break
            }
        }
        if let collection { fields["collection"] = .string(collection.rawValue) }
        if let order { fields["order"] = .string(order.rawValue) }
        for (key, value) in options { fields[key] = .number(.int(Int64(value))) }
        if let maxBytes { fields["max_bytes"] = .number(.int(Int64(maxBytes))) }
        return fields.isEmpty ? nil : .object(fields)
    }

    static func snapshot(collection: NativeCrashCollection, query: NativeCrashQuery,
                         issueID: String?, loaded: NativeCrashData.Loaded) throws -> NativeCrashSyncSnapshot {
        let key = scope(query, collection: collection, issueID: issueID)
        var metadata: [String: JSONValue] = ["query": key, "provenance": loaded.provenance,
            "importProvenance": loaded.provenance]
        var issues: [JSONValue] = []
        var logDirectory: URL?
        let sourceAvailable = loaded.value != nil || loaded.recovery != nil
        var complete = loaded.isComplete && sourceAvailable
        var sourceObservedAt = loaded.fetchedAt
        var errors = loaded.errors
        if case .object(let native)? = loaded.value {
            metadata["native"] = sourceMetadata(.object(native))
            if collection == .issues {
                if case .array(let points) = native["points"] { issues = try points.map(NativeCrashData.issue) }
                else { throw NativeRuntimeError.unsupportedContract("Native crash list has no points array") }
            } else {
                if case .string(let path) = native["logDirectory"] { logDirectory = URL(fileURLWithPath: path, isDirectory: true) }
                if let distribution = native["distribution"] {
                    do { metadata["timeSeries"] = try NativeCrashData.timeSeries(distribution, timePeriod: query.timePeriod) }
                    catch { errors.append(NativeCrashData.diagnostic(error, operation: "timeSeries")) }
                }
                metadata["logFilters"] = .object(["appVersion": .null, "isBeta": .null,
                    "limitation": .string("Organizer's saved samples and distributions cover all app versions and release channels; saved sample counts are not crash occurrences or affected devices.")])
            }
        }
        if let recovery = loaded.recovery {
            let provenance = NativeCrashData.Loaded(value: recovery.value,
                source: recovery.source, fetchedAt: recovery.fetchedAt, errors: recovery.errors).provenance
            metadata["recovery"] = .object(["provenance": provenance,
                "native": sourceMetadata(recovery.value), "errors": .array(recovery.errors)])
            if case .object(let native) = recovery.value {
                if collection == .logs, case .string(let path) = native["logDirectory"] {
                    logDirectory = URL(fileURLWithPath: path, isDirectory: true)
                    complete = recovery.isComplete
                    sourceObservedAt = recovery.fetchedAt
                    metadata["importProvenance"] = provenance
                } else if collection == .issues, case .array(let points) = native["points"] {
                    issues = try points.map(NativeCrashData.issue)
                    complete = recovery.isComplete
                    sourceObservedAt = recovery.fetchedAt
                    metadata["importProvenance"] = provenance
                }
            }
        }
        var snapshot = NativeCrashSyncSnapshot(collection: collection, query: key, metadata: .object(metadata),
            issues: issues, logDirectory: logDirectory, isComplete: complete, errors: errors)
        snapshot.sourceAvailable = sourceAvailable
        snapshot.sourceObservedAt = sourceObservedAt.flatMap { value in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions.remove(.withFractionalSeconds)
            return formatter.date(from: value)
        }
        return snapshot
    }

    private static func sourceMetadata(_ value: JSONValue) -> JSONValue {
        guard case .object(var fields) = value else { return value }
        for key in ["points", "issues", "logs", "organizerCache", "copiedPages"] {
            fields.removeValue(forKey: key)
        }
        return .object(fields)
    }

    private func resolve(_ input: NativeCrashRequest) async throws -> NativeCrashResolution {
        let workspace: AnyObject?
        if input.bundleIdentifier == nil || input.platform == nil {
            workspace = try await self.workspace(identifier: input.workspaceIdentifier)
        } else { workspace = nil }
        let bundle: String
        if let explicit = input.bundleIdentifier {
            bundle = explicit.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            if let identifier = try bundleFromActiveScheme(workspace) {
                bundle = identifier
            } else {
                try await waitForProductInventory()
                let identifiers = try availableBundleIdentifiers()
                guard identifiers.count == 1, let only = identifiers.first else {
                    return .selectionRequired(identifiers)
                }
                bundle = only
            }
        }
        guard !bundle.isEmpty else { throw NativeRuntimeError.invalidRequest("The bundle identifier is empty") }
        let executionIdentifier: String
        if let name = input.platform {
            executionIdentifier = try NativeCrashQuery.platformIdentifier(for: name)
        } else {
            try await waitForProductInventory()
            let choices = try productPlatforms(bundleIdentifier: bundle)
            if choices.count == 1, let only = choices.first {
                let identifier = try runtime.object(only).resolveAndWait(.objc(.method("identifier", as: (() -> String).self)))
                executionIdentifier = try unsafe identifier.unsafeInvoke()
            } else {
                guard let workspace,
                      let manager = try object(workspace, selector: "runContextManager"),
                      let destination = try object(manager, selector: "activeRunDestination"),
                      let sdk = try object(destination, selector: "targetSDK"),
                      let value = try object(sdk, selector: "platform"),
                      let family = try object(value, selector: "family") else {
                    if choices.count > 1 {
                        let names = try choices.map { choice -> String in
                            guard let family = try object(choice, selector: "family") else {
                                throw NativeRuntimeError.unsupportedContract("Native analytics platform has no family")
                            }
                            let getter = try runtime.object(family).resolveAndWait(.objc(.method("displayName", as: (() -> String).self)))
                            return try unsafe getter.unsafeInvoke()
                        }
                        return .platformSelectionRequired(bundleIdentifier: bundle, platforms: Array(Set(names)).sorted())
                    }
                    throw NativeRuntimeError.invalidRequest("Could not resolve the platform from the active run destination")
                }
                let description = try runtime.object(family).resolveAndWait(.objc(.method("displayName", as: (() -> String).self)))
                executionIdentifier = try unsafe NativeCrashQuery.platformIdentifier(for: description.unsafeInvoke())
            }
        }
        let uploadIdentifier = try input.uploadPlatform.map(NativeCrashQuery.platformIdentifier(for:)) ?? executionIdentifier
        return .resolved(NativeCrashQuery(bundleIdentifier: bundle, platformIdentifier: executionIdentifier,
            uploadPlatformIdentifier: uploadIdentifier, appVersion: input.appVersion, isBeta: input.isBeta,
            timePeriod: input.timePeriod, pageIndex: 0, pageSize: 25, collectsAllPages: true))
    }

    private func bundleFromActiveScheme(_ workspace: AnyObject?) throws -> String? {
        guard let workspace,
              let manager = try object(workspace, selector: "runContextManager"),
              let context = try object(manager, selector: "activeRunContext"),
              let action = try object(context, selector: "launchSchemeAction"),
              let product = try object(action, selector: "buildableProductForPlaceholderPathRunnable") else { return nil }
        guard let actionClass = NSClassFromString("IDESchemeAction") else {
            throw NativeRuntimeError.unsupportedContract("Xcode's scheme action class is unavailable")
        }
        let getter = try runtime.object(actionClass as AnyObject).resolveAndWait(
            .objc(.method("bundleIdentifierFromBuildableProduct:withBuildParameters:", as: ((AnyObject, AnyObject?) -> String?).self)))
        return try unsafe getter.unsafeInvoke(product, nil)
    }

    private func availableBundleIdentifiers() throws -> [String] {
        let getter = try runtime.object(productManager()).resolveAndWait(.objc(.method("products", as: (() -> NSArray).self)))
        let products = try unsafe getter.unsafeInvoke()
        var identifiers = Set<String>()
        for product in products {
            let appStoreID = try runtime.object(product as AnyObject).resolveAndWait(.objc(.method("adamId", as: (() -> AnyObject?).self)))
            guard try unsafe appStoreID.unsafeInvoke() != nil,
                  let identifier = try object(product as AnyObject, selector: "identifier") else { continue }
            let bundle = try runtime.object(identifier).resolveAndWait(.objc(.method("bundleIdentifier", as: (() -> String?).self)))
            if let value = try unsafe bundle.unsafeInvoke() { identifiers.insert(value) }
        }
        return identifiers.sorted()
    }

    private func productManager() throws -> AnyObject {
        guard let type = NSClassFromString("IDEProductManager") else {
            throw NativeRuntimeError.unsupportedContract("Xcode's product manager is unavailable")
        }
        let getter = try runtime.object(type as AnyObject).resolveAndWait(.objc(.method("defaultManager", as: (() -> AnyObject).self)))
        return try unsafe getter.unsafeInvoke()
    }

    private func waitForProductInventory() async throws {
        let manager = try productManager()
        let started = try runtime.object(manager).resolveAndWait(.objc(.method("hasStartedLocating", as: (() -> Bool).self)))
        if try unsafe !started.unsafeInvoke() {
            let load = try runtime.object(manager).resolveAndWait(.objc(.method("load", as: (() -> Void).self)))
            try unsafe load.unsafeInvoke()
        }
        let completed = try runtime.object(manager).resolveAndWait(.objc(.method("hasCompletedInitialLoading", as: (() -> Bool).self)))
        while try unsafe !completed.unsafeInvoke() {
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func platformFamilyIdentifier(_ platform: AnyObject) throws -> String {
        guard let family = try object(platform, selector: "family") else {
            throw NativeRuntimeError.unsupportedContract("Native analytics platform has no family")
        }
        let getter = try runtime.object(family).resolveAndWait(.objc(.method("identifier", as: (() -> String).self)))
        return try unsafe getter.unsafeInvoke()
    }

    private func productPlatforms(bundleIdentifier: String) throws -> [AnyObject] {
        let getter = try runtime.object(productManager()).resolveAndWait(.objc(.method("products", as: (() -> NSArray).self)))
        let products = try unsafe getter.unsafeInvoke()
        var platforms: [String: AnyObject] = [:]
        for product in products {
            guard let identifier = try object(product as AnyObject, selector: "identifier") else { continue }
            let bundle = try runtime.object(identifier).resolveAndWait(.objc(.method("bundleIdentifier", as: (() -> String?).self)))
            guard try unsafe bundle.unsafeInvoke() == bundleIdentifier,
                  let category = try object(identifier, selector: "productCategory"),
                  let platform = try object(category, selector: "platform") else { continue }
            let key = try platformFamilyIdentifier(platform)
            if platforms[key] == nil { platforms[key] = platform }
        }
        return Array(platforms.values)
    }

    private func workspace(identifier: String?) async throws -> AnyObject? {
        guard let identifier else { return nil }
        let type = try await runtime.resolve(.swift(.type("IDEFoundation.IDEWorkspaceRegistry")), in: .path(installation.framework("IDEFoundation")))
        let shared = try await type.resolve(.swift(.staticGetter("shared.getter : IDEFoundation.IDEWorkspaceRegistry", as: (() -> AnyObject).self)))
        let registry = try unsafe shared.unsafeInvoke()
        let lookup = try await runtime.object(registry).resolve(
            .swift(.method("workspace(withIdentifier: Swift.String) -> Swift.Optional<__C.IDEWorkspace>", as: ((String) -> AnyObject?).self)))
        return try unsafe lookup.unsafeInvoke(identifier)
    }

    private func object(_ receiver: AnyObject, selector: String) throws -> AnyObject? {
        let getter = try runtime.object(receiver).resolveAndWait(.objc(.method(selector, as: (() -> AnyObject?).self)))
        return try unsafe getter.unsafeInvoke()
    }


    private func event(_ type: String, data: JSONValue) throws -> Data {
        try JSONRPC.Wire.data(from: ["type": type, "data": data.foundationObject])
    }

    private func errorEvent(_ error: any Error, operation: Operation) -> Data {
        let query = operation.query.flatMap { try? Self.constraints($0, collection: operation.collection) } ?? .object([:])
        do {
            return try event("error", data: .object(["status": .string("failed"),
                "collection": operation.collection.map { .string($0.rawValue) } ?? .null,
                "query": query,
                "errors": .array([NativeCrashData.diagnostic(error, operation: "crashReports")])]))
        }
        catch let encodingError {
            NativeHostDiagnostic.report("Native analytics failed: \(error); error encoding also failed: \(encodingError)")
            return Data(#"{"type":"error","data":"Could not encode the native analytics failure; see host diagnostics"}"#.utf8)
        }
    }
}

private enum NativeCrashResolution {
    case resolved(NativeCrashQuery)
    case selectionRequired([String])
    case platformSelectionRequired(bundleIdentifier: String, platforms: [String])
}
