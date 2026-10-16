import Foundation
import Testing
@testable import XcodeMCPNativeRuntime

@Suite
@MainActor
struct NativePreviewBuildTests {
    @Test func sourceSelectionsWaitForRestorationAndCancelQueuedOperations() async throws {
        let (builder, root) = try sourceSelectionBuilder()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = NSObject()
        let entered = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let attempted = AsyncStream<Void>.makeStream()
        var input = "original"
        var observed: [String] = []
        let first = Task { @MainActor in
            try await builder.withSourceSelection(workspace: workspace) {
                input = "first"
                entered.continuation.yield(())
                defer { input = "original"; observed.append("restored") }
                for await _ in release.stream { break }
                throw SourceSelectionFailure()
            }
        }
        var ready = entered.stream.makeAsyncIterator()
        _ = await ready.next()
        let second = Task { @MainActor in
            attempted.continuation.yield(())
            return try await builder.withSourceSelection(workspace: workspace) {
                observed.append(input)
                return input
            }
        }
        var pending = attempted.stream.makeAsyncIterator()
        _ = await pending.next()
        let cancelled = Task { @MainActor in
            try await builder.withSourceSelection(workspace: workspace) {
                observed.append("cancelled operation ran")
            }
        }
        await Task.yield()
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(input == "first")
        #expect(observed.isEmpty)
        release.continuation.yield(())
        release.continuation.finish()
        await #expect(throws: SourceSelectionFailure.self) { try await first.value }
        #expect(try await second.value == "original")
        #expect(observed == ["restored", "original"])
    }

    @Test func sourceSelectionDoesNotBlockAnotherWorkspace() async throws {
        let (builder, root) = try sourceSelectionBuilder()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstWorkspace = NSObject()
        let secondWorkspace = NSObject()
        let entered = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let attempted = AsyncStream<Void>.makeStream()
        var secondEntered = false
        let first = Task { @MainActor in
            try await builder.withSourceSelection(workspace: firstWorkspace) {
                entered.continuation.yield(())
                for await _ in release.stream { break }
            }
        }
        var ready = entered.stream.makeAsyncIterator()
        _ = await ready.next()
        let second = Task { @MainActor in
            attempted.continuation.yield(())
            try await builder.withSourceSelection(workspace: secondWorkspace) { secondEntered = true }
        }
        var pending = attempted.stream.makeAsyncIterator()
        _ = await pending.next()
        #expect(secondEntered)
        release.continuation.yield(())
        release.continuation.finish()
        try await first.value
        try await second.value
    }

