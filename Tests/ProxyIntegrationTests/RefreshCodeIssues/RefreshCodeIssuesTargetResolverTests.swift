import Foundation
import NIOEmbedded
import Testing

@testable import ProxyFeatureXcode

@Suite
struct RefreshCodeIssuesTargetResolverTests {
    @Test func resolverResolvesDirectPath() async throws {
        let root = makeTemporaryWorkspaceRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let target = URL(fileURLWithPath: root)
            .appendingPathComponent("App/Sources/Foo.swift")
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "".write(to: target, atomically: true, encoding: .utf8)

        let resolver = RefreshCodeIssuesTargetResolver()
        let resolved = await resolver.resolveAbsoluteFilePath(
            workspacePath: root,
            workspaceRoot: root,
            requestedFilePath: "App/Sources/Foo.swift"
        )

        #expect(resolved == target.path)
    }

    @Test func resolverResolvesSuffixMatchedPath() async throws {
        let root = makeTemporaryWorkspaceRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let target = URL(fileURLWithPath: root)
            .appendingPathComponent("SampleProject/Feature/Scene/PrimaryView.swift")
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "".write(to: target, atomically: true, encoding: .utf8)

        let resolver = RefreshCodeIssuesTargetResolver()
        let resolved = await resolver.resolveAbsoluteFilePath(
            workspacePath: root,
            workspaceRoot: root,
            requestedFilePath: "SampleProject/Feature/Scene/PrimaryView.swift"
        )

        #expect(resolved?.lowercased() == target.path.lowercased())
    }

    @Test func resolverReturnsNilForAmbiguousSuffixMatchedPath() async throws {
        let root = makeTemporaryWorkspaceRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let candidates = [
            "A/Feature/Screen/Foo.swift",
            "B/Feature/Screen/Foo.swift",
        ]
        for relativePath in candidates {
            let url = URL(fileURLWithPath: root).appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try "".write(to: url, atomically: true, encoding: .utf8)
        }

        let resolver = RefreshCodeIssuesTargetResolver()
        let resolved = await resolver.resolveAbsoluteFilePath(
            workspacePath: root,
            workspaceRoot: root,
            requestedFilePath: "Feature/Screen/Foo.swift"
        )

        #expect(resolved == nil)
    }

    @Test func resolverRejectsAbsolutePathOutsideWorkspaceRoot() async throws {
        let root = makeTemporaryWorkspaceRoot()
        let outsideRoot = makeTemporaryWorkspaceRoot()
        defer {
            try? FileManager.default.removeItem(atPath: root)
            try? FileManager.default.removeItem(atPath: outsideRoot)
        }

        let outsideFile = URL(fileURLWithPath: outsideRoot)
            .appendingPathComponent("Outside.swift")
        try "".write(to: outsideFile, atomically: true, encoding: .utf8)

        let resolver = RefreshCodeIssuesTargetResolver()
        let resolved = await resolver.resolveAbsoluteFilePath(
            workspacePath: root,
            workspaceRoot: root,
            requestedFilePath: outsideFile.path
        )

        #expect(resolved == nil)
    }

    @Test func resolverRejectsTraversalOutsideWorkspaceRoot() async throws {
        let root = makeTemporaryWorkspaceRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let resolver = RefreshCodeIssuesTargetResolver()
        let resolved = await resolver.resolveAbsoluteFilePath(
            workspacePath: root,
            workspaceRoot: root,
            requestedFilePath: "../Outside.swift"
        )

        #expect(resolved == nil)
    }

    @Test func resolverRejectsSymlinkEscapeOutsideWorkspaceRoot() async throws {
        let root = makeTemporaryWorkspaceRoot()
        let outsideRoot = makeTemporaryWorkspaceRoot()
        defer {
            try? FileManager.default.removeItem(atPath: root)
            try? FileManager.default.removeItem(atPath: outsideRoot)
        }

        let outsideFile = URL(fileURLWithPath: outsideRoot)
            .appendingPathComponent("Outside.swift")
        try "".write(to: outsideFile, atomically: true, encoding: .utf8)

        let symlinkPath = URL(fileURLWithPath: root).appendingPathComponent("linked").path
        try FileManager.default.createSymbolicLink(
            atPath: symlinkPath,
            withDestinationPath: outsideRoot
        )

        let resolver = RefreshCodeIssuesTargetResolver()
        let resolved = await resolver.resolveAbsoluteFilePath(
            workspacePath: root,
            workspaceRoot: root,
            requestedFilePath: "linked/Outside.swift"
        )

        #expect(resolved == nil)
    }

