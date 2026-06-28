
import XcodeMCPKit

extension XcodeMCPProxyServer {
    /// High-level launcher dependency adapter.
    ///
    /// Proxy restart policy stays inside `XcodeMCPProxyKit`; low-level process
    /// command and signal mechanics are owned by the internal process runtime.
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
