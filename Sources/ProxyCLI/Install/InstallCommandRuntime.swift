import Foundation
import ProxyBuildInfo
import ProxyCLICommon

extension XcodeMCPProxyInstallCommand {
    package struct Runtime {
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
            guard let executableURL = dependencies.executableURL() else {
                throw XcodeMCPProxyInstallCommand.Error.message("failed to locate installer executable")
            }
            try dependencies.install(options, executableURL, dependencies.stdout)
            return 0
        } catch let error as XcodeMCPProxyInstallCommand.Error {
            dependencies.stderr("error: \(error.description)")
            dependencies.stderr("run with --help for usage")
            return 1
        } catch {
            dependencies.stderr("error: \(error)")
            return 1
        }
    }
    }
}
