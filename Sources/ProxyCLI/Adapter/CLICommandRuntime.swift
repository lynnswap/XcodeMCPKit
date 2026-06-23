import Foundation
import Logging
import ProxyBuildInfo
import ProxyCLICommon
import ProxyCore

extension XcodeMCPProxyCLICommand {
    package struct Runtime {
    private let dependencies: XcodeMCPProxyCLICommand.Dependencies

    package init(dependencies: XcodeMCPProxyCLICommand.Dependencies) {
        self.dependencies = dependencies
    }

    package func execute(args: [String], environment: [String: String]) async -> Int32 {
        let invocation = XcodeMCPProxyCLICommand.scanInvocation(args)

        if invocation.showHelp {
            dependencies.stdout(XcodeMCPProxyCLICommand.usage())
            return 0
        }

        if invocation.showVersion {
            dependencies.stdout(
                ProxyBuildInfo.versionLine(
                    arguments: args,
                    defaultExecutableName: "xcode-mcp-proxy"
                )
            )
            return 0
        }

        let logSink = dependencies.makeLogSink()

        if invocation.usesRemovedURLHelper {
            logSink.error(
                "url helper mode was removed; configure your HTTP client with a concrete URL (default: http://localhost:8765/mcp)."
            )
            return 1
        }

        if let removedFlagMessage = invocation.removedFlagMessage {
            logSink.error(removedFlagMessage)
            return 1
        }

        if invocation.serverOnlyFlag != nil {
            logSink.error(
                "This option is only supported by xcode-mcp-proxy-server (proxy server)."
            )
            logSink.error("Run: xcode-mcp-proxy-server --help")
            return 1
        }

        do {
            var parseArgs = args
            if invocation.hasExplicitURL && invocation.hasStdioFlag {
                throw CLIError.message("Use either --url or --stdio (not both).")
            }
            if invocation.hasExplicitURL {
                parseArgs = try XcodeMCPProxyCLICommand.rewriteURLFlagToStdio(parseArgs)
            }

            if !parseArgs.contains("--stdio") {
                parseArgs.append("--stdio")
            }

            let config = try CLIParser.parse(args: parseArgs, environment: environment)
            guard let upstreamURL = config.stdioUpstreamURL else {
                logSink.error("Missing upstream URL (start xcode-mcp-proxy-server).")
                return 1
            }

            logResolvedUpstream(config: config, upstreamURL: upstreamURL, logSink: logSink)

            let adapter = dependencies.makeAdapter(
                upstreamURL,
                config.requestTimeout,
                dependencies.input,
                dependencies.output
            )
            await adapter.start()
            await adapter.wait()
            return 0
        } catch let error as CLIError {
            logSink.error(error.description)
            logSink.error(XcodeMCPProxyCLICommand.usage())
            return 1
        } catch {
            logSink.error("error: \(error)")
            return 1
        }
    }

    private func logResolvedUpstream(
        config: ProxyConfig,
        upstreamURL: URL,
        logSink: XcodeMCPProxyCLICommand.LogSink
    ) {
        let url = upstreamURL.absoluteString
        guard let source = config.stdioUpstreamSource else {
            return
        }

        switch source {
        case .discovery:
            logSink.info(
                "STDIO upstream resolved from discovery file",
                [
                    "url": "\(url)",
                    "path": "\(config.discoveryFileURL?.path ?? Discovery.defaultFileURL.path)",
                ]
            )
        case .fallback:
            logSink.info(
                "STDIO upstream fell back to default",
                ["url": "\(url)"]
            )
        case .environment:
            logSink.info(
                "STDIO upstream resolved from XCODE_MCP_PROXY_ENDPOINT",
                ["url": "\(url)"]
            )
        case .explicit:
            logSink.info(
                "STDIO upstream resolved from CLI",
                ["url": "\(url)"]
            )
        }
    }
    }
}
