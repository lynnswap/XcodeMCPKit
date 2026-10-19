import Foundation
import Testing
@testable import XcodeMCPNativeRuntime

@MainActor
struct NativeWorkspaceRegistryTests {
    @Test func packageManifestAndDirectoryResolveToTheSameWorkspacePath() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativeWorkspaceRegistryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = directory.appendingPathComponent("Package.swift")
        try "import PackageDescription".write(to: manifest, atomically: true, encoding: .utf8)

        #expect(NativeWorkspaceRegistry.workspacePath(for: manifest.path)
            == NativeWorkspaceRegistry.workspacePath(for: directory.path))
    }

    @Test func removedModelsStayOpenUntilAnotherRequestReleasesTheirWorkspace() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativeWorkspaceRegistryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let real = directory.appendingPathComponent("Real", isDirectory: true)
        let alias = directory.appendingPathComponent("Alias", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        let active = real.appendingPathComponent("Active.xcodeproj", isDirectory: true)
        let removed = directory.appendingPathComponent("Removed.xcodeproj", isDirectory: true)
        let existing = directory.appendingPathComponent("Existing.xcodeproj", isDirectory: true)
        for project in [active, removed, existing] {
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        }
        let activeKey = active.standardizedFileURL.resolvingSymlinksInPath().path
        let entries: [(identifier: String, path: String?)] = [
            ("active", alias.appendingPathComponent("Active.xcodeproj").path),
            ("removed", removed.path), ("existing", existing.path),
        ]
        let activeRequest = directory.appendingPathComponent("request-a")
        let cleanupRequest = directory.appendingPathComponent("request-b")
        let execution = NativeWorkspaceRegistry.WorkspaceExecution(workspace: activeKey, entries: entries)
        try FileManager.default.removeItem(at: active)
        try FileManager.default.removeItem(at: removed)
        var closed: [String] = []

        try NativeWorkspaceRegistry.closeRemovedEntries(entries, request: cleanupRequest,
            activeExecutions: [activeRequest: execution]) { closed.append($0) }

        #expect(closed == ["removed"])

        closed.removeAll()
        try NativeWorkspaceRegistry.closeRemovedEntries(entries, request: cleanupRequest,
            activeExecutions: [:]) { closed.append($0) }

        #expect(closed == ["active", "removed"])
    }
}
