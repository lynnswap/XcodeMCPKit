import Foundation

package struct ExecutableLookupClient: DependencyClient {
    package var resolveExecutablePath: @Sendable (_ command: String) -> String?
    package var resolveXcrunToolPath: @Sendable (
        _ xcrunCommandPath: String,
        _ toolName: String,
        _ preToolArguments: [String]
    ) -> String?

    package init(
        resolveExecutablePath: @escaping @Sendable (_ command: String) -> String?,
        resolveXcrunToolPath: @escaping @Sendable (
            _ xcrunCommandPath: String,
            _ toolName: String,
            _ preToolArguments: [String]
        ) -> String?
    ) {
        self.resolveExecutablePath = resolveExecutablePath
        self.resolveXcrunToolPath = resolveXcrunToolPath
    }

    package static let liveValue = live()

    package static let testValue = Self(
        resolveExecutablePath: { _ in nil },
        resolveXcrunToolPath: { _, _, _ in nil }
    )

    package static func live(
        environment: @escaping @Sendable () -> [String: String] = {
            ProcessInfo.processInfo.environment
        },
        fileSystem: FileSystemClient = .liveValue,
        runCommand: @escaping @Sendable (_ executablePath: String, _ arguments: [String]) -> String? =
            defaultRunCommand
    ) -> Self {
        Self(
            resolveExecutablePath: { command in
                resolvedExecutablePath(
                    for: command,
                    environment: environment(),
                    fileSystem: fileSystem
                )
            },
            resolveXcrunToolPath: { xcrunCommandPath, toolName, preToolArguments in
                resolvedXcrunToolPath(
                    xcrunCommandPath: xcrunCommandPath,
                    toolName: toolName,
                    preToolArguments: preToolArguments,
                    environment: environment(),
                    fileSystem: fileSystem,
                    runCommand: runCommand
                )
            }
        )
    }

    private static func resolvedExecutablePath(
        for command: String,
        environment: [String: String],
        fileSystem: FileSystemClient
    ) -> String? {
        guard command.isEmpty == false else {
            return nil
        }

        if command.contains("/") {
            return URL(fileURLWithPath: command).standardizedFileURL.path
        }

        let pathValue =
            environment["PATH"]
            ?? "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

        for directory in pathValue.split(separator: ":").map(String.init) where directory.isEmpty == false {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(command).path
            if fileSystem.isExecutableFile(candidate) {
                return candidate
            }
        }

        return nil
    }

    private static func resolvedXcrunToolPath(
        xcrunCommandPath: String,
        toolName: String,
        preToolArguments: [String],
        environment: [String: String],
        fileSystem: FileSystemClient,
        runCommand: @escaping @Sendable (_ executablePath: String, _ arguments: [String]) -> String?
    ) -> String? {
        let executablePath: String
        if xcrunCommandPath.contains("/") {
            executablePath = URL(fileURLWithPath: xcrunCommandPath).standardizedFileURL.path
        } else if let resolvedCommandPath = resolvedExecutablePath(
            for: xcrunCommandPath,
            environment: environment,
            fileSystem: fileSystem
        ) {
            executablePath = resolvedCommandPath
        } else {
            executablePath = MCPBridgeInvocation.xcrunCommand
        }

        guard let output = runCommand(executablePath, preToolArguments + ["--find", toolName])?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              output.isEmpty == false else {
            return nil
        }
        return output
    }

    private static func defaultRunCommand(
        executablePath: String,
        arguments: [String]
    ) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else {
            return nil
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}
