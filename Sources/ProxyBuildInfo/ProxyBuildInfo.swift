import Foundation

package enum ProxyBuildInfo {
    package static var version: String {
        ProxyBuildGeneratedInfo.version
    }

    package static func versionLine(
        arguments: [String],
        defaultExecutableName: String
    ) -> String {
        "\(executableName(arguments: arguments, defaultExecutableName: defaultExecutableName)) \(version)"
    }

    private static func executableName(
        arguments: [String],
        defaultExecutableName: String
    ) -> String {
        guard let rawExecutable = arguments.first, !rawExecutable.isEmpty else {
            return defaultExecutableName
        }

        let executableName = URL(fileURLWithPath: rawExecutable).lastPathComponent
        return executableName.isEmpty ? defaultExecutableName : executableName
    }
}
