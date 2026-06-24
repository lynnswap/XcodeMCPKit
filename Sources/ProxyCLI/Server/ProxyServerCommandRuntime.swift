import Foundation
import ProxyBuildInfo
import ProxyCLICommon
import ProxyCore
import XcodeMCPProxyKit

extension XcodeMCPProxyServerCommand {
    package struct Runtime {
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

            let proxyArgs = ["xcode-mcp-proxy"] + options.forwardedArgs
            let config = try CLIParser.parse(args: proxyArgs, environment: environment)
            try config.validateModernProtocolConfiguration()

            let isDryRun = options.dryRun || XcodeMCPProxyServerCommand.isTruthy(environment["DRY_RUN"])
            if isDryRun {
                dependencies.stdout(
                    XcodeMCPProxyServerCommand.dryRunCommandLine(options: options, config: config)
                )
                return 0
            }
            if options.forceRestart, config.listenPort > 0 {
                _ = dependencies.existingProxyServerClient.terminateExistingServer(
                    config.listenHost,
                    config.listenPort,
                    dependencies.stderr
                )
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
                        pids: dependencies.existingProxyServerClient.detectExistingProxyServerPIDs(
                            config.listenHost,
                            config.listenPort
                        )
                    )
                    dependencies.stderr(message)
                    return 1
                }
                throw error
            }
        } catch let error as XcodeMCPProxyServerCommand.Error {
            dependencies.stderr("error: \(error.description)")
            dependencies.stderr("run with --help for usage")
            return 1
        } catch let error as CLIError {
            dependencies.stderr(error.description)
            dependencies.stderr(XcodeMCPProxyServerCommand.serverUsage())
            return 1
        } catch let error as ProxyConfig.ValidationError {
            dependencies.stderr(error.description)
            dependencies.stderr(XcodeMCPProxyServerCommand.serverUsage())
            return 1
        } catch {
            dependencies.stderr("error: \(error)")
            return 1
        }
    }
    }
}
