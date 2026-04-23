import Foundation
import XcodeMCPProxy

package struct ProxyServerCommandRuntime {
    private let dependencies: XcodeMCPProxyServerCommand.Dependencies

    package init(dependencies: XcodeMCPProxyServerCommand.Dependencies) {
        self.dependencies = dependencies
    }

    package func execute(args: [String], environment: [String: String]) async -> Int32 {
        do {
            var options = try XcodeMCPProxyServerCommand.parseOptions(args: args)
            if options.showHelp {
                dependencies.stdout(XcodeMCPProxyServerCommand.serverUsage())
                return 0
            }
            if options.showVersion {
                dependencies.stdout(
                    ProxyBuildInfo.versionLine(
                        arguments: args,
                        defaultExecutableName: "xcode-mcp-proxy-server"
                    )
                )
                return 0
            }
            try XcodeMCPProxyServerCommand.applyDefaults(from: environment, to: &options)

            let isDryRun = options.dryRun || XcodeMCPProxyServerCommand.isTruthy(environment["DRY_RUN"])
            if isDryRun {
                let command = (["xcode-mcp-proxy-server"] + options.forwardedArgs)
                    .joined(separator: " ")
                dependencies.stdout(command)
                return 0
            }

            let proxyArgs = ["xcode-mcp-proxy"] + options.forwardedArgs
            let config = try CLIParser.parse(args: proxyArgs, environment: environment)
            if options.forceRestart, config.listenPort > 0 {
                _ = dependencies.terminateExistingServer(config.listenHost, config.listenPort)
            }

            do {
                let server = dependencies.makeServer(config)
                _ = try server.startAndWriteDiscovery()
                try await server.wait()
                return 0
            } catch {
                if config.listenPort > 0, dependencies.isAddressAlreadyInUse(error) {
                    let message = XcodeMCPProxyServerCommand.portInUseMessage(
                        host: config.listenHost,
                        port: config.listenPort,
                        pids: dependencies.detectExistingProxyServerPIDs(
                            config.listenHost,
                            config.listenPort
                        )
                    )
                    dependencies.stderr(message)
                    return 1
                }
                throw error
            }
        } catch let error as ProxyServerCommandError {
            dependencies.stderr("error: \(error.description)")
            dependencies.stderr("run with --help for usage")
            return 1
        } catch let error as CLIError {
            dependencies.stderr(error.description)
            dependencies.stderr(XcodeMCPProxyServerCommand.serverUsage())
            return 1
        } catch {
            dependencies.stderr("error: \(error)")
            return 1
        }
    }
}
