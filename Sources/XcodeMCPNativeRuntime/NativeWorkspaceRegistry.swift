import ABIBridge
import Foundation
import XcodeMCPNativeSwiftABI

@MainActor
final class NativeWorkspaceRegistry {
    private let runtime = ABIRuntime.shared
    private let registry: AnyObject
    private let listEntries: NativeBoundSwiftMethod<() -> NativeSwiftValue>
    private let setChangeHandler: NativeBoundSwiftMethod<(NativeSwiftValue) -> Void>
    private let previousChangeHandler: NativeSwiftValue
    private let callPreviousChangeHandler: NativeSwiftClosure<@MainActor () -> Void>?
    private let identifyWorkspace: NativeBoundSwiftMethod<(AnyObject) -> String>
    private var documents: [String: NativeWorkspaceDocument] = [:]
    private var openingDocuments: [String: OpeningDocument] = [:]
    private var openingRequests: [URL: OpeningDocument] = [:]

    private final class OpeningDocument {
        let path: String
        var requests: Set<URL> = []
        var identifier: String?
        var document: NativeWorkspaceDocument?

        init(path: String) { self.path = path }
    }

    init(installation: NativeXcodeInstallation) async throws {
        let type = try await runtime.resolveSwiftType(named: "IDEFoundation.IDEWorkspaceRegistry", in: .path(installation.framework("IDEFoundation")), loading: .loadedOnly)
        let shared = try await type.resolveStaticGetter(named: "shared.getter : IDEFoundation.IDEWorkspaceRegistry", as: (() -> AnyObject).self)
        registry = try unsafe shared.unsafeInvoke()
        identifyWorkspace = try await runtime.object(registry).resolveMethod(
            named: "identifier(for: __C.IDEWorkspace) -> Swift.String", as: ((AnyObject) -> String).self)
        listEntries = try await runtime.object(registry).resolveMethod(
            named: "list() -> Swift.Array<IDEFoundation.IDEWorkspaceRegistry.WorkspaceInfo>", as: (() -> NativeSwiftValue).self)
        let callbackType = try await runtime.resolveSwiftType(named: "Swift.Optional", genericArguments: [.type(WorkspaceCallback.self)])
        // Both the selected Xcode's accessors and a compiler-emitted Optional
        // callback use direct function/context words. Value witnesses own copies.
        let callbackABI = try NativeType.structure(named: callbackType.name, fields: [.pointer, .pointer])
        let valueABIs = [callbackType: callbackABI]
        let getChangeHandler = try await type.resolveGetter(
            named: "onChange.getter : Swift.Optional<@Swift.MainActor () -> ()>", as: (() -> NativeSwiftValue).self,
            valueABIs: valueABIs).bind(to: registry)
        setChangeHandler = try await type.resolveSetter(
            named: "onChange.setter : Swift.Optional<@Swift.MainActor () -> ()>", as: NativeSwiftValue.self,
            valueABIs: valueABIs).bind(to: registry)
        previousChangeHandler = try unsafe getChangeHandler.unsafeInvoke()
        let previous = try await previousChangeHandler.resolveEnumPayload(forCase: "some")
        callPreviousChangeHandler = try await previous?.resolveClosure(as: (@MainActor () -> Void).self)
        let onChange = optionalWorkspaceCallback { [weak self] in
            guard let self else { return }
            do {
                try unsafe self.callPreviousChangeHandler?.unsafeInvoke()
                try self.closeUnregisteredDocuments()
            }
            catch { NativeErrorPresentation.report(error as NSError) }
        }
        let ownCallback = try await runtime.resolveSwiftFunction(
            named: "XcodeMCPNativeRuntime.nativePreviewValue<A>(A) -> A",
            as: ((WorkspaceCallback?) -> NativeSwiftValue).self,
            genericArguments: [.type(WorkspaceCallback?.self)], valueABIs: valueABIs)
        let callback = try unsafe ownCallback.unsafeInvoke(onChange)
        try unsafe setChangeHandler.unsafeInvoke(callback)
    }

