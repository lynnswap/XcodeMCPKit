import Foundation

package enum RefreshCodeIssuesPathMatcher {
    package static func matches(
        issuePath: String,
        resolvedFilePath: String,
        caseSensitiveFileSystemOverride: Bool? = nil
    ) -> Bool {
        let normalizedIssuePath = normalizedPath(issuePath)
        let normalizedResolvedFilePath = normalizedPath(resolvedFilePath)

        guard normalizedIssuePath.isEmpty == false, normalizedResolvedFilePath.isEmpty == false
        else {
            return false
        }
        if normalizedIssuePath == normalizedResolvedFilePath {
            return true
        }
        if fileIdentifiersMatch(
            lhs: normalizedIssuePath,
            rhs: normalizedResolvedFilePath
        ) {
            return true
        }
        guard
            isCaseSensitiveFileSystem(
                atPath: normalizedResolvedFilePath,
                override: caseSensitiveFileSystemOverride
            ) == false
        else {
            return false
        }

        return normalizedIssuePath.compare(
            normalizedResolvedFilePath,
            options: [.caseInsensitive, .literal]
        ) == .orderedSame
    }

    package static func normalizedPath(_ path: String) -> String {
        let symlinkResolvedPath = (path as NSString).resolvingSymlinksInPath
        return URL(fileURLWithPath: symlinkResolvedPath).standardizedFileURL.path
    }

    private static func fileIdentifiersMatch(lhs: String, rhs: String) -> Bool {
        guard
            let lhsIdentifier = fileIdentifier(forPath: lhs),
            let rhsIdentifier = fileIdentifier(forPath: rhs)
        else {
            return false
        }
        return lhsIdentifier.isEqual(rhsIdentifier)
    }

    private static func fileIdentifier(forPath path: String) -> NSObject? {
        let url = URL(fileURLWithPath: path)
        guard
            let resourceValues = try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]),
            let identifier = resourceValues.fileResourceIdentifier as? NSObject
        else {
            return nil
        }
        return identifier
    }

    private static func isCaseSensitiveFileSystem(
        atPath path: String,
        override: Bool?
    ) -> Bool {
        if let override {
            return override
        }
        guard
            let existingURL = existingURL(forPath: path),
            let resourceValues = try? existingURL.resourceValues(
                forKeys: [.volumeSupportsCaseSensitiveNamesKey]
            ),
            let supportsCaseSensitiveNames = resourceValues.volumeSupportsCaseSensitiveNames
        else {
            return true
        }
        return supportsCaseSensitiveNames
    }

    private static func existingURL(forPath path: String) -> URL? {
        let fileManager = FileManager.default
        var currentURL = URL(fileURLWithPath: path)

        while true {
            if fileManager.fileExists(atPath: currentURL.path) {
                return currentURL
            }
            let parentURL = currentURL.deletingLastPathComponent()
            if parentURL.path == currentURL.path {
                return nil
            }
            currentURL = parentURL
        }
    }
}