    @Test func resolverRejectsSuffixMatchedSymlinkEscapeOutsideWorkspaceRoot() async throws {
        let root = makeTemporaryWorkspaceRoot()
        let outsideRoot = makeTemporaryWorkspaceRoot()
        defer {
            try? FileManager.default.removeItem(atPath: root)
            try? FileManager.default.removeItem(atPath: outsideRoot)
        }

        let outsideFile = URL(fileURLWithPath: outsideRoot)
            .appendingPathComponent("Outside.swift")
        try "".write(to: outsideFile, atomically: true, encoding: .utf8)

        let symlinkDirectory = URL(fileURLWithPath: root)
            .appendingPathComponent("Some")
            .path
        try FileManager.default.createDirectory(
            atPath: symlinkDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: URL(fileURLWithPath: symlinkDirectory).appendingPathComponent("Outside.swift").path,
            withDestinationPath: outsideFile.path
        )

        let resolver = RefreshCodeIssuesTargetResolver()
        let resolved = await resolver.resolveAbsoluteFilePath(
            workspacePath: root,
            workspaceRoot: root,
            requestedFilePath: "Nested/Outside.swift"
        )

        #expect(resolved == nil)
    }

    @Test func resolverBuildsWorkspaceRelativePathFromResolvedTarget() async throws {
        let root = makeTemporaryWorkspaceRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let workspacePath = URL(fileURLWithPath: root)
            .appendingPathComponent("SampleProject.xcworkspace").path
        try FileManager.default.createDirectory(
            atPath: workspacePath,
            withIntermediateDirectories: true
        )
        let target = URL(fileURLWithPath: root)
            .appendingPathComponent("SampleProject/Feature/Scene/PrimaryView.swift")
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "".write(to: target, atomically: true, encoding: .utf8)

        let resolver = RefreshCodeIssuesTargetResolver()
        let resolution = await resolver.resolve(
            tabIdentifier: "windowtab2",
            filePath: "SampleProject/Feature/Scene/PrimaryView.swift",
            sessionID: "session-1",
            eventLoop: EmbeddedEventLoop(),
            windowsProvider: { _, _ in
                [XcodeWindowInfo(tabIdentifier: "windowtab2", workspacePath: workspacePath)]
            }
        )

        #expect(resolution.failureReason == nil)
        #expect(resolution.target?.workspaceRoot == root)
        #expect(resolution.target?.workspaceRelativePath == "SampleProject/Feature/Scene/PrimaryView.swift")
    }