    func prepareOpen(path: String, request: URL) async throws {
        let path = URL(filePath: path).standardizedFileURL.resolvingSymlinksInPath().path
        let opening = openingDocuments[path] ?? OpeningDocument(path: path)
        openingDocuments[path] = opening
        opening.requests.insert(request)
        openingRequests[request] = opening
        let loaded = try await NativeWorkspaceDocument.load(at: URL(filePath: path))
        if !loaded.wasAlreadyOpen {
            do { opening.document = try NativeWorkspaceDocument(document: loaded.document) }
            catch {
                loaded.document.close()
                throw error
            }
        }
        opening.identifier = try unsafe identifyWorkspace.unsafeInvoke(loaded.workspace)
        try opening.document?.checkFailure()
        // AppKit may finish loading after cancellation. Acquire its document
        // before propagating cancellation so request cleanup can close it.
        try Task.checkCancellation()
    }

    func finishOpen(request: URL) throws {
        guard let opening = openingRequests.removeValue(forKey: request) else { return }
        opening.requests.remove(request)
        defer {
            if opening.requests.isEmpty, opening.document == nil {
                openingDocuments.removeValue(forKey: opening.path)
            }
        }
        if let identifier = opening.identifier, let document = opening.document,
           try entries().contains(where: { $0.identifier == identifier }) {
            documents[identifier] = document
            opening.document = nil
            try document.checkFailure()
        }
        guard opening.requests.isEmpty else { return }
        if let document = opening.document {
            try document.close()
            opening.document = nil
        }
    }

