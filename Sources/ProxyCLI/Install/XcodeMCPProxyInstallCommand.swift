import Foundation
import ProxyCLICommon
import XcodeMCPProxyKit

package struct XcodeMCPProxyInstallCommand {
    package typealias Options = XcodeMCPProxyInstaller.Configuration

    package struct Invocation {
        package var showHelp = false
        package var showVersion = false
    }

    package typealias Error = XcodeMCPProxyInstaller.Error

    package struct Dependencies {
        package var stdout: (String) -> Void
        package var stderr: (String) -> Void
        package var executableURL: () -> URL?
        package var install:
            (XcodeMCPProxyInstaller.Configuration, URL, @escaping (String) -> Void) throws -> Void

        package init(
            stdout: @escaping (String) -> Void,
            stderr: @escaping (String) -> Void,
            executableURL: @escaping () -> URL?,
            install: @escaping (
                XcodeMCPProxyInstaller.Configuration,
                URL,
                @escaping (String) -> Void
            ) throws -> Void
        ) {
            self.stdout = stdout
            self.stderr = stderr
            self.executableURL = executableURL
            self.install = install
        }

        package static var live: Self {
            Self(
                stdout: { print($0) },
                stderr: { FileHandle.writeLine($0, to: .standardError) },
                executableURL: { Bundle.main.executableURL },
                install: { configuration, executableURL, stdout in
                    try XcodeMCPProxyInstaller(configuration: configuration).install(
                        executableURL: executableURL,
                        stdout: stdout
                    )
                }
            )
        }
    }

    private let dependencies: Dependencies

    package init(dependencies: Dependencies = .live) {
        self.dependencies = dependencies
    }

    package func run(args: [String], environment: [String: String]) -> Int32 {
        XcodeMCPProxyInstallCommand.Runtime(dependencies: dependencies).execute(
            args: args,
            environment: environment
        )
    }
}