    @Test func resolverUsesLatestWorkspacePathOnRepeatedLookups() async throws {
        let rootA = makeTemporaryWorkspaceRoot()
        let rootB = makeTemporaryWorkspaceRoot()
        defer {
            try? FileManager.default.removeItem(atPath: rootA)
            try? FileManager.default.removeItem(atPath: rootB)
        }

        let workspaceA = URL(fileURLWithPath: rootA)
            .appendingPathComponent("SampleProject.xcworkspace").path
        let workspaceB = URL(fileURLWithPath: rootB)
            .appendingPathComponent("SampleProject.xcworkspace").path
        try FileManager.default.createDirectory(atPath: workspaceA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: workspaceB, withIntermediateDirectories: true)

        let targetA = URL(fileURLWithPath: rootA)
            .appendingPathComponent("SampleProject/Feature/Scene/PrimaryView.swift")
        let targetB = URL(fileURLWithPath: rootB)
            .appendingPathComponent("SampleProject/Feature/Scene/PrimaryView.swift")
        try FileManager.default.createDirectory(
            at: targetA.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: targetB.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "".write(to: targetA, atomically: true, encoding: .utf8)
        try "".write(to: targetB, atomically: true, encoding: .utf8)

        let resolver = RefreshCodeIssuesTargetResolver()
        let eventLoop = EmbeddedEventLoop()

        let first = await resolver.resolve(
            tabIdentifier: "windowtab2",
            filePath: "SampleProject/Feature/Scene/PrimaryView.swift",
            sessionID: "session-1",
            eventLoop: eventLoop,
            windowsProvider: { _, _ in
                [XcodeWindowInfo(tabIdentifier: "windowtab2", workspacePath: workspaceA)]
            }
        )
        let second = await resolver.resolve(
            tabIdentifier: "windowtab2",
            filePath: "SampleProject/Feature/Scene/PrimaryView.swift",
            sessionID: "session-1",
            eventLoop: eventLoop,
            windowsProvider: { _, _ in
                [XcodeWindowInfo(tabIdentifier: "windowtab2", workspacePath: workspaceB)]
            }
        )

        #expect(first.workspacePath == workspaceA)
        #expect(second.workspacePath == workspaceB)
        #expect(second.target?.resolvedFilePath == targetB.path)
    }

    @Test func resolverFallsBackWhenWindowLookupFailsAfterPreviousSuccess() async throws {
        let root = makeTemporaryWorkspaceRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let workspacePath = URL(fileURLWithPath: root)
            .appendingPathComponent("SampleProject.xcworkspace").path
        try FileManager.default.createDirectory(atPath: workspacePath, withIntermediateDirectories: true)

        let target = URL(fileURLWithPath: root)
            .appendingPathComponent("SampleProject/Feature/Scene/PrimaryView.swift")
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "".write(to: target, atomically: true, encoding: .utf8)

        let resolver = RefreshCodeIssuesTargetResolver()
        let eventLoop = EmbeddedEventLoop()

        let first = await resolver.resolve(
            tabIdentifier: "windowtab2",
            filePath: "SampleProject/Feature/Scene/PrimaryView.swift",
            sessionID: "session-1",
            eventLoop: eventLoop,
            windowsProvider: { _, _ in
                [XcodeWindowInfo(tabIdentifier: "windowtab2", workspacePath: workspacePath)]
            }
        )
        let second = await resolver.resolve(
            tabIdentifier: "windowtab2",
            filePath: "SampleProject/Feature/Scene/PrimaryView.swift",
            sessionID: "session-1",
            eventLoop: eventLoop,
            windowsProvider: { _, _ in
                nil
            }
        )

        #expect(first.failureReason == nil)
        #expect(second.target == nil)
        #expect(second.workspacePath == nil)
        #expect(second.failureReason == "workspacePath not found")
    }

    @Test func resolverRequiresWindowLookupPerSession() async throws {
        let root = makeTemporaryWorkspaceRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let workspacePath = URL(fileURLWithPath: root)
            .appendingPathComponent("SampleProject.xcworkspace").path
        try FileManager.default.createDirectory(atPath: workspacePath, withIntermediateDirectories: true)

        let target = URL(fileURLWithPath: root)
            .appendingPathComponent("SampleProject/Feature/Scene/PrimaryView.swift")
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "".write(to: target, atomically: true, encoding: .utf8)

        let resolver = RefreshCodeIssuesTargetResolver()
        let eventLoop = EmbeddedEventLoop()

        let first = await resolver.resolve(
            tabIdentifier: "windowtab2",
            filePath: "SampleProject/Feature/Scene/PrimaryView.swift",
            sessionID: "session-A",
            eventLoop: eventLoop,
            windowsProvider: { _, _ in
                [XcodeWindowInfo(tabIdentifier: "windowtab2", workspacePath: workspacePath)]
            }
        )
        let second = await resolver.resolve(
            tabIdentifier: "windowtab2",
            filePath: "SampleProject/Feature/Scene/PrimaryView.swift",
            sessionID: "session-B",
            eventLoop: eventLoop,
            windowsProvider: { _, _ in
                nil
            }
        )

        #expect(first.failureReason == nil)
        #expect(second.workspacePath == nil)
        #expect(second.failureReason == "workspacePath not found")
    }
}

private func makeTemporaryWorkspaceRoot() -> String {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.path
}
