import Darwin
import Dispatch
import Foundation
import Synchronization

extension XcodeMCPProxyServer {
    package protocol LaunchServer: Sendable {
        func start() async throws -> XcodeMCPProxyServer.Endpoint
        func waitUntilShutdown() async throws
        func shutdown() async throws
    }

    package struct Launcher {
        package struct Dependencies {
            package var makeServer: (XcodeMCPProxyServerConfiguration) -> any LaunchServer
            package var isAddressAlreadyInUse: (Swift.Error) -> Bool
            package var forceRestartExistingServer: (_ host: String, _ port: Int, _ stderr: (String) -> Void) -> Bool
            package var detectExistingServerProcessIDs: (_ host: String, _ port: Int) -> [Int]
            /// Calls `handler` when the process receives a termination signal, until the returned
            /// closure stops observing.
            package var observeTerminationSignals: (_ handler: @escaping @Sendable () -> Void) -> () -> Void

            package init(
                makeServer: @escaping (XcodeMCPProxyServerConfiguration) -> any LaunchServer,
                isAddressAlreadyInUse: @escaping (Swift.Error) -> Bool,
                forceRestartExistingServer:
                    @escaping (
                        _ host: String,
                        _ port: Int,
                        _ stderr: (String) -> Void
                    ) -> Bool = { _, _, _ in false },
                detectExistingServerProcessIDs: @escaping (_ host: String, _ port: Int) -> [Int] = { _, _ in [] },
                observeTerminationSignals: @escaping (_ handler: @escaping @Sendable () -> Void) -> () -> Void = { _ in {} }
            ) {
                self.makeServer = makeServer
                self.isAddressAlreadyInUse = isAddressAlreadyInUse
                self.forceRestartExistingServer = forceRestartExistingServer
                self.detectExistingServerProcessIDs = detectExistingServerProcessIDs
                self.observeTerminationSignals = observeTerminationSignals
            }

            package static var live: Self {
                let existingServerController = XcodeMCPProxyServer.ExistingServerController.liveValue
                return Self(
                    makeServer: { configuration in
                        XcodeMCPProxyServer(configuration: configuration)
                    },
                    isAddressAlreadyInUse: XcodeMCPProxyServer.isAddressAlreadyInUse,
                    forceRestartExistingServer: { host, port, stderr in
                        existingServerController.terminateExistingServer(host, port, stderr)
                    },
                    detectExistingServerProcessIDs: { host, port in
                        existingServerController.detectExistingServerProcessIDs(host, port)
                    },
                    observeTerminationSignals: TerminationSignals.observe
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
                case .start(let configuration, let forceRestart):
                    return try await startServer(
                        configuration: configuration,
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
            configuration: XcodeMCPProxyServerConfiguration,
            forceRestart: Bool,
            stderr: (String) -> Void
        ) async throws -> Int32 {
            if forceRestart, configuration.bindAddress.port > 0 {
                _ = dependencies.forceRestartExistingServer(
                    configuration.bindAddress.host,
                    configuration.bindAddress.port,
                    stderr
                )
            }

            let server = dependencies.makeServer(configuration)
            // A termination signal shuts the server down, also while it starts, which stops its host
            // processes and ends the wait.
            let signalled = Mutex(false)
            let stopObservingSignals = dependencies.observeTerminationSignals {
                signalled.withLock { $0 = true }
                Task { try? await server.shutdown() }
            }
            defer { stopObservingSignals() }
            let endpoint: Endpoint
            do {
                endpoint = try await server.start()
            } catch {
                // A startup that a signal stopped ends like a shutdown, unless its cleanup failed.
                if !(error is CleanupError), signalled.withLock({ $0 }) {
                    return 0
                }
                if !(error is CleanupError), configuration.bindAddress.port > 0,
                   dependencies.isAddressAlreadyInUse(error) {
                    let diagnostic = XcodeMCPProxyServer.PortInUseError(
                        host: configuration.bindAddress.host,
                        port: configuration.bindAddress.port,
                        processIdentifiers: dependencies.detectExistingServerProcessIDs(
                            configuration.bindAddress.host,
                            configuration.bindAddress.port
                        )
                    )
                    stderr(diagnostic.description)
                    return 1
                }
                throw error
            }

            do {
                try await server.waitUntilShutdown()
            } catch {
                let operationError = error
                do {
                    try await server.shutdown()
                } catch {
                    throw CleanupError(
                        operationError: operationError,
                        cleanupError: error,
                        endpoint: endpoint
                    )
                }
                throw operationError
            }
            try await server.shutdown()
            return 0
        }
    }
}

extension XcodeMCPProxyServer: XcodeMCPProxyServer.LaunchServer {}

/// Delivers `SIGINT` and `SIGTERM` to handlers instead of terminating the process. Observers in one
/// process share the dispositions, which are replaced while any observer is registered.
enum TerminationSignals {
    static let numbers = [SIGINT, SIGTERM]

    private struct Registry {
        var handlers: [UUID: @Sendable () -> Void] = [:]
        var received: UInt = 0
        var sources: [any DispatchSourceSignal] = []
        var previous: [(number: Int32, action: sigaction)] = []
    }

    private static let registry = Mutex(Registry())

    /// The first signal calls every registered handler. A later one terminates the process, so a
    /// shutdown that does not finish can still be interrupted. When the last observer stops, the
    /// previous dispositions are restored with their flags and masks.
    static func observe(_ handler: @escaping @Sendable () -> Void) -> () -> Void {
        let id = UUID()
        registry.withLock { registry in
            if registry.handlers.isEmpty { install(in: &registry) }
            registry.handlers[id] = handler
        }
        return {
            registry.withLock { registry in
                guard registry.handlers.removeValue(forKey: id) != nil, registry.handlers.isEmpty else { return }
                for source in registry.sources { source.cancel() }
                for var entry in registry.previous { sigaction(entry.number, &entry.action, nil) }
                registry = Registry()
            }
        }
    }

    private static func install(in registry: inout Registry) {
        for number in numbers {
            var ignore = sigaction()
            ignore.__sigaction_u.__sa_handler = SIG_IGN
            var action = sigaction()
            sigaction(number, &ignore, &action)
            registry.previous.append((number, action))
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { [weak source] in
                guard let source else { return }
                // A source reports signals that arrive together in one event.
                let (count, handlers) = Self.registry.withLock { registry in
                    registry.received += source.data
                    return (registry.received, Array(registry.handlers.values))
                }
                if count == 1 {
                    for handler in handlers { handler() }
                } else {
                    signal(number, SIG_DFL)
                    raise(number)
                }
            }
            source.resume()
            registry.sources.append(source)
        }
    }
}
