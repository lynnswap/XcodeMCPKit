extension XcodeMCPProxyServer {
    package protocol LaunchServer {
        func startAndWriteDiscovery() throws -> XcodeMCPProxyServer.Endpoint
        func wait() async throws
    }

    package struct Launcher {
        package struct Dependencies {
            package var makeServer: (XcodeMCPProxyServer.Configuration) -> any LaunchServer
            package var isAddressAlreadyInUse: (Swift.Error) -> Bool
            package var forceRestartExistingServer: (_ host: String, _ port: Int, _ stderr: (String) -> Void) -> Bool
            package var detectExistingServerProcessIDs: (_ host: String, _ port: Int) -> [Int]

            package init(
                makeServer: @escaping (XcodeMCPProxyServer.Configuration) -> any LaunchServer,
                isAddressAlreadyInUse: @escaping (Swift.Error) -> Bool,
                forceRestartExistingServer: @escaping (
                    _ host: String,
                    _ port: Int,
                    _ stderr: (String) -> Void
                ) -> Bool = { _, _, _ in false },
                detectExistingServerProcessIDs: @escaping (_ host: String, _ port: Int) -> [Int] = { _, _ in [] }
            ) {
                self.makeServer = makeServer
                self.isAddressAlreadyInUse = isAddressAlreadyInUse
                self.forceRestartExistingServer = forceRestartExistingServer
                self.detectExistingServerProcessIDs = detectExistingServerProcessIDs
            }

            package static var live: Self {
                let existingServerController = XcodeMCPProxyServer.ExistingServerController.liveValue
                return Self(
                    makeServer: { config in
                        XcodeMCPProxyServer(config: config)
                    },
                    isAddressAlreadyInUse: XcodeMCPProxyServer.isAddressAlreadyInUse,
                    forceRestartExistingServer: { host, port, stderr in
                        existingServerController.terminateExistingServer(host, port, stderr)
                    },
                    detectExistingServerProcessIDs: { host, port in
                        existingServerController.detectExistingServerProcessIDs(host, port)
                    }
                )
            }
        }

        private let dependencies: Dependencies

        package init(dependencies: Dependencies = .live) {
            self.dependencies = dependencies
        }

        package func run(
            arguments: [String],
            environment: [String: String],
            stdout: (String) -> Void,
            stderr: (String) -> Void
        ) async -> Int32 {
            do {
                let plan = try XcodeMCPProxyServer.resolveLaunchPlan(
                    arguments: arguments,
                    environment: environment
                )

                switch plan.action {
                case .showHelp:
                    stdout(plan.usage)
                    return 0
                case .showVersion:
                    stdout(plan.versionLine)
                    return 0
                case .dryRun:
                    stdout(plan.resolvedDryRunCommandLine ?? "")
                    return 0
                case .start:
                    return try await startServer(from: plan, stderr: stderr)
                }
            } catch let error as XcodeMCPProxyServer.LaunchResolutionError {
                switch error.presentation {
                case .conciseUsageHint:
                    stderr("error: \(error.description)")
                    stderr("run with --help for usage")
                case .fullUsage:
                    stderr(error.description)
                    stderr(XcodeMCPProxyServer.serverUsage)
                }
                return 1
            } catch {
                stderr("error: \(error)")
                return 1
            }
        }

        private func startServer(
            from plan: XcodeMCPProxyServer.LaunchPlan,
            stderr: (String) -> Void
        ) async throws -> Int32 {
            guard let serverConfig = plan.configuration else {
                throw XcodeMCPProxyServer.LaunchResolutionError(
                    message: "server launch plan is missing configuration",
                    presentation: .conciseUsageHint
                )
            }

            if plan.options.forceRestart, serverConfig.bind.port > 0 {
                _ = dependencies.forceRestartExistingServer(
                    serverConfig.bind.host,
                    serverConfig.bind.port,
                    stderr
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
                        processIdentifiers: dependencies.detectExistingServerProcessIDs(
                            serverConfig.bind.host,
                            serverConfig.bind.port
                        )
                    )
                    stderr(diagnostic.description)
                    return 1
                }
                throw error
            }
        }
    }
}

extension XcodeMCPProxyServer: XcodeMCPProxyServer.LaunchServer {}
