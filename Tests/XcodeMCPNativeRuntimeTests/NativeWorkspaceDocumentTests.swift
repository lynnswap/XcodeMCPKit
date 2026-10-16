import ABIBridge
import AppKit
import Foundation
import Testing
@testable import XcodeMCPNativeRuntime

@MainActor
struct NativeWorkspaceDocumentTests {
    @Test func aLoadedDocumentPreservesItsWorkspaceAndOwnership() throws {
        let document = LoadedWorkspaceDocumentFixture()

        let loaded = try NativeWorkspaceDocument.Loaded(document: document, wasAlreadyOpen: true)

        #expect(loaded.document === document)
        let expectedWorkspace = try #require(document.workspace)
        #expect(ObjectIdentifier(loaded.workspace) == ObjectIdentifier(expectedWorkspace))
        #expect(loaded.wasAlreadyOpen)
        #expect(!document.closed)
    }

    @Test(arguments: [false, true])
    func aDocumentWithoutAWorkspaceIsClosedOnlyWhenNew(wasAlreadyOpen: Bool) throws {
        let document = LoadedWorkspaceDocumentFixture()
        document.workspace = nil

        #expect(throws: NativeRuntimeError.self) {
            try NativeWorkspaceDocument.Loaded(document: document, wasAlreadyOpen: wasAlreadyOpen)
        }

        #expect(document.closed == !wasAlreadyOpen)
    }

    @Test func nativeChangesUpdateTheDocumentRestoreIdentityAcrossSelections() throws {
        let document = WorkspaceDocumentFixture()
        let owner = try NativeWorkspaceDocument(document: document)
        defer { try? owner.close() }

        for scheme in ["Watch", "Catalyst"] {
            try document.stateRepository.select(scheme)
            #expect(document.stateRepository.storedScheme == scheme)
        }
        #expect(document.stateRepository.collectionCount == 2)
    }

    @Test func closingDetachesTheRepositoryAndReleasesItsOwner() throws {
        let document = WorkspaceDocumentFixture()
        var owner: NativeWorkspaceDocument? = try NativeWorkspaceDocument(document: document)
        weak var observedOwner = owner

        try owner?.close()
        owner = nil

        #expect(document.closed)
        #expect(document.stateRepository.delegate == nil)
        #expect(observedOwner == nil)
        try document.stateRepository.select("After close")
        #expect(document.stateRepository.collectionCount == 0)
    }

    @Test(arguments: [true, false])
    func preservesAnExistingNativeStoreOrDelegate(store: Bool) throws {
        let original = NSObject()
        let workspace = WorkspaceOwnerFixture(store: store ? original : nil, delegate: store ? nil : original)

        #expect(try NativeWorkspaceDocument.open(workspace: workspace) == nil)
        #expect(store ? workspace.activeRunContextStore === original : workspace.workspaceDelegate === original)
    }
}

@MainActor
private final class LoadedWorkspaceDocumentFixture: NSDocument {
    @objc var workspace: AnyObject? = NSObject()
    private(set) var closed = false
    override func close() { closed = true }
}

private final class WorkspaceDocumentFixture: NSObject {
    @objc let stateRepository = WorkspaceStateRepositoryFixture()
    private(set) var closed = false
    @objc func close() {
        stateRepository.delegate = nil
        closed = true
    }
}

private final class WorkspaceStateRepositoryFixture: NSObject {
    @objc var delegate: AnyObject?
    private var selectedScheme = "Initial"
    private(set) var storedScheme: String?
    private(set) var collectionCount = 0

    func select(_ scheme: String) throws {
        selectedScheme = scheme
        guard let delegate else { return }
        let changed = try ABIRuntime.shared.object(delegate).resolveMethodAndWait(
            selector: "stateRepositoryDidChange:", as: ((AnyObject) -> Void).self)
        try unsafe changed.unsafeInvoke(self)
    }

    @objc func collectStateFromRegisteredObjects() {
        collectionCount += 1
        storedScheme = selectedScheme
    }
}

private final class WorkspaceOwnerFixture: NSObject {
    @objc let activeRunContextStore: AnyObject?
    @objc let workspaceDelegate: AnyObject?

    init(store: AnyObject?, delegate: AnyObject?) {
        activeRunContextStore = store
        workspaceDelegate = delegate
    }
}
