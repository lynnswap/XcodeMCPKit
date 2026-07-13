extension XcodeMCPProxyServer {
    package protocol LaunchServer: Sendable {
        func start() async throws -> XcodeMCPProxyServer.Endpoint
        func waitUntilShutdown() async throws
        func shutdown() async throws
    }

    package struct Launcher {
        package struct Dependencies {
            package var makeServer: (PreparedConfiguration) -> any LaunchServer
            package var isAddressAlreadyInUse: (Swift.Error) -> Bool
            package var forceRestartExistingServer: (_ host: String, _ port: Int, _ stderr: (String) -> Void) -> Bool
            package var detectExistingServerProcessIDs: (_ host: String, _ port: Int) -> [Int]

            package init(
                makeServer: @escaping (PreparedConfiguration) -> any LaunchServer,
                isAddressAlreadyInUse: @escaping (Swift.Error) -> Bool,
                forceRestartExistingServer:
                    @escaping (
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
                    makeServer: { preparedConfiguration in
                        XcodeMCPProxyServer(
                            preparedConfiguration: preparedConfiguration,
                            dependencies: .live
                        )
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
                let action = try XcodeMCPProxyServer.resolveLaunchAction(
                    arguments: arguments,
                    environment: environment
                )

                switch action {
                case .display(let message):
                    stdout(message)
                    return 0
                case .dryRun(let commandLine):
                    stdout(commandLine)
                    return 0
                case .start(let preparedConfiguration, let forceRestart):
                    return try await startServer(
                        preparedConfiguration: preparedConfiguration,
                        forceRestart: forceRestart,
                        stderr: stderr
                    )
                }
            } catch let error as CLICommandError {
                stderr(error.description)
                return error.exitCode
            } catch {
                stderr("error: \(error)")
                return 1
            }
        }

        private func startServer(
            preparedConfiguration: PreparedConfiguration,
            forceRestart: Bool,
            stderr: (String) -> Void
        ) async throws -> Int32 {
            let serverConfig = preparedConfiguration.configuration
            if forceRestart, serverConfig.bindAddress.port > 0 {
                _ = dependencies.forceRestartExistingServer(
                    serverConfig.bindAddress.host,
                    serverConfig.bindAddress.port,
                    stderr
                )
            }

            do {
                let server = dependencies.makeServer(preparedConfiguration)
                _ = try await server.start()
                do {
                    try await server.waitUntilShutdown()
                    try await server.shutdown()
                } catch {
                    try? await server.shutdown()
                    throw error
                }
                return 0
            } catch {
                if serverConfig.bindAddress.port > 0, dependencies.isAddressAlreadyInUse(error) {
                    let diagnostic = XcodeMCPProxyServer.PortInUseError(
                        host: serverConfig.bindAddress.host,
                        port: serverConfig.bindAddress.port,
                        processIdentifiers: dependencies.detectExistingServerProcessIDs(
                            serverConfig.bindAddress.host,
                            serverConfig.bindAddress.port
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
