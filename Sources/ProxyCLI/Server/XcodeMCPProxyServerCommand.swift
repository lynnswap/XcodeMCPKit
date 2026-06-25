import Foundation
import ProxyCLICommon
import XcodeMCPProxyKit

package struct XcodeMCPProxyServerCommand {
    package struct Dependencies {
        package typealias Launch = (
            _ args: [String],
            _ environment: [String: String],
            _ stdout: @escaping (String) -> Void,
            _ stderr: @escaping (String) -> Void
        ) async -> Int32

        package var bootstrapLogging: ([String: String]) -> Void
        package var stdout: (String) -> Void
        package var stderr: (String) -> Void
        package var launch: Launch

        package init(
            bootstrapLogging: @escaping ([String: String]) -> Void,
            stdout: @escaping (String) -> Void,
            stderr: @escaping (String) -> Void,
            launcher: XcodeMCPProxyServer.Launcher
        ) {
            self.bootstrapLogging = bootstrapLogging
            self.stdout = stdout
            self.stderr = stderr
            self.launch = { args, environment, stdout, stderr in
                await launcher.run(
                    arguments: args,
                    environment: environment,
                    stdout: stdout,
                    stderr: stderr
                )
            }
        }

        package init(
            bootstrapLogging: @escaping ([String: String]) -> Void,
            stdout: @escaping (String) -> Void,
            stderr: @escaping (String) -> Void,
            launch: @escaping Launch
        ) {
            self.bootstrapLogging = bootstrapLogging
            self.stdout = stdout
            self.stderr = stderr
            self.launch = launch
        }

        package static var live: Self {
            let launcher = XcodeMCPProxyServer.Launcher()
            return Self(
                bootstrapLogging: XcodeMCPProxyServer.bootstrapLogging(environment:),
                stdout: { print($0) },
                stderr: { FileHandle.writeLine($0, to: .standardError) },
                launcher: launcher
            )
        }
    }

    private let dependencies: Dependencies

    package init(dependencies: Dependencies = .live) {
        self.dependencies = dependencies
    }

    package func run(args: [String], environment: [String: String]) async -> Int32 {
        dependencies.bootstrapLogging(environment)
        return await XcodeMCPProxyServerCommand.Runtime(dependencies: dependencies).execute(
            args: args,
            environment: environment
        )
    }
}
