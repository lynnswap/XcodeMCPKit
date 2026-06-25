import XcodeMCPProxyKit

extension XcodeMCPProxyServerCommand {
    package struct Runtime {
        private let dependencies: XcodeMCPProxyServerCommand.Dependencies

        package init(dependencies: XcodeMCPProxyServerCommand.Dependencies) {
            self.dependencies = dependencies
        }

        package func execute(args: [String], environment: [String: String]) async -> Int32 {
            do {
                let plan = try XcodeMCPProxyServer.resolveLaunchPlan(
                    arguments: args,
                    environment: environment
                )

                switch plan.action {
                case .showHelp:
                    dependencies.stdout(plan.usage)
                    return 0
                case .showVersion:
                    dependencies.stdout(plan.versionLine)
                    return 0
                case .dryRun:
                    dependencies.stdout(plan.resolvedDryRunCommandLine ?? "")
                    return 0
                case .start:
                    guard let serverConfig = plan.configuration else {
                        throw XcodeMCPProxyServer.LaunchResolutionError(
                            message: "server launch plan is missing configuration",
                            presentation: .conciseUsageHint
                        )
                    }
                    if plan.options.forceRestart, serverConfig.bind.port > 0 {
                        _ = dependencies.existingServerController.terminateExistingServer(
                            serverConfig.bind.host,
                            serverConfig.bind.port,
                            dependencies.stderr
                        )
                    }

                    do {
                        let server = dependencies.makeServer(serverConfig)
                        _ = try server.startAndWriteDiscovery()
                        try await server.wait()
                        return 0
                    } catch {
                        if serverConfig.bind.port > 0, dependencies.isAddressAlreadyInUse(error) {
                            let diagnostic = XcodeMCPProxyServer.PortInUseError(
                                host: serverConfig.bind.host,
                                port: serverConfig.bind.port,
                                processIdentifiers: dependencies.existingServerController.detectExistingServerProcessIDs(
                                    serverConfig.bind.host,
                                    serverConfig.bind.port
                                )
                            )
                            dependencies.stderr(diagnostic.description)
                            return 1
                        }
                        throw error
                    }
                }
            } catch let error as XcodeMCPProxyServer.LaunchResolutionError {
                switch error.presentation {
                case .conciseUsageHint:
                    dependencies.stderr("error: \(error.description)")
                    dependencies.stderr("run with --help for usage")
                case .fullUsage:
                    dependencies.stderr(error.description)
                    dependencies.stderr(XcodeMCPProxyServer.serverUsage)
                }
                return 1
            } catch {
                dependencies.stderr("error: \(error)")
                return 1
            }
        }
    }
}
