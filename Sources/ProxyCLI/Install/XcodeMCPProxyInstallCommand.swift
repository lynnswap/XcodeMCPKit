import Foundation
import ProxyCLICommon
import XcodeMCPProxyKit

package struct XcodeMCPProxyInstallCommand {
    package typealias Options = XcodeMCPProxyInstaller.Configuration

    package typealias Error = XcodeMCPProxyInstaller.Error

    package struct Dependencies {
        package typealias Launch = (
            _ args: [String],
            _ environment: [String: String],
            _ stdout: @escaping (String) -> Void,
            _ stderr: @escaping (String) -> Void
        ) -> Int32

        package var stdout: (String) -> Void
        package var stderr: (String) -> Void
        package var launch: Launch

        package init(
            stdout: @escaping (String) -> Void,
            stderr: @escaping (String) -> Void,
            launcher: XcodeMCPProxyInstaller.Launcher
        ) {
            self.stdout = stdout
            self.stderr = stderr
            self.launch = { args, environment, stdout, stderr in
                launcher.run(
                    arguments: args,
                    environment: environment,
                    stdout: stdout,
                    stderr: stderr
                )
            }
        }

        package init(
            stdout: @escaping (String) -> Void,
            stderr: @escaping (String) -> Void,
            launch: @escaping Launch
        ) {
            self.stdout = stdout
            self.stderr = stderr
            self.launch = launch
        }

        package init(
            stdout: @escaping (String) -> Void,
            stderr: @escaping (String) -> Void,
            executableURL: @escaping () -> URL?,
            install: @escaping (
                XcodeMCPProxyInstaller.Configuration,
                URL,
                (String) -> Void
            ) throws -> Void
        ) {
            let launcher = XcodeMCPProxyInstaller.Launcher(
                dependencies: .init(
                    executableURL: executableURL,
                    install: install
                )
            )
            self.init(stdout: stdout, stderr: stderr, launcher: launcher)
        }

        package static var live: Self {
            let launcher = XcodeMCPProxyInstaller.Launcher()
            return Self(
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

    package func run(args: [String], environment: [String: String]) -> Int32 {
        dependencies.launch(args, environment, dependencies.stdout, dependencies.stderr)
    }
}
