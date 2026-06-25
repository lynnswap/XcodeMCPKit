import ProxyCore
import ProxyProcessManagement

extension XcodeMCPProxyServer {
    /// High-level launcher dependency adapter.
    ///
    /// Low-level `lsof`/`ps`/signal mechanics are owned by
    /// `ProxyProcessManagement`; this type keeps the server launcher facade in
    /// `XcodeMCPProxyKit` without making process management part of its public
    /// responsibility.
    package struct ExistingServerController: DependencyClient {
        package var terminateExistingServer:
            @Sendable (_ host: String, _ port: Int, _ emitWarning: (String) -> Void) -> Bool
        package var detectExistingServerProcessIDs: @Sendable (_ host: String, _ port: Int) -> [Int]

        package init(
            terminateExistingServer: @escaping @Sendable (
                _ host: String,
                _ port: Int,
                _ emitWarning: (String) -> Void
            ) -> Bool,
            detectExistingServerProcessIDs: @escaping @Sendable (_ host: String, _ port: Int) -> [Int]
        ) {
            self.terminateExistingServer = terminateExistingServer
            self.detectExistingServerProcessIDs = detectExistingServerProcessIDs
        }

        package static let liveValue = live()

        package static let testValue = Self(
            terminateExistingServer: { _, _, _ in false },
            detectExistingServerProcessIDs: { _, _ in [] }
        )

        package static func live(
            processController: ExistingProxyServerProcessController = .liveValue
        ) -> Self {
            Self(
                terminateExistingServer: { host, port, emitWarning in
                    processController.terminateExistingServer(host, port, emitWarning)
                },
                detectExistingServerProcessIDs: { host, port in
                    processController.detectExistingServerProcessIDs(host, port)
                }
            )
        }
    }
}
