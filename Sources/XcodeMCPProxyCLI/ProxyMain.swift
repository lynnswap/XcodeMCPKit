import Foundation
import Logging
import XcodeMCPProxy
import XcodeMCPStdioProxy

@main
struct ProxyMain {
    static func main() async {
        ProxyLogging.bootstrap()
        let logger: Logger = ProxyLogging.make("cli")

        do {
            let stdioMode = try StdioMode.parse(args: CommandLine.arguments)
            if stdioMode.showHelp {
                print(CLIParser.usage())
                exit(0)
            }

            let config = try CLIParser.parse(
                args: stdioMode.filteredArgs,
                environment: ProcessInfo.processInfo.environment
            )

            if stdioMode.enabled {
                try await runStdioProxy(config: config, framing: stdioMode.framing, logger: logger)
            } else {
                let server = ProxyServer(config: config)
                try server.run()
            }
        } catch let error as CLIError {
            logger.error("\(error.description)")
            if !error.description.contains("Usage:") {
                logger.error("\(CLIParser.usage())")
            }
            exit(1)
        } catch {
            logger.error("error: \(error)")
            exit(1)
        }
    }
}

private struct StdioMode {
    let enabled: Bool
    let framing: StdioFraming
    let showHelp: Bool
    let filteredArgs: [String]

    static func parse(args: [String]) throws -> StdioMode {
        var enabled = false
        var framing: StdioFraming = .ndjson
        var showHelp = false
        var filteredArgs: [String] = []
        filteredArgs.append(args.first ?? "xcode-mcp-proxy")

        var index = 1
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--stdio":
                enabled = true
                index += 1
            case "--stdio-framing":
                guard index + 1 < args.count else {
                    throw CLIError.message("--stdio-framing requires a value")
                }
                let value = args[index + 1]
                guard let parsed = StdioFraming(rawValue: value) else {
                    throw CLIError.message("--stdio-framing must be ndjson or content-length")
                }
                framing = parsed
                enabled = true
                index += 2
            case "-h", "--help":
                showHelp = true
                filteredArgs.append(arg)
                index += 1
            default:
                filteredArgs.append(arg)
                index += 1
            }
        }

        return StdioMode(
            enabled: enabled,
            framing: framing,
            showHelp: showHelp,
            filteredArgs: filteredArgs
        )
    }
}

private func runStdioProxy(config: ProxyConfig, framing: StdioFraming, logger: Logger) async throws {
    let server = ProxyServer(config: config)
    _ = try server.start()
    logger.info("Spawned HTTP/SSE proxy", metadata: ["listen": "\(config.listenHost):\(config.listenPort)"])

    let proxyURL = buildProxyURL(host: config.listenHost, port: config.listenPort)
    let stdioConfig = StdioProxyConfig(
        spawnProxy: false,
        proxyURL: proxyURL,
        framing: framing,
        proxyConfig: config
    )

    let stdioProxy = StdioProxy(config: stdioConfig, logger: ProxyLogging.make("stdio"))
    await stdioProxy.run()

    _ = server.shutdownGracefully()
}

private func buildProxyURL(host: String, port: Int) -> URL {
    let resolvedHost: String
    switch host {
    case "", "0.0.0.0", "::":
        resolvedHost = "127.0.0.1"
    default:
        resolvedHost = host
    }
    let wrappedHost = resolvedHost.contains(":") && !resolvedHost.hasPrefix("[")
        ? "[\(resolvedHost)]"
        : resolvedHost
    let value = "http://\(wrappedHost):\(port)/mcp"
    return URL(string: value)!
}
