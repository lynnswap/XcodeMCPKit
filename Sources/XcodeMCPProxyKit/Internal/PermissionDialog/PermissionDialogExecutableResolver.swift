import Foundation
import XcodeMCPCore

enum PermissionDialogExecutableResolver {
    static func executableCandidates(
        bundleURL: URL?,
        developerDirectoryURL: URL?,
        fileSystem: FileSystemClient = .liveValue
    ) -> [String] {
        guard let invocation = try? NativeHostInvocation.resolve(
            bundleURL: bundleURL,
            developerDirectoryURL: developerDirectoryURL,
            fileSystem: fileSystem
        ) else { return [] }
        return [invocation.command]
    }
}
