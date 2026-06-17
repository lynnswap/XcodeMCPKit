import Foundation
import NIOEmbedded
import Testing

@testable import ProxyXcodeFeatures
@testable import ProxyXcodeSupport

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

        let resolver = RefreshCodeIssues.TargetResolver()
        let resolved = await resolver.resolveAbsoluteFilePath(
            workspacePath: root,
            workspaceRoot: root,
            requestedFilePath: "App/Sources/Foo.swift"
        )

        #expect(resolved == target.path)
    }

    @Test func resolverRejectsDirectoryPaths() async throws {
        let root = makeTemporaryWorkspaceRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let directory = URL(fileURLWithPath: root)
            .appendingPathComponent("App/Sources")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let resolver = RefreshCodeIssues.TargetResolver()
        let resolved = await resolver.resolveAbsoluteFilePath(
            workspacePath: root,
            workspaceRoot: root,
            requestedFilePath: "App/Sources"
        )

        #expect(resolved == nil)
    }

    @Test func resolverRejectsDirectoryPathBeforeBasenameFallback() async throws {
        let root = makeTemporaryWorkspaceRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let directory = URL(fileURLWithPath: root)
            .appendingPathComponent("App/Sources/Foo.swift")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let unrelatedFile = URL(fileURLWithPath: root)
            .appendingPathComponent("Other/Foo.swift")
        try FileManager.default.createDirectory(
            at: unrelatedFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "".write(to: unrelatedFile, atomically: true, encoding: .utf8)

        let resolver = RefreshCodeIssues.TargetResolver()
        let resolved = await resolver.resolveAbsoluteFilePath(
            workspacePath: root,
            workspaceRoot: root,
            requestedFilePath: "App/Sources/Foo.swift"
        )

        #expect(resolved == nil)
    }

    @Test func resolverDoesNotReuseStaleCachedPath() async throws {
        let root = makeTemporaryWorkspaceRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let target = URL(fileURLWithPath: root)
            .appendingPathComponent("App/Sources/Foo.swift")
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "".write(to: target, atomically: true, encoding: .utf8)

        let resolver = RefreshCodeIssues.TargetResolver()
        let first = await resolver.resolveAbsoluteFilePath(
            workspacePath: root,
            workspaceRoot: root,
            requestedFilePath: "App/Sources/Foo.swift"
        )
        #expect(first == target.path)

        try FileManager.default.removeItem(at: target)

        let second = await resolver.resolveAbsoluteFilePath(
            workspacePath: root,
            workspaceRoot: root,
            requestedFilePath: "App/Sources/Foo.swift"
        )

        #expect(second == nil)
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

        let resolver = RefreshCodeIssues.TargetResolver()
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

        let resolver = RefreshCodeIssues.TargetResolver()
        let resolved = await resolver.resolveAbsoluteFilePath(
            workspacePath: root,
            workspaceRoot: root,
            requestedFilePath: "Feature/Screen/Foo.swift"
        )

        #expect(resolved == nil)
    }

    @Test func resolverDoesNotReuseSuffixMatchedPathAfterWorkspaceContentsChange() async throws {
        let root = makeTemporaryWorkspaceRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let firstCandidate = URL(fileURLWithPath: root)
            .appendingPathComponent("A/Feature/Screen/Foo.swift")
        try FileManager.default.createDirectory(
            at: firstCandidate.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "".write(to: firstCandidate, atomically: true, encoding: .utf8)

        let resolver = RefreshCodeIssues.TargetResolver()
        let first = await resolver.resolveAbsoluteFilePath(
            workspacePath: root,
            workspaceRoot: root,
            requestedFilePath: "Feature/Screen/Foo.swift"
        )
        #expect(first?.hasSuffix("/A/Feature/Screen/Foo.swift") == true)

        let secondCandidate = URL(fileURLWithPath: root)
            .appendingPathComponent("B/Feature/Screen/Foo.swift")
        try FileManager.default.createDirectory(
            at: secondCandidate.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "".write(to: secondCandidate, atomically: true, encoding: .utf8)

        let second = await resolver.resolveAbsoluteFilePath(
            workspacePath: root,
            workspaceRoot: root,
            requestedFilePath: "Feature/Screen/Foo.swift"
        )

        #expect(second == nil)
    }

    @Test func resolverIgnoresBrokenSuffixMatchedSymlink() async throws {
        let root = makeTemporaryWorkspaceRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let brokenSymlink = URL(fileURLWithPath: root)
            .appendingPathComponent("Broken/Feature/Screen/Foo.swift")
        try FileManager.default.createDirectory(
            at: brokenSymlink.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: brokenSymlink.path,
            withDestinationPath: URL(fileURLWithPath: root)
                .appendingPathComponent("Missing/Foo.swift").path
        )

        let validFallback = URL(fileURLWithPath: root)
            .appendingPathComponent("Real/Screen/Foo.swift")
        try FileManager.default.createDirectory(
            at: validFallback.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "".write(to: validFallback, atomically: true, encoding: .utf8)

        let resolver = RefreshCodeIssues.TargetResolver()
        let resolved = await resolver.resolveAbsoluteFilePath(
            workspacePath: root,
            workspaceRoot: root,
            requestedFilePath: "Feature/Screen/Foo.swift"
        )

        #expect(resolved == fileReferencePath(validFallback))
    }

    @Test func resolverIgnoresSuffixMatchedSymlinkToDirectory() async throws {
        let root = makeTemporaryWorkspaceRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let directoryTarget = URL(fileURLWithPath: root)
            .appendingPathComponent("DirectoryTarget")
        try FileManager.default.createDirectory(
            at: directoryTarget,
            withIntermediateDirectories: true
        )

        let directorySymlink = URL(fileURLWithPath: root)
            .appendingPathComponent("Broken/Feature/Screen/Foo.swift")
        try FileManager.default.createDirectory(
            at: directorySymlink.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: directorySymlink.path,
            withDestinationPath: directoryTarget.path
        )

        let validFallback = URL(fileURLWithPath: root)
            .appendingPathComponent("Real/Screen/Foo.swift")
        try FileManager.default.createDirectory(
            at: validFallback.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "".write(to: validFallback, atomically: true, encoding: .utf8)

        let resolver = RefreshCodeIssues.TargetResolver()
        let resolved = await resolver.resolveAbsoluteFilePath(
            workspacePath: root,
            workspaceRoot: root,
            requestedFilePath: "Feature/Screen/Foo.swift"
        )

        #expect(resolved == fileReferencePath(validFallback))
    }

    @Test func resolverReturnsSuffixMatchedSymlinkAliasPath() async throws {
        let root = makeTemporaryWorkspaceRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let target = URL(fileURLWithPath: root)
            .appendingPathComponent("Targets/Deep/Foo.swift")
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "".write(to: target, atomically: true, encoding: .utf8)

        let alias = URL(fileURLWithPath: root)
            .appendingPathComponent("Alias/Feature/Screen/Foo.swift")
        try FileManager.default.createDirectory(
            at: alias.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: alias.path,
            withDestinationPath: target.path
        )

        let resolver = RefreshCodeIssues.TargetResolver()
        let resolved = await resolver.resolveAbsoluteFilePath(
            workspacePath: root,
            workspaceRoot: root,
            requestedFilePath: "Feature/Screen/Foo.swift"
        )

        #expect(resolved == fileReferencePath(alias))
    }

    @Test func resolverDoesNotSuffixMatchCaseMismatchedPath() async throws {
        let root = makeTemporaryWorkspaceRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let target = URL(fileURLWithPath: root)
            .appendingPathComponent("Feature/Screen/Foo.swift")
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "".write(to: target, atomically: true, encoding: .utf8)

        let resolver = RefreshCodeIssues.TargetResolver()
        let resolved = await resolver.resolveAbsoluteFilePath(
            workspacePath: root,
            workspaceRoot: root,
            requestedFilePath: "feature/screen/foo.swift"
        )

        if FileManager.default.fileExists(atPath: "\(root)/feature/screen/foo.swift") {
            #expect(resolved?.lowercased() == target.path.lowercased())
        } else {
            #expect(resolved == nil)
        }
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

        let resolver = RefreshCodeIssues.TargetResolver()
        let resolved = await resolver.resolveAbsoluteFilePath(
            workspacePath: root,
            workspaceRoot: root,
            requestedFilePath: outsideFile.path
        )

        #expect(resolved == nil)
    }

    @Test func resolverAcceptsAbsolutePathInsideWorkspaceRoot() async throws {
        let root = makeTemporaryWorkspaceRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let target = URL(fileURLWithPath: root)
            .appendingPathComponent("App/Sources/Foo.swift")
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "".write(to: target, atomically: true, encoding: .utf8)

        let resolver = RefreshCodeIssues.TargetResolver()
        let resolved = await resolver.resolveAbsoluteFilePath(
            workspacePath: root,
            workspaceRoot: root,
            requestedFilePath: target.path
        )

        #expect(resolved == target.path)
    }

    @Test func resolverAcceptsAbsoluteSymlinkAliasInsideWorkspaceRoot() async throws {
        let root = makeTemporaryWorkspaceRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let target = URL(fileURLWithPath: root)
            .appendingPathComponent("App/Sources/Foo.swift")
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "".write(to: target, atomically: true, encoding: .utf8)

        let aliasDirectory = URL(fileURLWithPath: root)
            .appendingPathComponent("Alias")
        try FileManager.default.createDirectory(
            at: aliasDirectory,
            withIntermediateDirectories: true
        )
        let aliasPath = aliasDirectory.appendingPathComponent("Foo.swift").path
        try FileManager.default.createSymbolicLink(
            atPath: aliasPath,
            withDestinationPath: target.path
        )

        let resolver = RefreshCodeIssues.TargetResolver()
        let resolved = await resolver.resolveAbsoluteFilePath(
            workspacePath: root,
            workspaceRoot: root,
            requestedFilePath: aliasPath
        )

        #expect(resolved == target.path)
    }

    @Test func resolverRejectsStaleAbsolutePathWithoutBasenameFallback() async throws {
        let root = makeTemporaryWorkspaceRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let staleTarget = URL(fileURLWithPath: root)
            .appendingPathComponent("App/Sources/Foo.swift")
        try FileManager.default.createDirectory(
            at: staleTarget.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "".write(to: staleTarget, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: staleTarget)

        let unrelatedFile = URL(fileURLWithPath: root)
            .appendingPathComponent("Other/Foo.swift")
        try FileManager.default.createDirectory(
            at: unrelatedFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "".write(to: unrelatedFile, atomically: true, encoding: .utf8)

        let resolver = RefreshCodeIssues.TargetResolver()
        let resolved = await resolver.resolveAbsoluteFilePath(
            workspacePath: root,
            workspaceRoot: root,
            requestedFilePath: staleTarget.path
        )

        #expect(resolved == nil)
    }

    @Test func resolverRejectsTraversalOutsideWorkspaceRoot() async throws {
        let root = makeTemporaryWorkspaceRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let resolver = RefreshCodeIssues.TargetResolver()
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

        let resolver = RefreshCodeIssues.TargetResolver()
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

        let resolver = RefreshCodeIssues.TargetResolver()
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

        let resolver = RefreshCodeIssues.TargetResolver()
        let resolution = try await resolver.resolve(
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

    @Test func resolverPreservesSuffixMatchedSymlinkAliasInWorkspaceRelativePath() async throws {
        let root = makeTemporaryWorkspaceRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let workspacePath = URL(fileURLWithPath: root)
            .appendingPathComponent("SampleProject.xcworkspace").path
        try FileManager.default.createDirectory(
            atPath: workspacePath,
            withIntermediateDirectories: true
        )

        let target = URL(fileURLWithPath: root)
            .appendingPathComponent("Targets/Deep/PrimaryView.swift")
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "".write(to: target, atomically: true, encoding: .utf8)

        let alias = URL(fileURLWithPath: root)
            .appendingPathComponent("Alias/Feature/Scene/PrimaryView.swift")
        try FileManager.default.createDirectory(
            at: alias.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: alias.path,
            withDestinationPath: target.path
        )

        let resolver = RefreshCodeIssues.TargetResolver()
        let resolution = try await resolver.resolve(
            tabIdentifier: "windowtab2",
            filePath: "Feature/Scene/PrimaryView.swift",
            sessionID: "session-1",
            eventLoop: EmbeddedEventLoop(),
            windowsProvider: { _, _ in
                [XcodeWindowInfo(tabIdentifier: "windowtab2", workspacePath: workspacePath)]
            }
        )

        #expect(resolution.failureReason == nil)
        #expect(resolution.target?.resolvedFilePath == fileReferencePath(alias))
        #expect(resolution.target?.workspaceRelativePath == "Alias/Feature/Scene/PrimaryView.swift")
    }

    @Test func resolverFallsBackToResolvedPathWhenWorkspaceRootUsesSymlinkAlias() async throws {
        let realRoot = makeTemporaryWorkspaceRoot()
        defer { try? FileManager.default.removeItem(atPath: realRoot) }

        let rootAlias = URL(fileURLWithPath: FileManager.default.temporaryDirectory.path)
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createSymbolicLink(
            atPath: rootAlias.path,
            withDestinationPath: realRoot
        )
        defer { try? FileManager.default.removeItem(at: rootAlias) }

        let target = URL(fileURLWithPath: realRoot)
            .appendingPathComponent("App/Sources/Foo.swift")
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "".write(to: target, atomically: true, encoding: .utf8)

        let resolver = RefreshCodeIssues.TargetResolver()
        let relativePath = await resolver.relativePath(
            for: target.path,
            within: rootAlias.path
        )

        #expect(relativePath == "App/Sources/Foo.swift")
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

        let resolver = RefreshCodeIssues.TargetResolver()
        let eventLoop = EmbeddedEventLoop()

        let first = try await resolver.resolve(
            tabIdentifier: "windowtab2",
            filePath: "SampleProject/Feature/Scene/PrimaryView.swift",
            sessionID: "session-1",
            eventLoop: eventLoop,
            windowsProvider: { _, _ in
                [XcodeWindowInfo(tabIdentifier: "windowtab2", workspacePath: workspaceA)]
            }
        )
        let second = try await resolver.resolve(
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

        let resolver = RefreshCodeIssues.TargetResolver()
        let eventLoop = EmbeddedEventLoop()

        let first = try await resolver.resolve(
            tabIdentifier: "windowtab2",
            filePath: "SampleProject/Feature/Scene/PrimaryView.swift",
            sessionID: "session-1",
            eventLoop: eventLoop,
            windowsProvider: { _, _ in
                [XcodeWindowInfo(tabIdentifier: "windowtab2", workspacePath: workspacePath)]
            }
        )
        let second = try await resolver.resolve(
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

        let resolver = RefreshCodeIssues.TargetResolver()
        let eventLoop = EmbeddedEventLoop()

        let first = try await resolver.resolve(
            tabIdentifier: "windowtab2",
            filePath: "SampleProject/Feature/Scene/PrimaryView.swift",
            sessionID: "session-A",
            eventLoop: eventLoop,
            windowsProvider: { _, _ in
                [XcodeWindowInfo(tabIdentifier: "windowtab2", workspacePath: workspacePath)]
            }
        )
        let second = try await resolver.resolve(
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

private func fileReferencePath(_ url: URL) -> String {
    ((url as NSURL).fileReferenceURL()?.path) ?? url.path
}
