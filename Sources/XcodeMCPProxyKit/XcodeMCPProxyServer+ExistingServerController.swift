
import XcodeMCPCore
import XcodeMCPProcessRuntime
import XcodeMCPProxyRuntime

extension XcodeMCPProxyServer {
    /// High-level launcher dependency adapter.
    ///
    /// Low-level `lsof`/`ps`/signal mechanics stay inside `XcodeMCPProxyKit`
    /// without becoming part of the public server launcher facade.
    struct ExistingServerController: DependencyClient {
        var terminateExistingServer:
            @Sendable (_ host: String, _ port: Int, _ emitWarning: (String) -> Void) -> Bool
        var detectExistingServerProcessIDs: @Sendable (_ host: String, _ port: Int) -> [Int]

        init(
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

        static let liveValue = live()

        static let testValue = Self(
            terminateExistingServer: { _, _, _ in false },
            detectExistingServerProcessIDs: { _, _ in [] }
        )

        static func live(
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
