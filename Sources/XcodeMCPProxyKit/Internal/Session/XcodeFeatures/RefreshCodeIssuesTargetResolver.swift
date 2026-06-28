import Foundation
import NIO
import XcodeMCPCore
import XcodeMCPProcessRuntime
import XcodeMCPProxyRuntime

extension RefreshCodeIssues {
    package struct ResolvedTarget: Sendable, Equatable {
        package let workspacePath: String
        package let workspaceRoot: String
        package let resolvedFilePath: String
        package let workspaceRelativePath: String
    }

    package struct TargetResolution: Sendable, Equatable {
        package let target: RefreshCodeIssues.ResolvedTarget?
        package let workspacePath: String?
        package let resolvedFilePath: String?
        package let failureReason: String?
    }

    package actor TargetResolver {
    package typealias WindowsProvider =
        @Sendable (_ sessionID: String, _ eventLoop: EventLoop) async throws -> [XcodeWindowInfo]?

    private struct FileResolutionKey: Hashable {
        let workspacePath: String
        let filePath: String
    }

    private let fileSystem: FileSystemClient
    private var resolvedFilePathCache: [FileResolutionKey: String] = [:]

    package init(fileSystem: FileSystemClient = .liveValue) {
        self.fileSystem = fileSystem
    }

    package func resolve(
        tabIdentifier: String?,
        filePath: String?,
        sessionID: String,
        eventLoop: EventLoop,
        windowsProvider: WindowsProvider
    ) async throws -> RefreshCodeIssues.TargetResolution {
        guard let tabIdentifier, tabIdentifier.isEmpty == false else {
            return RefreshCodeIssues.TargetResolution(
                target: nil,
                workspacePath: nil,
                resolvedFilePath: nil,
                failureReason: "missing tabIdentifier"
            )
        }
        guard let filePath, filePath.isEmpty == false else {
            return RefreshCodeIssues.TargetResolution(
                target: nil,
                workspacePath: nil,
                resolvedFilePath: nil,
                failureReason: "missing filePath"
            )
        }

        let workspacePath = try await resolveWorkspacePath(
            tabIdentifier: tabIdentifier,
            sessionID: sessionID,
            eventLoop: eventLoop,
            windowsProvider: windowsProvider
        )
        guard let workspacePath else {
            return RefreshCodeIssues.TargetResolution(
                target: nil,
                workspacePath: nil,
                resolvedFilePath: nil,
                failureReason: "workspacePath not found"
            )
        }

        let workspaceRoot = workspaceRoot(for: workspacePath)
        guard let resolvedFilePath = resolveAbsoluteFilePath(
            workspacePath: workspacePath,
            workspaceRoot: workspaceRoot,
            requestedFilePath: filePath
        ) else {
            return RefreshCodeIssues.TargetResolution(
                target: nil,
                workspacePath: workspacePath,
                resolvedFilePath: nil,
                failureReason: "could not resolve target path"
            )
        }
        guard let workspaceRelativePath = relativePath(
            for: resolvedFilePath,
            within: workspaceRoot
        ) else {
            return RefreshCodeIssues.TargetResolution(
                target: nil,
                workspacePath: workspacePath,
                resolvedFilePath: resolvedFilePath,
                failureReason: "resolved path outside workspace root"
            )
        }

        return RefreshCodeIssues.TargetResolution(
            target: RefreshCodeIssues.ResolvedTarget(
                workspacePath: workspacePath,
                workspaceRoot: workspaceRoot,
                resolvedFilePath: resolvedFilePath,
                workspaceRelativePath: workspaceRelativePath
            ),
            workspacePath: workspacePath,
            resolvedFilePath: resolvedFilePath,
            failureReason: nil
        )
    }

    package func resolveAbsoluteFilePath(
        workspacePath: String,
        workspaceRoot: String,
        requestedFilePath: String
    ) -> String? {
        let key = FileResolutionKey(
            workspacePath: workspacePath,
            filePath: requestedFilePath
        )
        if let cached = resolvedFilePathCache[key],
            isExistingRegularFile(cached, containedIn: workspaceRoot)
        {
            return cached
        }

        let requestedRelativeComponents: [String]
        if requestedFilePath.hasPrefix("/") {
            let absolutePath = URL(fileURLWithPath: requestedFilePath).standardizedFileURL.path
            if let resolvedAbsolutePath = resolvedRegularFilePath(
                absolutePath,
                containedIn: workspaceRoot
            ) {
                resolvedFilePathCache[key] = resolvedAbsolutePath
                return resolvedAbsolutePath
            }
            if isExistingDirectory(absolutePath, containedIn: workspaceRoot) {
                return nil
            }
            return nil
        } else {
            guard let components = sanitizedRelativePathComponents(requestedFilePath),
                components.isEmpty == false
            else {
                return nil
            }
            requestedRelativeComponents = components
        }

        let directURL = requestedRelativeComponents.reduce(
            URL(fileURLWithPath: workspaceRoot)
        ) { partialURL, component in
            partialURL.appendingPathComponent(component)
        }
        let directPath = directURL.standardizedFileURL.path
        if isExistingRegularFile(directPath, containedIn: workspaceRoot)
        {
            resolvedFilePathCache[key] = directPath
            return directPath
        }
        if isExistingDirectory(directPath, containedIn: workspaceRoot) {
            return nil
        }

        guard let requestedBasename = requestedRelativeComponents.last else {
            return nil
        }
        let requestedComponents = requestedRelativeComponents
        var bestPath: String?
        var bestScore = 0
        var ambiguous = false

        for fileURL in fileSystem.enumeratedFileURLs(URL(fileURLWithPath: workspaceRoot)) {
            guard fileURL.hasDirectoryPath == false else { continue }
            guard fileURL.lastPathComponent == requestedBasename else { continue }
            guard resolvedRegularFilePath(
                fileURL.path,
                containedIn: workspaceRoot
            ) != nil else { continue }

            let score = suffixMatchScore(
                requestedComponents: requestedComponents,
                candidateComponents: normalizedPathComponents(fileURL.path)
            )
            guard score > 0 else { continue }

            if score > bestScore {
                bestScore = score
                bestPath = fileURL.path
                ambiguous = false
            } else if score == bestScore {
                ambiguous = true
            }
        }

        guard ambiguous == false, let bestPath else {
            return nil
        }
        return bestPath
    }

    package func workspaceRoot(for workspacePath: String) -> String {
        let url = URL(fileURLWithPath: workspacePath)
        if ["xcworkspace", "xcodeproj"].contains(url.pathExtension.lowercased()) {
            return url.deletingLastPathComponent().path
        }
        return workspacePath
    }

    package func relativePath(for absolutePath: String, within workspaceRoot: String) -> String? {
        let resolvedPath = resolvedPathForContainment(absolutePath)
        let resolvedRoot = resolvedPathForContainment(workspaceRoot)
        guard isPath(resolvedPath, containedIn: resolvedRoot) else {
            return nil
        }
        if let aliasRelativePath = lexicalRelativePath(
            path: standardizedPathPreservingSymlink(absolutePath),
            root: standardizedPathPreservingSymlink(workspaceRoot)
        ) {
            return aliasRelativePath
        }
        return lexicalRelativePath(path: resolvedPath, root: resolvedRoot)
    }

    private func resolveWorkspacePath(
        tabIdentifier: String,
        sessionID: String,
        eventLoop: EventLoop,
        windowsProvider: WindowsProvider
    ) async throws -> String? {
        guard let windows = try await windowsProvider(sessionID, eventLoop) else {
            return nil
        }
        return windows.first(where: { $0.tabIdentifier == tabIdentifier })?.workspacePath
    }

    private func normalizedPathComponents(_ path: String) -> [String] {
        URL(fileURLWithPath: path).pathComponents
            .filter { $0 != "/" && $0 != "." }
    }

    private func isExistingRegularFile(_ path: String, containedIn workspaceRoot: String) -> Bool {
        guard isPath(path, containedIn: workspaceRoot) else {
            return false
        }
        return fileSystem.regularFileExists(path)
    }

    private func resolvedRegularFilePath(_ path: String, containedIn workspaceRoot: String) -> String? {
        let resolvedPath = resolvedPathForContainment(path)
        guard isExistingRegularFile(resolvedPath, containedIn: workspaceRoot) else {
            return nil
        }
        return resolvedPath
    }

    private func isExistingDirectory(_ path: String, containedIn workspaceRoot: String) -> Bool {
        guard isPath(path, containedIn: workspaceRoot) else {
            return false
        }
        return fileSystem.directoryExists(path)
    }

    private func sanitizedRelativePathComponents(_ path: String) -> [String]? {
        guard path.isEmpty == false, path.hasPrefix("/") == false else { return nil }

        var components: [String] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                return nil
            default:
                components.append(String(component))
            }
        }
        return components.isEmpty ? nil : components
    }

    private func isPath(_ path: String, containedIn workspaceRoot: String) -> Bool {
        let resolvedPath = resolvedPathForContainment(path)
        let resolvedRoot = resolvedPathForContainment(workspaceRoot)
        guard resolvedRoot.isEmpty == false else { return false }
        if resolvedPath == resolvedRoot {
            return true
        }
        let rootPrefix = resolvedRoot.hasSuffix("/") ? resolvedRoot : resolvedRoot + "/"
        return resolvedPath.hasPrefix(rootPrefix)
    }

    private func resolvedPathForContainment(_ path: String) -> String {
        let symlinkResolvedPath = (path as NSString).resolvingSymlinksInPath
        return URL(fileURLWithPath: symlinkResolvedPath).standardizedFileURL.path
    }

    private func standardizedPathPreservingSymlink(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private func lexicalRelativePath(path: String, root: String) -> String? {
        if path == root {
            return "."
        }
        let rootPrefix = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(rootPrefix) else {
            return nil
        }
        return String(path.dropFirst(rootPrefix.count))
    }

    private func suffixMatchScore(
        requestedComponents: [String],
        candidateComponents: [String]
    ) -> Int {
        let requested = Array(requestedComponents.reversed())
        let candidate = Array(candidateComponents.reversed())
        var score = 0
        for (lhs, rhs) in zip(requested, candidate) {
            guard lhs == rhs else { break }
            score += 1
        }
        return score
    }
    }
}
