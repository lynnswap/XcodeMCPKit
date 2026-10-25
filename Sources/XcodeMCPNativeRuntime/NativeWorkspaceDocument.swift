import ABIBridge
import AppKit
import Foundation
import ObjectiveC

@safe
@MainActor
final class NativeWorkspaceDocument: NSObject {
    private let document: AnyObject
    private let collectState: NativeBoundObjCMethod<Void>
    private let closeDocument: NativeBoundObjCMethod<Void>
    private var failure: (any Error)?

    @MainActor
    struct Loaded {
        let document: NSDocument
        let workspace: AnyObject
        let wasAlreadyOpen: Bool

        init(document: NSDocument, wasAlreadyOpen: Bool) throws {
            self.document = document
            self.wasAlreadyOpen = wasAlreadyOpen
            do {
                let getter = try ABIRuntime.shared.object(document).resolveAndWait(.objc(.method("workspace", as: (() -> AnyObject?).self)))
                guard let workspace = try unsafe getter.unsafeInvoke() else {
                    throw NativeRuntimeError.invocation("The native document has no workspace")
                }
                self.workspace = workspace
            } catch {
                if !wasAlreadyOpen { document.close() }
                throw error
            }
        }
    }

    static func load(at url: URL) async throws -> Loaded {
        let document: NSDocument
        let wasAlreadyOpen: Bool
        do {
            (document, wasAlreadyOpen) = try await NSDocumentController.shared.openDocument(withContentsOf: url, display: false)
        } catch {
            if error is CancellationError { throw error }
            throw NativeToolExecutionError(message: error.localizedDescription)
        }
        return try Loaded(document: document, wasAlreadyOpen: wasAlreadyOpen)
    }

    init(document: AnyObject) throws {
        self.document = document
        let runtime = ABIRuntime.shared
        let getter = try runtime.object(document).resolveAndWait(.objc(.method("stateRepository", as: (() -> AnyObject).self)))
        let repository = try unsafe getter.unsafeInvoke()
        collectState = try runtime.object(repository).resolveAndWait(.objc(.method("collectStateFromRegisteredObjects", as: (() -> Void).self)))
        let setDelegate = try runtime.object(repository).resolveAndWait(.objc(.method("setDelegate:", as: ((AnyObject?) -> Void).self)))
        closeDocument = try runtime.object(document).resolveAndWait(.objc(.method("close", as: (() -> Void).self)))
        super.init()
        if let nativeProtocol = unsafe objc_getProtocol("DVTStateRepositoryDelegate") {
            _ = class_addProtocol(Self.self, nativeProtocol)
        }
        try unsafe setDelegate.unsafeInvoke(self)
    }

    static func open(workspace: AnyObject) throws -> NativeWorkspaceDocument? {
        let runtime = ABIRuntime.shared
        let storeGetter = try runtime.object(workspace).resolveAndWait(.objc(.method("activeRunContextStore", as: (() -> AnyObject?).self)))
        let delegateGetter = try runtime.object(workspace).resolveAndWait(.objc(.method("workspaceDelegate", as: (() -> AnyObject?).self)))
        guard try unsafe storeGetter.unsafeInvoke() == nil,
              try unsafe delegateGetter.unsafeInvoke() == nil else { return nil }
        guard let documentClass = NSClassFromString("IDEWorkspaceDocument"),
              let nativeProtocol = unsafe objc_getProtocol("DVTStateRepositoryDelegate") else {
            throw NativeRuntimeError.unsupportedContract("Xcode's workspace document or state-repository protocol is unavailable")
        }
        _ = class_addProtocol(Self.self, nativeProtocol)
        let allocate = try runtime.object(documentClass as AnyObject).resolveAndWait(.objc(.method("alloc", as: (() -> AnyObject).self)))
        let allocated = try unsafe allocate.unsafeInvoke()
        let initialize = try runtime.object(allocated).resolveAndWait(.objc(.method("initWithWorkspace:", as: ((AnyObject) -> AnyObject?).self)))
        guard let document = try unsafe initialize.unsafeInvoke(workspace) else {
            throw NativeRuntimeError.invocation("IDEWorkspaceDocument.initWithWorkspace: returned nil")
        }
        do {
            return try NativeWorkspaceDocument(document: document)
        } catch {
            let original = error
            do {
                let close = try runtime.object(document).resolveAndWait(.objc(.method("close", as: (() -> Void).self)))
                try unsafe close.unsafeInvoke()
            } catch {
                throw NativeRuntimeError.invocation("Cannot connect workspace state: \(original); document cleanup failed: \(error)")
            }
            throw original
        }
    }

    @objc(stateRepositoryDidChange:)
    func stateRepositoryDidChange(_ repository: AnyObject) {
        do {
            // Keep the document's canonical restore identities current without
            // the GUI delegate's delayed UserInterfaceState file save.
            try unsafe collectState.unsafeInvoke()
        } catch {
            if failure == nil { failure = error }
            NativeErrorPresentation.report(error as NSError)
        }
    }

    func checkFailure() throws {
        if let failure { throw failure }
    }

    func close() throws {
        do {
            // Native document invalidation detaches its state repository. Keep
            // its owner connected until that operation has completed.
            try unsafe closeDocument.unsafeInvoke()
        } catch {
            failure = error
            throw error
        }
    }
}