    func resolve(_ selector: String, opensIfMissing: Bool = true, request: URL) async throws -> String {
        if selector.hasPrefix("/") {
            let path = URL(fileURLWithPath: selector).standardizedFileURL.resolvingSymlinksInPath().path
            let matches = try entries().filter { entry in
                entry.path.map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path } == path
            }
            if let match = matches.first {
                guard matches.count == 1 else {
                    throw NativeRuntimeError.invalidRequest("Multiple native workspaces match '\(selector)'; select a workspaceIdentifier: " + matches.map(\.identifier).sorted().joined(separator: ", "))
                }
                if opensIfMissing { try await prepareDocument(for: match.identifier) }
                return match.identifier
            }
            guard opensIfMissing else {
                throw NativeRuntimeError.invalidRequest("No open native workspace matches '\(selector)'")
            }
            try await prepareOpen(path: path, request: request)
            let open = try await runtime.object(registry).resolveMethod(named: "open(path: Swift.String) async throws -> __C.IDEWorkspace", as: (@concurrent (String) async throws -> AnyObject).self)
            try Task.checkCancellation()
            let workspace: AnyObject
            do {
                workspace = try unsafe await open.unsafeInvoke(path)
            } catch let error as NativeSwiftError {
                if error.withUnderlyingError({ $0 is CancellationError }) { throw CancellationError() }
                throw NativeToolExecutionError(message: error.description)
            }
            let getter = try await runtime.object(workspace).resolveGetter(named: "workspaceIdentifier", as: (() -> String).self)
            let identifier = try unsafe getter.unsafeInvoke()
            try finishOpen(request: request)
            try prepareDocument(workspace: workspace, identifier: identifier)
            return identifier
        }
        if opensIfMissing { try await prepareDocument(for: selector) }
        return selector
    }

    func prepareDebugger(for identifier: String) async throws {
        guard let workspace = try await workspace(with: identifier) else { return }
        let manager = try runtime.object(workspace).resolveMethodAndWait(selector: "breakpointManager", as: (() -> AnyObject?).self)
        _ = try unsafe manager.unsafeInvoke()
    }

    private func closeDocument(for identifier: String) throws {
        guard let document = documents[identifier] else { return }
        try document.close()
        documents.removeValue(forKey: identifier)
    }

    private func workspace(with identifier: String) async throws -> AnyObject? {
        let lookup = try await runtime.object(registry).resolveMethod(named: "workspace(withIdentifier: Swift.String) -> Swift.Optional<__C.IDEWorkspace>", as: ((String) -> AnyObject?).self)
        try Task.checkCancellation()
        return try unsafe lookup.unsafeInvoke(identifier)
    }

    private func prepareDocument(for identifier: String) async throws {
        if let document = documents[identifier] {
            try document.checkFailure()
            return
        }
        if let workspace = try await workspace(with: identifier) {
            try prepareDocument(workspace: workspace, identifier: identifier)
        }
    }

    private func prepareDocument(workspace: AnyObject, identifier: String) throws {
        if let document = documents[identifier] {
            try document.checkFailure()
            return
        }
        documents[identifier] = try NativeWorkspaceDocument.open(workspace: workspace)
    }

    func closeRemovedWorkspaces() async throws {
        let close = try await runtime.object(registry).resolveMethod(
            named: "close(identifier: Swift.String) throws -> ()", as: ((String) throws -> Void).self
        )
        let snapshot = try entries()
        var failures: [String] = []
        do { try closeUnregisteredDocuments() }
        catch { failures.append(String(describing: error)) }
        for entry in snapshot {
            guard let path = entry.path else { continue }
            do {
                _ = try URL(filePath: path).resourceValues(forKeys: [.isDirectoryKey])
                continue
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                // The saved model has disappeared; close it through its owner.
            } catch {
                failures.append("Cannot inspect native workspace '\(path)': \(error)")
                continue
            }
            do {
                try unsafe close.unsafeInvoke(entry.identifier)
                try documents[entry.identifier]?.checkFailure()
            } catch {
                failures.append("Cannot close removed native workspace '\(path)': \(error)")
            }
        }
        if !failures.isEmpty {
            throw NativeRuntimeError.invocation(failures.joined(separator: "; "))
        }
    }

    // This registry belongs to the headless host process. Its native snapshot
    // also includes opens whose completion event a cancelled caller did not see.
    func closeAllWorkspaces() async throws {
        var failures: [String] = []
        do {
            let identifiers = Set(try entries().map(\.identifier))
            let close = try await runtime.object(registry).resolveMethod(named: "close(identifier: Swift.String) throws -> ()", as: ((String) throws -> Void).self)
            for identifier in identifiers.union(documents.keys).sorted() {
                do {
                    if identifiers.contains(identifier) {
                        try unsafe close.unsafeInvoke(identifier)
                        try documents[identifier]?.checkFailure()
                    } else {
                        try closeDocument(for: identifier)
                    }
                } catch {
                    failures.append("\(identifier): \(error)")
                }
            }
        } catch {
            failures.append(String(describing: error))
        }
        for (path, opening) in openingDocuments {
            do {
                try opening.document?.close()
                opening.document = nil
                openingDocuments.removeValue(forKey: path)
            } catch {
                failures.append("Cannot close pending workspace document '\(path)': \(error)")
            }
        }
        openingRequests.removeAll()
        do { try unsafe setChangeHandler.unsafeInvoke(previousChangeHandler.copy()) }
        catch { failures.append("Cannot restore native workspace change handler: \(error)") }
        if !failures.isEmpty {
            throw NativeRuntimeError.invocation("Failed to close native workspaces: " + failures.joined(separator: "; "))
        }
    }

    private func closeUnregisteredDocuments() throws {
        let registered = Set(try entries().map(\.identifier))
        var failures: [String] = []
        for identifier in documents.keys.sorted() where !registered.contains(identifier) {
            do { try closeDocument(for: identifier) }
            catch { failures.append("Cannot close workspace document '\(identifier)': \(error)") }
        }
        if !failures.isEmpty {
            throw NativeRuntimeError.invocation(failures.joined(separator: "; "))
        }
    }

    private func entries() throws -> [(identifier: String, path: String?)] {
        let snapshot = try unsafe listEntries.unsafeInvoke()
        return try snapshot.withCopy { value in
            guard let values = value as? [Any] else {
                throw NativeRuntimeError.unsupportedContract("Native workspace registry did not return an array")
            }
            return try values.map { value in
                let fields = Mirror(reflecting: value).children
                guard let identifier = fields.first(where: { $0.label == "identifier" })?.value as? String,
                      let pathField = fields.first(where: { $0.label == "path" }),
                      let path = pathField.value as? String? else {
                    throw NativeRuntimeError.unsupportedContract("Native workspace registry entry has no identifier or optional path")
                }
                return (identifier, path)
            }
        }
    }
}
