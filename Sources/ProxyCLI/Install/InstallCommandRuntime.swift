import Foundation
import XcodeMCPProxy

package struct InstallCommandRuntime {
    private let dependencies: XcodeMCPProxyInstallCommand.Dependencies

    package init(dependencies: XcodeMCPProxyInstallCommand.Dependencies) {
        self.dependencies = dependencies
    }

    package func execute(args: [String], environment: [String: String]) -> Int32 {
        let invocation = XcodeMCPProxyInstallCommand.scanInvocation(args)
        if invocation.showHelp {
            dependencies.stdout(XcodeMCPProxyInstallCommand.usage())
            return 0
        }
        if invocation.showVersion {
            dependencies.stdout(
                ProxyBuildInfo.versionLine(
                    arguments: args,
                    defaultExecutableName: "xcode-mcp-proxy-install"
                )
            )
            return 0
        }

        do {
            let options = try XcodeMCPProxyInstallCommand.parseOptions(args, environment: environment)
            if options.showHelp {
                dependencies.stdout(XcodeMCPProxyInstallCommand.usage())
                return 0
            }
            guard let executableURL = dependencies.executableURL() else {
                throw InstallCommandError.message("failed to locate installer executable")
            }
            try XcodeMCPProxyInstallCommand.install(
                options: options,
                executableURL: executableURL,
                buildProducts: dependencies.buildProducts,
                stdout: dependencies.stdout
            )
            return 0
        } catch let error as InstallCommandError {
            dependencies.stderr("error: \(error.description)")
            dependencies.stderr("run with --help for usage")
            return 1
        } catch {
            dependencies.stderr("error: \(error)")
            return 1
        }
    }
}
