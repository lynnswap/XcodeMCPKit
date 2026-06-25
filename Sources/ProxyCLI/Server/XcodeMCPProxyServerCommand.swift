import Foundation
import ProxyCLICommon
import XcodeMCPProxyKit

package protocol ProxyServerCommandServer {
    func startAndWriteDiscovery() throws -> XcodeMCPProxyServer.Endpoint
    func wait() async throws
}

extension XcodeMCPProxyServer: ProxyServerCommandServer {}

package struct XcodeMCPProxyServerCommand {
    package struct Dependencies {
        package var bootstrapLogging: ([String: String]) -> Void
        package var stdout: (String) -> Void
        package var stderr: (String) -> Void
        package var makeServer: (XcodeMCPProxyServer.Configuration) -> any ProxyServerCommandServer
        package var isAddressAlreadyInUse: (Swift.Error) -> Bool
        package var existingServerController: XcodeMCPProxyServer.ExistingServerController

        package init(
            bootstrapLogging: @escaping ([String: String]) -> Void,
            stdout: @escaping (String) -> Void,
            stderr: @escaping (String) -> Void,
            makeServer: @escaping (XcodeMCPProxyServer.Configuration) -> any ProxyServerCommandServer,
            isAddressAlreadyInUse: @escaping (Swift.Error) -> Bool,
            existingServerController: XcodeMCPProxyServer.ExistingServerController = .liveValue
        ) {
            self.bootstrapLogging = bootstrapLogging
            self.stdout = stdout
            self.stderr = stderr
            self.makeServer = makeServer
            self.isAddressAlreadyInUse = isAddressAlreadyInUse
            self.existingServerController = existingServerController
        }

        package init(
            bootstrapLogging: @escaping ([String: String]) -> Void,
            stdout: @escaping (String) -> Void,
            stderr: @escaping (String) -> Void,
            terminateExistingServer: @escaping @Sendable (String, Int) -> Bool,
            makeServer: @escaping (XcodeMCPProxyServer.Configuration) -> any ProxyServerCommandServer,
            isAddressAlreadyInUse: @escaping (Swift.Error) -> Bool,
            detectExistingProxyServerPIDs: @escaping @Sendable (String, Int) -> [Int]
        ) {
            self.init(
                bootstrapLogging: bootstrapLogging,
                stdout: stdout,
                stderr: stderr,
                makeServer: makeServer,
                isAddressAlreadyInUse: isAddressAlreadyInUse,
                existingServerController: XcodeMCPProxyServer.ExistingServerController(
                    terminateExistingServer: { host, port, _ in
                        terminateExistingServer(host, port)
                    },
                    detectExistingServerProcessIDs: detectExistingProxyServerPIDs
                )
            )
        }

        package static var live: Self {
            Self(
                bootstrapLogging: XcodeMCPProxyServer.bootstrapLogging(environment:),
                stdout: { print($0) },
                stderr: { FileHandle.writeLine($0, to: .standardError) },
                makeServer: { config in
                    XcodeMCPProxyServer(config: config)
                },
                isAddressAlreadyInUse: XcodeMCPProxyServer.isAddressAlreadyInUse,
                existingServerController: .liveValue
            )
        }
    }

    private let dependencies: Dependencies

    package init(dependencies: Dependencies = .live) {
        self.dependencies = dependencies
    }

    package func run(args: [String], environment: [String: String]) async -> Int32 {
        dependencies.bootstrapLogging(environment)
        return await XcodeMCPProxyServerCommand.Runtime(dependencies: dependencies).execute(
            args: args,
            environment: environment
        )
    }
}