    private func sourceSelectionBuilder() throws -> (NativePreviewBuild, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = root.appendingPathComponent("Xcode.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/Frameworks/IDEFoundation.framework"),
                                                withIntermediateDirectories: true)
        return (NativePreviewBuild(installation: try NativeXcodeInstallation(developerDirectory: app)), root)
    }

    @Test func resolvesRunnableAndUsesNativeBuildableEquality() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = root.appendingPathComponent("Xcode.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/Frameworks/IDEFoundation.framework"),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let builder = NativePreviewBuild(installation: try NativeXcodeInstallation(developerDirectory: app))
        let product = PreviewBuildBuildable(identity: "Selected")
        let equivalent = PreviewBuildBuildable(identity: "Selected")
        let unrelated = PreviewBuildBuildable(identity: "Unrelated")
        let scheme = PreviewBuildScheme(runnable: PreviewBuildRunnable(product: product))
        let resolved = try builder.runnableBuildable(in: scheme)
        let runnable = try #require(resolved)

        #expect(equivalent !== product)
        #expect(NativePreviewBuild.isRunnable(equivalent, runnable: runnable))
        #expect(!NativePreviewBuild.isRunnable(unrelated, runnable: runnable))

        let pathScheme = PreviewBuildScheme(runnable: PreviewBuildRunnable(product: nil))
        let absent = try builder.runnableBuildable(in: pathScheme)
        #expect(absent == nil)
        #expect(!NativePreviewBuild.isRunnable(equivalent, runnable: absent))
    }

    @Test func linkBuildablesPreserveDynamicOwnersAndDirectStaticDependencies() {
        let source = PreviewBuildBuildable(identity: "Source")
        let dynamic = PreviewBuildBuildable(identity: "Dynamic")
        let internalStatic = PreviewBuildBuildable(identity: "Internal")
        let sharedArchive = PreviewBuildBuildable(identity: "Shared")
        let dependencies: [ObjectIdentifier: [NSObject]] = [
            ObjectIdentifier(source): [dynamic, sharedArchive],
            ObjectIdentifier(dynamic): [internalStatic, sharedArchive],
        ]

        let inputs = NativePreviewBuild.linkBuildables(for: source, dependencies: dependencies,
            dynamicBuildables: [ObjectIdentifier(dynamic)])

        #expect(inputs.count == 2)
        #expect(Set(inputs.map(ObjectIdentifier.init)) == [ObjectIdentifier(dynamic), ObjectIdentifier(sharedArchive)])
    }

    @Test func previewRootsIncludeStaticSourceAndFirstDynamicDependencies() {
        let source = PreviewBuildBuildable(identity: "Source")
        let archive = PreviewBuildBuildable(identity: "Archive")
        let dynamic = PreviewBuildBuildable(identity: "Dynamic")
        let nested = PreviewBuildBuildable(identity: "Nested")
        let dependencies: [ObjectIdentifier: [NSObject]] = [
            ObjectIdentifier(source): [archive],
            ObjectIdentifier(archive): [dynamic],
            ObjectIdentifier(dynamic): [nested],
        ]

        let roots = NativePreviewBuild.previewRootBuildables(for: source, dependencies: dependencies, dependents: [:],
            dynamicBuildables: [ObjectIdentifier(dynamic), ObjectIdentifier(nested)])

        #expect(roots.count == 2)
        #expect(Set(roots.map(ObjectIdentifier.init)) == [ObjectIdentifier(source), ObjectIdentifier(dynamic)])
    }

    @Test func previewRootsUseNearestDynamicAncestorIncludingSelf() {
        let source = PreviewBuildBuildable(identity: "Source")
        let archive = PreviewBuildBuildable(identity: "Archive")
        let owner = PreviewBuildBuildable(identity: "Owner")
        let outer = PreviewBuildBuildable(identity: "Outer")
        let support = PreviewBuildBuildable(identity: "Support")
        let dependencies: [ObjectIdentifier: [NSObject]] = [
            ObjectIdentifier(outer): [owner],
            ObjectIdentifier(owner): [archive],
            ObjectIdentifier(archive): [source],
            ObjectIdentifier(source): [support],
        ]
        let dependents: [ObjectIdentifier: [NSObject]] = [
            ObjectIdentifier(source): [archive],
            ObjectIdentifier(archive): [owner],
            ObjectIdentifier(owner): [outer],
        ]
        let dynamicBuildables: Set<ObjectIdentifier> = [ObjectIdentifier(owner), ObjectIdentifier(outer), ObjectIdentifier(support)]

        let roots = NativePreviewBuild.previewRootBuildables(for: source, dependencies: dependencies, dependents: dependents,
            dynamicBuildables: dynamicBuildables)
        let ownerRoots = NativePreviewBuild.previewRootBuildables(for: owner, dependencies: dependencies, dependents: dependents,
            dynamicBuildables: dynamicBuildables)

        #expect(roots.count == 1)
        #expect(roots.first === owner)
        #expect(ownerRoots.count == 1)
        #expect(ownerRoots.first === owner)
    }

    @Test func previewRootsPreserveDistinctDynamicAncestorsAndDeduplicateSharedPaths() {
        let source = PreviewBuildBuildable(identity: "Source")
        let left = PreviewBuildBuildable(identity: "Left")
        let right = PreviewBuildBuildable(identity: "Right")
        let firstOwner = PreviewBuildBuildable(identity: "Owner")
        let secondOwner = PreviewBuildBuildable(identity: "Owner")
        let dependents: [ObjectIdentifier: [NSObject]] = [
            ObjectIdentifier(source): [left, right],
            ObjectIdentifier(left): [firstOwner],
            ObjectIdentifier(right): [firstOwner, secondOwner],
        ]

        let roots = NativePreviewBuild.previewRootBuildables(for: source, dependencies: [:], dependents: dependents,
            dynamicBuildables: [ObjectIdentifier(firstOwner), ObjectIdentifier(secondOwner)])

        #expect(roots.count == 2)
        #expect(Set(roots.map(ObjectIdentifier.init)) == [ObjectIdentifier(firstOwner), ObjectIdentifier(secondOwner)])
    }
}

private struct SourceSelectionFailure: Error {}

private final class PreviewBuildScheme: NSObject {
    @objc let launchSchemeAction: PreviewBuildLaunchAction
    init(runnable: PreviewBuildRunnable? = nil) {
        launchSchemeAction = PreviewBuildLaunchAction(runnable: runnable)
    }
}

private final class PreviewBuildLaunchAction: NSObject {
    @objc let runnable: PreviewBuildRunnable?
    init(runnable: PreviewBuildRunnable?) { self.runnable = runnable }
}

private final class PreviewBuildRunnable: NSObject {
    @objc let buildableProduct: PreviewBuildBuildable?
    init(product: PreviewBuildBuildable?) { buildableProduct = product }
}

private final class PreviewBuildBuildable: NSObject {
    let identity: String
    init(identity: String) { self.identity = identity }
    override func isEqual(_ object: Any?) -> Bool {
        (object as? PreviewBuildBuildable)?.identity == identity
    }
    override var hash: Int { identity.hashValue }
}
