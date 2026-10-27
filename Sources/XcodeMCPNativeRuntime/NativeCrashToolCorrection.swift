import ABIBridge
import Foundation
import XcodeMCPWire

@safe
@MainActor
final class NativeCrashToolCorrection {
    enum Kind {
        case topIssues, logs

        var toolName: String { self == .topIssues ? "ListCrashIssues" : "GetCrashIssue" }

        static func forAction(_ action: NativeActionClass) -> Kind? {
            let type = unsafe unsafeBitCast(action.metadata, to: Any.Type.self)
            switch String(reflecting: type) {
            case "IDEAnalyticsKit.GetTopCrashIssuesAction": return .topIssues
            case "IDEAnalyticsKit.GetCrashIssueLogsAction": return .logs
            default: return nil
            }
        }
    }

    private let runtime = ABIRuntime.shared
    private let installation: NativeXcodeInstallation
    private let service: NativeOrganizerCrashService
    private var operations: [UUID: (request: URL?, task: Task<Void, Never>)] = [:]

    init(installation: NativeXcodeInstallation) {
        self.installation = installation
        service = NativeOrganizerCrashService(installation: installation)
    }

    func execute(_ kind: Kind, input: Data, context: NativeToolContext) throws -> AsyncStream<Data> {
        let parameters: NativeCrashRequest
        do { parameters = try JSONDecoder().decode(NativeCrashRequest.self, from: input) }
        catch let error as DecodingError { throw NativeRuntimeError.invalidRequest(String(describing: error)) }
        if kind == .logs {
            guard let id = parameters.issueID, !id.isEmpty else {
                throw NativeRuntimeError.invalidRequest("GetCrashIssue requires issue_id from ListCrashIssues")
            }
            guard parameters.isBeta == nil else {
                throw NativeRuntimeError.invalidRequest("GetCrashIssue cannot filter sample logs by is_beta; the native service does not support that filter")
            }
            guard parameters.appVersion == nil else {
                throw NativeRuntimeError.invalidRequest("GetCrashIssue returns Organizer's samples and distributions for all app versions; use app_version on ListCrashIssues")
            }
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
                let resolved: NativeCrashContext
                switch try await resolve(parameters) {
                case .resolved(let value): resolved = value
                case .selectionRequired(let identifiers):
                    throw NativeRuntimeError.invalidRequest("Specify bundle_id. Available apps: " + identifiers.joined(separator: ", "))
                case .platformSelectionRequired(_, let platforms):
                    throw NativeRuntimeError.invalidRequest("Specify platform. Available platforms: " + platforms.joined(separator: ", "))
                }
                let query = try serviceQuery(parameters, context: resolved)
                let key = query.json(issueID: kind == .logs ? parameters.issueID : nil)
                let store = NativeCrashStore(root: context.artifactsRoot.appendingPathComponent("CrashAnalytics", isDirectory: true))
                let loaded = try await NativeCrashData.load(key: key, source: parameters.source, store: store) { [service] in
                    if kind == .topIssues { return try await service.fetchPage(query, store: store) }
                    return try await service.fetchIssue(query, issueID: parameters.issueID!)
                }
                try Task.checkCancellation()
                var payload: [String: JSONValue]
                do {
                    payload = try response(kind, query: query, loaded: loaded, issueID: parameters.issueID,
                                           directory: context.artifactsDirectory)
                } catch {
                    payload = ["status": .string("failed"), "query": key, "provenance": loaded.provenance,
                        "errors": .array(loaded.errors + [NativeCrashData.diagnostic(error, operation: "normalize")])]
                }
                let path = context.artifactsDirectory.appendingPathComponent("crash-response.json")
                payload["responsePath"] = .string(path.path)
                do { try NativeCrashStore.encode(.object(payload)).write(to: path, options: .atomic) }
                catch {
                    var errors = loaded.errors
                    if case .array(let existing) = payload["errors"] { errors = existing }
                    errors.append(NativeCrashData.diagnostic(error, operation: "responseWrite"))
                    payload["errors"] = .array(errors)
                    payload["status"] = .string(loaded.value == nil ? "failed" : "partial")
                    payload.removeValue(forKey: "responsePath")
                }
                let failed = payload["status"] == .string("failed")
                result.continuation.yield(try event(failed ? "error" : "completed", data: .object(payload)))
            } catch is CancellationError {
                return
            } catch {
                result.continuation.yield(errorEvent(error, input: parameters))
            }
        }
        operations[identifier] = (context.artifactsDirectory, task)
        result.continuation.onTermination = { _ in task.cancel() }
        return result.stream
    }

    func cancelPendingOperations() {
        for operation in Array(operations.values) { operation.task.cancel() }
    }

    func shutdown() async {
        let pending = operations.values.map(\.task)
        for operation in pending { operation.cancel() }
        for operation in pending { await operation.value }
    }

    func finishExecution(request: URL) async {
        let pending = operations.values.filter { $0.request == request }.map(\.task)
        if Task.isCancelled { for task in pending { task.cancel() } }
        for task in pending { await task.value }
    }

    private func serviceQuery(_ input: NativeCrashRequest, context: NativeCrashContext) throws -> NativeCrashServiceQuery {
        let getter = try runtime.object(productManager()).resolveAndWait(.objc(.method("products", as: (() -> NSArray).self)))
        let uploadPlatform = try input.uploadPlatform.map { try platform(description: $0) } ?? context.platform
        let uploadFamily = try platformFamilyIdentifier(uploadPlatform)
        let platformID = try runtime.object(context.platform).resolveAndWait(.objc(.method("identifier", as: (() -> String).self)))
        let uploadID = try runtime.object(uploadPlatform).resolveAndWait(.objc(.method("identifier", as: (() -> String).self)))
        let executionIdentifier = try unsafe platformID.unsafeInvoke()
        let uploadIdentifier = try unsafe uploadID.unsafeInvoke()
        let products = try unsafe getter.unsafeInvoke()
        for value in products {
            let product = value as AnyObject
            guard let identifier = try object(product, selector: "identifier"),
                  let category = try object(identifier, selector: "productCategory"),
                  let platform = try object(category, selector: "platform") else { continue }
            let bundle = try runtime.object(identifier).resolveAndWait(.objc(.method("bundleIdentifier", as: (() -> String?).self)))
            guard try unsafe bundle.unsafeInvoke() == context.bundleIdentifier,
                  try platformFamilyIdentifier(platform) == uploadFamily,
                  let adam = try object(product, selector: "adamId") else { continue }
            return NativeCrashServiceQuery(adamIdentifier: String(describing: adam), bundleIdentifier: context.bundleIdentifier,
                platformIdentifier: executionIdentifier, uploadPlatformIdentifier: uploadIdentifier,
                appVersion: input.appVersion, isBeta: input.isBeta, timePeriod: input.timePeriod,
                pageIndex: input.pageIndex, pageSize: input.pageSize)
        }
        throw NativeRuntimeError.unavailable("No App Store product matches \(context.bundleIdentifier) on upload platform \(uploadIdentifier)")
    }

    private func response(_ kind: Kind, query: NativeCrashServiceQuery, loaded: NativeCrashData.Loaded,
                          issueID: String?, directory: URL) throws -> [String: JSONValue] {
        var errors = loaded.errors
        var result: [String: JSONValue] = ["query": query.json(issueID: kind == .logs ? issueID : nil),
            "provenance": loaded.provenance]
        if case .object(var native)? = loaded.value {
            if kind == .topIssues {
                guard case .array(let points) = native["points"] else {
                    throw NativeRuntimeError.unsupportedContract("Native crash list has no points array")
                }
                result["issues"] = .array(try points.map(NativeCrashData.issue))
                var metadata = native
                metadata.removeValue(forKey: "points")
                result["native"] = .object(metadata)
                let needsProbe = !points.isEmpty
                result["pagination"] = .object(["page": .number(.int(Int64(query.pageIndex))),
                    "pageSize": .number(.int(Int64(query.pageSize))), "returnedCount": .number(.int(Int64(points.count))),
                    "hasMore": needsProbe ? .null : .bool(false),
                    "nextPage": needsProbe ? .number(.int(Int64(query.pageIndex + 1))) : .null,
                    "continuationRequiresProbe": .bool(needsProbe)])
            } else {
                result["issueId"] = issueID.map(JSONValue.string) ?? .null
                do {
                    guard let distribution = native["distribution"] else {
                        throw NativeRuntimeError.unavailable("Organizer did not provide crash device distributions")
                    }
                    result["timeSeries"] = try NativeCrashData.timeSeries(distribution, timePeriod: query.timePeriod)
                }
                catch { errors.append(NativeCrashData.diagnostic(error, operation: "timeSeries")) }
                let saved = NativeCrashData.saveLogs(native, directory: directory)
                errors += saved.errors
                let logs = saved.logs
                native.removeValue(forKey: "logs")
                result["logs"] = .array(logs)
                result["sampleLogCount"] = .number(.int(Int64(logs.count)))
                result["native"] = .object(native)
                result["logFilters"] = .object(["appVersion": query.appVersion.map(JSONValue.string) ?? .null,
                    "isBeta": .null, "limitation": .string("Organizer's saved samples and distributions cover all app versions and release channels. Saved samples can include previously downloaded logs; their count is not the number of crashes or devices.")])
            }
        } else if kind == .topIssues {
            result["issues"] = .array([])
            result["pagination"] = .object(["page": .number(.int(Int64(query.pageIndex))),
                "pageSize": .number(.int(Int64(query.pageSize))), "returnedCount": .number(.int(0)),
                "hasMore": .null, "nextPage": .number(.int(Int64(query.pageIndex))), "continuationRequiresProbe": .bool(false)])
        }
        result["errors"] = .array(errors)
        result["status"] = .string(loaded.value == nil ? "failed" : errors.isEmpty ? "complete" : "partial")
        return result
    }

    private func resolve(_ input: NativeCrashRequest) async throws -> NativeCrashResolution {
        try await waitForProductInventory()
        let workspace = try await workspace(identifier: input.workspaceIdentifier)
        let bundle: String
        if let explicit = input.bundleIdentifier {
            bundle = explicit.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            if let identifier = try bundleFromActiveScheme(workspace) {
                bundle = identifier
            } else {
                let identifiers = try availableBundleIdentifiers()
                guard identifiers.count == 1, let only = identifiers.first else {
                    return .selectionRequired(identifiers)
                }
                bundle = only
            }
        }
        guard !bundle.isEmpty else { throw NativeRuntimeError.invalidRequest("The bundle identifier is empty") }
        let platform: AnyObject
        if let name = input.platform {
            platform = try self.platform(description: name)
        } else {
            let choices = try productPlatforms(bundleIdentifier: bundle)
            if choices.count == 1, let only = choices.first {
                platform = only
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
                platform = try unsafe self.platform(description: description.unsafeInvoke())
            }
        }
        return .resolved(NativeCrashContext(bundleIdentifier: bundle, platform: platform))
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

    private func platform(description: String) throws -> AnyObject {
        guard let type = NSClassFromString("DVTPlatform") else {
            throw NativeRuntimeError.unsupportedContract("Xcode's platform registry is unavailable")
        }
        let getter = try runtime.object(type as AnyObject).resolveAndWait(.objc(.method("platformForUserDescription:", as: ((String) -> AnyObject?).self)))
        guard let value = try unsafe getter.unsafeInvoke(description) else {
            throw NativeRuntimeError.invalidRequest("Unknown platform '\(description)'")
        }
        return value
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

    private func errorEvent(_ error: any Error, input: NativeCrashRequest) -> Data {
        do {
            return try event("error", data: .object(["status": .string("failed"),
                "query": .object(["bundleId": input.bundleIdentifier.map(JSONValue.string) ?? .null,
                    "platform": input.platform.map(JSONValue.string) ?? .null,
                    "uploadPlatform": input.uploadPlatform.map(JSONValue.string) ?? .null,
                    "appVersion": input.appVersion.map(JSONValue.string) ?? .null,
                    "isBeta": input.isBeta.map(JSONValue.bool) ?? .null,
                    "issueId": input.issueID.map(JSONValue.string) ?? .null,
                    "page": .number(.int(Int64(input.pageIndex))), "pageSize": .number(.int(Int64(input.pageSize))),
                    "timePeriod": .string(input.timePeriod)]),
                "provenance": NativeCrashData.Loaded().provenance,
                "errors": .array([NativeCrashData.diagnostic(error, operation: "crashAnalytics")])]))
        }
        catch let encodingError {
            try? FileHandle.standardError.write(contentsOf: Data("Native analytics failed: \(error); error encoding also failed: \(encodingError)\n".utf8))
            return Data(#"{"type":"error","data":"Could not encode the native analytics failure; see host diagnostics"}"#.utf8)
        }
    }
}

@MainActor
private struct NativeCrashContext {
    let bundleIdentifier: String
    let platform: AnyObject
}

@MainActor
private enum NativeCrashResolution {
    case resolved(NativeCrashContext)
    case selectionRequired([String])
    case platformSelectionRequired(bundleIdentifier: String, platforms: [String])
}

extension NativeCrashServiceQuery {
    func json(issueID: String?) -> JSONValue {
        var value: [String: JSONValue] = ["adamId": .string(adamIdentifier), "bundleId": .string(bundleIdentifier),
            "platform": .string(platformIdentifier), "uploadPlatform": .string(uploadPlatformIdentifier),
            "appVersion": appVersion.map(JSONValue.string) ?? .null, "isBeta": isBeta.map(JSONValue.bool) ?? .null,
            "timePeriod": .string(timePeriod)]
        if let issueID { value["issueId"] = .string(issueID) }
        else {
            value["page"] = .number(.int(Int64(pageIndex)))
            value["pageSize"] = .number(.int(Int64(pageSize)))
        }
        return .object(value)
    }
}
