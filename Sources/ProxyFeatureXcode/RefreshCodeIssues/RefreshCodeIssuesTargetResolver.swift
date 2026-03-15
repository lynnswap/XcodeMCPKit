import Foundation
import NIO

package struct XcodeWindowInfo: Sendable, Equatable {
    package let tabIdentifier: String
    package let workspacePath: String

    package init(tabIdentifier: String, workspacePath: String) {
        self.tabIdentifier = tabIdentifier
        self.workspacePath = workspacePath
    }
}

package struct RefreshCodeIssuesResolvedTarget: Sendable, Equatable {
    package let workspacePath: String
    package let workspaceRoot: String
    package let resolvedFilePath: String
    package let workspaceRelativePath: String
}

package struct RefreshCodeIssuesTargetResolution: Sendable, Equatable {
    package let target: RefreshCodeIssuesResolvedTarget?
    package let workspacePath: String?
    package let resolvedFilePath: String?
    package let failureReason: String?
}

package actor RefreshCodeIssuesTargetResolver {
    package typealias WindowsProvider = @Sendable (_ sessionID: String, _ eventLoop: EventLoop) async -> [XcodeWindowInfo]?

    private struct FileResolutionKey: Hashable {
        let workspacePath: String
        let filePath: String
    }

    private let fileManager = FileManager.default
    private var resolvedFilePathCache: [FileResolutionKey: String] = [:]

    package init() {}

    package func resolve(
        tabIdentifier: String?,
        filePath: String?,
        sessionID: String,
        eventLoop: EventLoop,
        windowsProvider: WindowsProvider
    ) async -> RefreshCodeIssuesTargetResolution {
        guard let tabIdentifier, tabIdentifier.isEmpty == false else {
            return RefreshCodeIssuesTargetResolution(
                target: nil,
                workspacePath: nil,
                resolvedFilePath: nil,
                failureReason: "missing tabIdentifier"
            )
        }
        guard let filePath, filePath.isEmpty == false else {
            return RefreshCodeIssuesTargetResolution(
                target: nil,
                workspacePath: nil,
                resolvedFilePath: nil,
                failureReason: "missing filePath"
            )
        }

        let workspacePath = await resolveWorkspacePath(
            tabIdentifier: tabIdentifier,
            sessionID: sessionID,
            eventLoop: eventLoop,
            windowsProvider: windowsProvider
        )
        guard let workspacePath else {
            return RefreshCodeIssuesTargetResolution(
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
            return RefreshCodeIssuesTargetResolution(
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
            return RefreshCodeIssuesTargetResolution(
                target: nil,
                workspacePath: workspacePath,
                resolvedFilePath: resolvedFilePath,
                failureReason: "resolved path outside workspace root"
            )
        }

        return RefreshCodeIssuesTargetResolution(
            target: RefreshCodeIssuesResolvedTarget(
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
        guard let requestedRelativeComponents = sanitizedRelativePathComponents(requestedFilePath),
            requestedRelativeComponents.isEmpty == false
        else {
            return nil
        }
        let key = FileResolutionKey(
            workspacePath: workspacePath,
            filePath: requestedFilePath
        )
        if let cached = resolvedFilePathCache[key] {
            return cached
        }

        let directURL = requestedRelativeComponents.reduce(
            URL(fileURLWithPath: workspaceRoot)
        ) { partialURL, component in
            partialURL.appendingPathComponent(component)
        }
        let directPath = directURL.standardizedFileURL.path
        if isPath(directPath, containedIn: workspaceRoot),
            fileManager.fileExists(atPath: directPath)
        {
            resolvedFilePathCache[key] = directPath
            return directPath
        }

        guard let requestedBasename = requestedRelativeComponents.last?.lowercased() else {
            return nil
        }
        let requestedComponents = requestedRelativeComponents.map { $0.lowercased() }
        let enumerator = fileManager.enumerator(
            at: URL(fileURLWithPath: workspaceRoot),
            includingPropertiesForKeys: nil
        )

        var bestPath: String?
        var bestScore = 0
        var ambiguous = false

        while let fileURL = enumerator?.nextObject() as? URL {
            guard fileURL.hasDirectoryPath == false else { continue }
            guard fileURL.lastPathComponent.lowercased() == requestedBasename else { continue }
            guard isPath(fileURL.path, containedIn: workspaceRoot) else { continue }

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
        resolvedFilePathCache[key] = bestPath
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
        if resolvedPath == resolvedRoot {
            return "."
        }
        let rootPrefix = resolvedRoot.hasSuffix("/") ? resolvedRoot : resolvedRoot + "/"
        guard resolvedPath.hasPrefix(rootPrefix) else {
            return nil
        }
        return String(resolvedPath.dropFirst(rootPrefix.count))
    }

    private func resolveWorkspacePath(
        tabIdentifier: String,
        sessionID: String,
        eventLoop: EventLoop,
        windowsProvider: WindowsProvider
    ) async -> String? {
        guard let windows = await windowsProvider(sessionID, eventLoop) else {
            return nil
        }
        return windows.first(where: { $0.tabIdentifier == tabIdentifier })?.workspacePath
    }

    private func normalizedPathComponents(_ path: String) -> [String] {
        URL(fileURLWithPath: path).pathComponents
            .filter { $0 != "/" && $0 != "." }
            .map { $0.lowercased() }
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
