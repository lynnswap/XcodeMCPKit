import ABIBridge
import Foundation
import XcodeMCPWire

@safe
@MainActor
final class NativeCrashToolCorrection {
    enum Kind {
        case topIssues
        case logs

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
    private var topMethod: NativeSwiftAsyncMethod<NativeAnalyticsDictionary, String, AnyObject, NativeAnalyticsBoolean, String?, NativeAnalyticsInteger>?
    private var logsMethod: NativeSwiftAsyncMethod<NativeAnalyticsDictionary, String, String, AnyObject, NativeAnalyticsBoolean, String?>?
    private var operations: [UUID: Task<Void, Never>] = [:]

    init(installation: NativeXcodeInstallation) {
        self.installation = installation
    }

    // Remove this correction when OrganizerMCPLogDownloader selects a product
    // by bundle identifier and platform before its App Store-ID fast path.
    // The catalog and schemas still come from the installed native actions.
    func execute(_ kind: Kind, inputType: Any.Type, input: Data) throws -> AsyncStream<Data> {
        guard let type = inputType as? any Decodable.Type else {
            throw NativeRuntimeError.unsupportedContract("Native crash action input has no Decodable contract")
        }
        let parameters: NativeCrashInput
        do { parameters = try decode(type, from: input, kind: kind) }
        catch let error as DecodingError { throw NativeRuntimeError.invalidRequest(String(describing: error)) }
        if let count = parameters.count, count < 0 {
            // The native downloader passes count to Collection.prefix(_:).
            throw NativeRuntimeError.invalidRequest("count must be nonnegative")
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
                result.continuation.yield(try event("update", data: .object([
                    "message": .string("Validating input parameters..."), "progress": .number(.int(10)), "total": .number(.int(100)),
                ])))
                let context: NativeCrashContext
                switch try await resolve(parameters) {
                case .resolved(let resolved): context = resolved
                case .selectionRequired(let identifiers):
                    result.continuation.yield(try event("completed", data: bundleSelection(kind, input: parameters, identifiers: identifiers)))
                    return
                case .platformSelectionRequired(let bundleIdentifier, let platforms):
                    result.continuation.yield(try event("completed", data: platformSelection(kind, input: parameters,
                        bundleIdentifier: bundleIdentifier, platforms: platforms)))
                    return
                }
                try Task.checkCancellation()
                result.continuation.yield(try event("update", data: .object([
                    "message": .string(kind == .topIssues ? "Fetching top crash issues..." : "Fetching crash logs for \(parameters.signatureName)..."),
                    "progress": .number(.int(30)), "total": .number(.int(100)),
                ])))
                do {
                    let data = try await fetch(kind, input: parameters, context: context)
                    try Task.checkCancellation()
                    result.continuation.yield(try event("update", data: .object([
                        "message": .string(kind == .topIssues ? "Top crash issues retrieved successfully" : "Crash logs analysis completed successfully"),
                        "progress": .number(.int(100)), "total": .number(.int(100)),
                    ])))
                    result.continuation.yield(try event("completed", data: output(kind, input: parameters, context: context,
                        success: true, data: data, message: kind == .topIssues ? "Top crash issues retrieved successfully" : "Crash issue logs retrieved successfully")))
                } catch let error as NativeSwiftError {
                    try Task.checkCancellation()
                    result.continuation.yield(try event("completed", data: output(kind, input: parameters, context: context,
                        success: false, data: "", message: (kind == .topIssues ? "Failed to get top crash issues: " : "Failed to get crash logs: ") + error.localizedDescription)))
                }
            } catch is CancellationError {
                return
            } catch {
                result.continuation.yield(errorEvent(error))
            }
        }
        operations[identifier] = task
        result.continuation.onTermination = { _ in task.cancel() }
        return result.stream
    }

    func shutdown() async {
        let pending = Array(operations.values)
        for operation in pending { operation.cancel() }
        for operation in pending { await operation.value }
    }

