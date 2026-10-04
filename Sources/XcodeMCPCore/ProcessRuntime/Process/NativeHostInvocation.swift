import Foundation

package enum NativeHostInvocation {
    package static let bundleName = "XcodeMCPNativeHost.app"
    package static let executableName = "xcode-mcp-native-host"

    package static func resolve(
        bundleURL: URL? = nil,
        developerDirectoryURL: URL? = nil,
        guiPID: Int32? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        executableURL: URL? = Bundle.main.executableURL,
        fileSystem: FileSystemClient = .liveValue
    ) throws -> MCPBridgeInvocation {
        let executable: URL
        if let bundleURL {
            executable = try resolveExecutable(in: bundleURL, fileSystem: fileSystem)
        } else if let path = environment["XCODE_MCP_NATIVE_HOST_BUNDLE"] {
            executable = try resolveExecutable(in: URL(fileURLWithPath: path), fileSystem: fileSystem)
        } else {
            var candidates: [URL] = []
            if let executableURL {
                candidates.append(executableURL.resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent(bundleName))
            }
            for directory in (environment["PATH"] ?? "").split(separator: ":") {
                let directoryURL = URL(fileURLWithPath: String(directory), isDirectory: true)
                candidates.append(directoryURL.appendingPathComponent(bundleName))
                let serverURL = directoryURL.appendingPathComponent("xcode-mcp-proxy-server").resolvingSymlinksInPath()
                candidates.append(serverURL.deletingLastPathComponent().appendingPathComponent(bundleName))
                let linkedExecutable = directoryURL.appendingPathComponent(executableName).resolvingSymlinksInPath()
                if linkedExecutable.deletingLastPathComponent().lastPathComponent == "MacOS" {
                    candidates.append(linkedExecutable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent())
                }
            }
            guard let bundle = candidates.first(where: {
                fileSystem.isExecutableFile($0.appendingPathComponent("Contents/MacOS/\(executableName)").path)
            }) else {
                throw MCPBridgeRuntimeError.transportUnavailable("Cannot find \(bundleName). Install XcodeMCPKit or supply nativeHostBundleURL / XCODE_MCP_NATIVE_HOST_BUNDLE.")
            }
            executable = try resolveExecutable(in: bundle, fileSystem: fileSystem)
        }
        var arguments: [String] = []
        if let developerDirectoryURL { arguments += ["--developer-dir", developerDirectoryURL.path] }
        if let guiPID { arguments += ["--gui-pid", String(guiPID)] }
        return MCPBridgeInvocation(command: executable.path, arguments: arguments)
    }

    private static func resolveExecutable(in bundleURL: URL, fileSystem: FileSystemClient) throws -> URL {
        let executable = bundleURL.standardizedFileURL.resolvingSymlinksInPath()
            .appendingPathComponent("Contents/MacOS/\(executableName)")
        guard fileSystem.isExecutableFile(executable.path) else {
            throw MCPBridgeRuntimeError.transportUnavailable("Native helper executable is unavailable: \(executable.path)")
        }
        return executable
    }
}
