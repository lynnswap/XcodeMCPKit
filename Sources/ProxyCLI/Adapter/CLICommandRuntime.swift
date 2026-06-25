import Foundation
import Logging
import ProxyBuildInfo
import ProxyCLICommon
import XcodeMCPProxyKit

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
            if invocation.hasExplicitURL && invocation.hasStdioFlag {
                throw XcodeMCPProxyCLICommand.Error.message(
                    "Use either --url or --stdio (not both)."
                )
            }

            let options = try XcodeMCPProxyCLICommand.parseOptions(args)
            let endpoint = try XcodeMCPProxyAdapterEndpointResolver().resolve(
                .init(
                    explicitURL: options.explicitURL,
                    explicitURLLabel: options.explicitURLLabel,
                    environment: environment
                )
            )

            logResolvedUpstream(
                endpoint: endpoint,
                environment: environment,
                logSink: logSink
            )

            let adapter = dependencies.makeAdapter(
                endpoint,
                options.requestTimeout,
                dependencies.input,
                dependencies.output
            )
            await adapter.start()
            await adapter.wait()
            return 0
        } catch let error as XcodeMCPProxyCLICommand.Error {
            logSink.error(error.description)
            logSink.error(XcodeMCPProxyCLICommand.usage())
            return 1
        } catch let error as XcodeMCPProxyAdapterEndpointResolver.Error {
            logSink.error(error.description)
            logSink.error(XcodeMCPProxyCLICommand.usage())
            return 1
        } catch {
            logSink.error("error: \(error)")
            return 1
        }
    }

    private func logResolvedUpstream(
        endpoint: XcodeMCPProxyAdapterEndpoint,
        environment: [String: String],
        logSink: XcodeMCPProxyCLICommand.LogSink
    ) {
        let url = endpoint.url.absoluteString
        switch endpoint.source {
        case .discovery:
            let discoveryPath = XcodeMCPProxyAdapterEndpointResolver.discoveryFileURL(
                environment: environment
            ).path
            logSink.info(
                "STDIO upstream resolved from discovery file",
                [
                    "url": "\(url)",
                    "path": "\(discoveryPath)",
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
