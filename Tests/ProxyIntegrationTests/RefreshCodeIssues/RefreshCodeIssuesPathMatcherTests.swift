import Foundation
import Testing

@testable import ProxyFeatureXcode

@Suite
struct RefreshCodeIssuesPathMatcherTests {
    @Test func matcherTreatsCaseOnlyDifferencesAsEqualOnCaseInsensitiveFileSystems() {
        #expect(
            RefreshCodeIssuesPathMatcher.matches(
                issuePath: "/tmp/Workspace/Foo.swift",
                resolvedFilePath: "/tmp/workspace/foo.swift",
                caseSensitiveFileSystemOverride: false
            )
        )
    }

    @Test func matcherPreservesCaseSensitivePathDifferences() {
        #expect(
            RefreshCodeIssuesPathMatcher.matches(
                issuePath: "/tmp/Workspace/Foo.swift",
                resolvedFilePath: "/tmp/workspace/foo.swift",
                caseSensitiveFileSystemOverride: true
            ) == false
        )
    }

    @Test func matcherTreatsSymlinkedPathsAsEquivalent() throws {
        let root = makeTemporaryWorkspaceRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let target = URL(fileURLWithPath: root)
            .appendingPathComponent("App/Sources/Foo.swift")
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "".write(to: target, atomically: true, encoding: .utf8)

        let symlinkPath = URL(fileURLWithPath: root)
            .appendingPathComponent("Linked/Foo.swift")
        try FileManager.default.createDirectory(
            at: symlinkPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: symlinkPath.path,
            withDestinationPath: target.path
        )

        #expect(
            RefreshCodeIssuesPathMatcher.matches(
                issuePath: symlinkPath.path,
                resolvedFilePath: target.path
            )
        )
    }
}

private func makeTemporaryWorkspaceRoot() -> String {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.path
}