    private func fetch(_ kind: Kind, input: NativeCrashInput, context: NativeCrashContext) async throws -> String {
        try NativeAnalyticsProductManager.establishNativeProtocol()
        let manager = try productManager()
        let view = NativeAnalyticsProductManager(manager: manager, bundleIdentifier: context.bundleIdentifier,
            familyIdentifier: try NativeAnalyticsProductManager.platformFamilyIdentifier(context.platform))
        let type = try await runtime.swiftType(named: "IDEAnalytics.OrganizerMCPLogDownloader",
            in: .path(installation.framework("IDEAnalytics", in: "PlugIns")))
        let initialize = try await type.initializer(
            named: "init(productManager: __C.DVTProductManagerProtocol) -> IDEAnalytics.OrganizerMCPLogDownloader", as: ((AnyObject) -> AnyObject).self)
        let downloader = try unsafe initialize.unsafeInvoke(view)
        let value: [String: Any]
        do {
            switch kind {
            case .topIssues:
                let prepared: NativeSwiftAsyncMethod<NativeAnalyticsDictionary, String, AnyObject, NativeAnalyticsBoolean, String?, NativeAnalyticsInteger>
                if let topMethod { prepared = topMethod } else {
                    let bound = try await runtime.object(downloader).method(
                        named: "getTopCrashPoints(bundleId: Swift.String, platform: __C.DVTPlatform, isBeta: Swift.Optional<Swift.Bool>, appVersion: Swift.Optional<Swift.String>, count: Swift.Optional<Swift.Int>) async throws -> Swift.Dictionary<Swift.String, Any>",
                        as: (@concurrent (String, AnyObject, NativeAnalyticsBoolean, String?, NativeAnalyticsInteger) async throws -> NativeAnalyticsDictionary).self)
                    prepared = bound.method
                    topMethod = prepared
                }
                let method = try prepared.bind(to: downloader)
                value = try unsafe await method.unsafeInvoke(context.bundleIdentifier, context.platform,
                    NativeAnalyticsBoolean(value: input.isBeta), input.appVersion, NativeAnalyticsInteger(value: input.count ?? 5)).value
            case .logs:
                let prepared: NativeSwiftAsyncMethod<NativeAnalyticsDictionary, String, String, AnyObject, NativeAnalyticsBoolean, String?>
                if let logsMethod { prepared = logsMethod } else {
                    let bound = try await runtime.object(downloader).method(
                        named: "getCrashLogs(bundleId: Swift.String, signatureName: Swift.String, platform: __C.DVTPlatform, isBeta: Swift.Optional<Swift.Bool>, appVersion: Swift.Optional<Swift.String>) async throws -> Swift.Dictionary<Swift.String, Any>",
                        as: (@concurrent (String, String, AnyObject, NativeAnalyticsBoolean, String?) async throws -> NativeAnalyticsDictionary).self)
                    prepared = bound.method
                    logsMethod = prepared
                }
                let method = try prepared.bind(to: downloader)
                value = try unsafe await method.unsafeInvoke(context.bundleIdentifier, input.signatureName, context.platform,
                    NativeAnalyticsBoolean(value: input.isBeta), input.appVersion).value
            }
        } catch {
            try view.checkFailure()
            throw error
        }
        try view.checkFailure()
        switch kind {
        case .topIssues:
            guard value["signatures"] is [String: Any] else { throw NativeRuntimeError.unsupportedContract("Native crash list has no signatures dictionary") }
        case .logs:
            guard value["crashLogs"] is [String], value["signatureName"] is String else {
                throw NativeRuntimeError.unsupportedContract("Native crash detail has no crashLogs or signatureName")
            }
        }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: value, options: .prettyPrinted), as: UTF8.self)
        guard kind == .logs else { return json }
        let reportType = try await runtime.swiftType(named: "DVTAnalytics.AnalyticsReportType",
            in: .path(installation.framework("DVTAnalytics", in: "SharedFrameworks")))
        let crashType = try await reportType.staticGetter(named: "crashPoint.getter : DVTAnalytics.AnalyticsReportType", as: AnyObject.self)
        let provider = try await runtime.swiftType(named: "IDEAnalytics.TriageKnowledgeProvider",
            in: .path(installation.framework("IDEAnalytics", in: "PlugIns")))
        let format = try await provider.staticMethod(
            named: "formatWithTriageKnowledge(diagnosticData: Swift.String, reportType: DVTAnalytics.AnalyticsReportType) throws -> Swift.String",
            as: ((String, AnyObject) throws -> String).self)
        return try unsafe format.unsafeInvoke(json, crashType.unsafeInvoke())
    }

    private func resolve(_ input: NativeCrashInput) async throws -> NativeCrashResolution {
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
                            let getter = try runtime.object(family).method(selector: "displayName", as: (() -> String).self)
                            return try unsafe getter.unsafeInvoke()
                        }
                        return .platformSelectionRequired(bundleIdentifier: bundle, platforms: Array(Set(names)).sorted())
                    }
                    throw NativeRuntimeError.invalidRequest("Could not resolve the platform from the active run destination")
                }
                let description = try runtime.object(family).method(selector: "displayName", as: (() -> String).self)
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
        let getter = try runtime.object(actionClass as AnyObject).method(selector: "bundleIdentifierFromBuildableProduct:withBuildParameters:",
            as: ((AnyObject, AnyObject?) -> String?).self)
        return try unsafe getter.unsafeInvoke(product, nil)
    }

    private func availableBundleIdentifiers() throws -> [String] {
        let getter = try runtime.object(productManager()).method(selector: "products", as: (() -> NSArray).self)
        let products = try unsafe getter.unsafeInvoke()
        var identifiers = Set<String>()
        for product in products {
            let appStoreID = try runtime.object(product as AnyObject).method(selector: "adamId", as: (() -> AnyObject?).self)
            guard try unsafe appStoreID.unsafeInvoke() != nil,
                  let identifier = try object(product as AnyObject, selector: "identifier") else { continue }
            let bundle = try runtime.object(identifier).method(selector: "bundleIdentifier", as: (() -> String?).self)
            if let value = try unsafe bundle.unsafeInvoke() { identifiers.insert(value) }
        }
        return identifiers.sorted()
    }

    private func productManager() throws -> AnyObject {
        guard let type = NSClassFromString("IDEProductManager") else {
            throw NativeRuntimeError.unsupportedContract("Xcode's product manager is unavailable")
        }
        let getter = try runtime.object(type as AnyObject).method(selector: "defaultManager", as: (() -> AnyObject).self)
        return try unsafe getter.unsafeInvoke()
    }

    private func waitForProductInventory() async throws {
        let manager = try productManager()
        let started = try runtime.object(manager).method(selector: "hasStartedLocating", as: (() -> Bool).self)
        if try unsafe !started.unsafeInvoke() {
            let load = try runtime.object(manager).method(selector: "load", as: (() -> Void).self)
            try unsafe load.unsafeInvoke()
        }
        let completed = try runtime.object(manager).method(selector: "hasCompletedInitialLoading", as: (() -> Bool).self)
        while try unsafe !completed.unsafeInvoke() {
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func platform(description: String) throws -> AnyObject {
        guard let type = NSClassFromString("DVTPlatform") else {
            throw NativeRuntimeError.unsupportedContract("Xcode's platform registry is unavailable")
        }
        let getter = try runtime.object(type as AnyObject).method(selector: "platformForUserDescription:", as: ((String) -> AnyObject?).self)
        guard let value = try unsafe getter.unsafeInvoke(description) else {
            throw NativeRuntimeError.invalidRequest("Unknown platform '\(description)'")
        }
        return value
    }

    private func productPlatforms(bundleIdentifier: String) throws -> [AnyObject] {
        let getter = try runtime.object(productManager()).method(selector: "products", as: (() -> NSArray).self)
        let products = try unsafe getter.unsafeInvoke()
        var platforms: [String: AnyObject] = [:]
        for product in products {
            guard let identifier = try object(product as AnyObject, selector: "identifier") else { continue }
            let bundle = try runtime.object(identifier).method(selector: "bundleIdentifier", as: (() -> String?).self)
            guard try unsafe bundle.unsafeInvoke() == bundleIdentifier,
                  let category = try object(identifier, selector: "productCategory"),
                  let platform = try object(category, selector: "platform") else { continue }
            let key = try NativeAnalyticsProductManager.platformFamilyIdentifier(platform)
            if platforms[key] == nil { platforms[key] = platform }
        }
        return Array(platforms.values)
    }

    private func workspace(identifier: String?) async throws -> AnyObject? {
        guard let identifier else { return nil }
        let type = try await runtime.swiftType(named: "IDEFoundation.IDEWorkspaceRegistry", in: .path(installation.framework("IDEFoundation")))
        let shared = try await type.staticGetter(named: "shared.getter : IDEFoundation.IDEWorkspaceRegistry", as: AnyObject.self)
        let registry = try unsafe shared.unsafeInvoke()
        let lookup = try await runtime.object(registry).method(named: "workspace(withIdentifier: Swift.String) -> Swift.Optional<__C.IDEWorkspace>", as: ((String) -> AnyObject?).self)
        return try unsafe lookup.unsafeInvoke(identifier)
    }

    private func object(_ receiver: AnyObject, selector: String) throws -> AnyObject? {
        let getter = try runtime.object(receiver).method(selector: selector, as: (() -> AnyObject?).self)
        return try unsafe getter.unsafeInvoke()
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data, kind: Kind) throws -> NativeCrashInput {
        let value = try JSONDecoder().decode(type, from: data)
        var fields: [String: Any] = [:]
        for child in Mirror(reflecting: value).children {
            if let label = child.label { fields[label] = child.value }
        }
        func optional<Value>(_ name: String, as type: Value.Type) throws -> Value? {
            guard let field = fields[name], let value = field as? Value? else {
                throw NativeRuntimeError.unsupportedContract("Native crash input has no compatible '\(name)' field")
            }
            return value
        }
        let signature: String
        if kind == .logs {
            guard let value = fields["signatureName"] as? String else { throw NativeRuntimeError.unsupportedContract("Native crash input has no signatureName") }
            signature = value
        } else { signature = "" }
        return NativeCrashInput(workspaceIdentifier: try optional("workspaceIdentifier", as: String.self),
            bundleIdentifier: try optional("bundleId", as: String.self), platform: try optional("platform", as: String.self),
            appVersion: try optional("appVersion", as: String.self), isBeta: try optional("isBeta", as: Bool.self),
            count: kind == .topIssues ? try optional("count", as: Int.self) : nil, signatureName: signature)
    }

    private func output(_ kind: Kind, input: NativeCrashInput, context: NativeCrashContext, success: Bool, data: String, message: String) -> JSONValue {
        var value: [String: JSONValue] = ["success": .bool(success), "data": .string(data), "message": .string(message), "bundleId": .string(context.bundleIdentifier)]
        if let version = input.appVersion { value["appVersion"] = .string(version) }
        if kind == .logs { value["signatureName"] = .string(input.signatureName) }
        return .object(value)
    }

    private func bundleSelection(_ kind: Kind, input: NativeCrashInput, identifiers: [String]) -> JSONValue {
        let data: String
        let message: String
        if identifiers.isEmpty {
            data = "Could not automatically determine the app's bundle identifier. No App Store apps are available; provide the 'bundle_id' parameter."
            message = "BUNDLE ID REQUIRED: Provide the bundle identifier of the app to analyze."
        } else {
            data = "Could not automatically determine the app's bundle identifier.\n\nAvailable apps:\n"
                + identifiers.map { "  - " + $0 }.joined(separator: "\n")
                + "\n\nPlease ask the user which app they want to analyze, then call this tool again with the 'bundle_id' parameter set to their chosen app."
            message = "BUNDLE ID SELECTION REQUIRED: Multiple apps are available. Please present the list above to the user and ask them to choose which app to analyze. Do not automatically select an app."
        }
        var result: [String: JSONValue] = ["success": .bool(false), "bundleId": .string(""), "data": .string(data),
            "message": .string(message)]
        if let version = input.appVersion { result["appVersion"] = .string(version) }
        if kind == .logs { result["signatureName"] = .string(input.signatureName) }
        return .object(result)
    }

    private func platformSelection(_ kind: Kind, input: NativeCrashInput,
                                   bundleIdentifier: String, platforms: [String]) -> JSONValue {
        var result: [String: JSONValue] = [
            "success": .bool(false), "bundleId": .string(bundleIdentifier),
            "data": .string("Multiple platforms are available for \(bundleIdentifier):\n\n"
                + platforms.map { "  - " + $0 }.joined(separator: "\n")
                + "\n\nPlease ask which platform they want data for, then call this tool again with the 'platform' parameter."),
            "message": .string("PLATFORM SELECTION REQUIRED: Multiple platforms are available. Please present the list above and ask which platform to analyze."),
        ]
        if let version = input.appVersion { result["appVersion"] = .string(version) }
        if kind == .logs { result["signatureName"] = .string(input.signatureName) }
        return .object(result)
    }

    private func event(_ type: String, data: JSONValue) throws -> Data {
        try JSONRPC.Wire.data(from: ["type": type, "data": data.foundationObject])
    }

    private func errorEvent(_ error: any Error) -> Data {
        do { return try event("error", data: .string(String(describing: error))) }
        catch let encodingError {
            FileHandle.standardError.write(Data("Native analytics failed: \(error); error encoding also failed: \(encodingError)\n".utf8))
            return Data(#"{"type":"error","data":"Could not encode the native analytics failure; see host diagnostics"}"#.utf8)
        }
    }
}

private struct NativeCrashInput: Sendable {
    let workspaceIdentifier: String?
    let bundleIdentifier: String?
    let platform: String?
    let appVersion: String?
    let isBeta: Bool?
    let count: Int?
    let signatureName: String
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
