import Foundation
import Logging
import XcodeMCPProxy
import XcodeMCPStdioProxy

@main
struct StdioMain {
    static func main() async {
        ProxyLogging.bootstrap()
        let logger: Logger = ProxyLogging.make("stdio-cli")
        do {
            let config = try StdioCLIParser.parse(
                args: CommandLine.arguments,
                environment: ProcessInfo.processInfo.environment
            )

            let proxyServer: ProxyServer?
            if config.spawnProxy {
                do {
                    let server = ProxyServer(config: config.proxyConfig)
                    _ = try server.start()
                    proxyServer = server
                    logger.info("Spawned HTTP/SSE proxy", metadata: ["url": "\(config.proxyURL)"])
                } catch {
                    logger.warning("Failed to spawn HTTP/SSE proxy; continuing", metadata: ["error": "\(error)"])
                    proxyServer = nil
                }
            } else {
                proxyServer = nil
            }

            let stdioProxy = StdioProxy(config: config, logger: ProxyLogging.make("stdio"))
            await stdioProxy.run()

            if let proxyServer {
                _ = proxyServer.shutdownGracefully()
            }
        } catch let error as StdioCLIError {
            logger.error("\(error.description)")
            if !error.description.contains("Usage:") {
                logger.error("\(StdioCLIParser.usage())")
            }
            exit(1)
        } catch {
            logger.error("error: \(error)")
            exit(1)
        }
    }
}
