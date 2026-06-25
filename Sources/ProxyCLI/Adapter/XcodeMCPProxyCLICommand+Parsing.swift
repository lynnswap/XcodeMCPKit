import Foundation
import ProxyCLICommon
import XcodeMCPProxyKit

extension XcodeMCPProxyCLICommand {
    package static func scanInvocation(_ args: [String]) -> XcodeMCPProxyCLICommand.Invocation {
        let scan = ProxyCLIInvocationScanner.scanAdapter(args)
        var invocation = XcodeMCPProxyCLICommand.Invocation()
        invocation.showHelp = scan.showHelp
        invocation.showVersion = scan.showVersion
        invocation.usesRemovedURLHelper = scan.usesRemovedURLHelper
        invocation.removedFlagMessage = scan.removedFlagMessage
        invocation.hasExplicitURL = scan.hasExplicitURL
        invocation.hasStdioFlag = scan.hasStdioFlag
        invocation.serverOnlyFlag = scan.serverOnlyFlag
        return invocation
    }

    package static func rewriteURLFlagToStdio(_ args: [String]) throws -> [String] {
        var rewritten: [String] = []
        rewritten.reserveCapacity(args.count + 1)
        var didRewrite = false

        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg == "--url" {
                guard !didRewrite else {
                    throw XcodeMCPProxyCLICommand.Error.message("--url may only be specified once.")
                }
                guard index + 1 < args.count else {
                    throw XcodeMCPProxyCLICommand.Error.message(
                        "--url requires a value (http/https URL)."
                    )
                }
                let value = args[index + 1]
                guard !value.hasPrefix("-") else {
                    throw XcodeMCPProxyCLICommand.Error.message(
                        "--url requires a value (http/https URL)."
                    )
                }
                rewritten.append("--stdio")
                rewritten.append(value)
                didRewrite = true
                index += 2
                continue
            }

            if arg.hasPrefix("--url=") {
                guard !didRewrite else {
                    throw XcodeMCPProxyCLICommand.Error.message("--url may only be specified once.")
                }
                let value = String(arg.dropFirst("--url=".count))
                guard !value.isEmpty else {
                    throw XcodeMCPProxyCLICommand.Error.message(
                        "--url requires a value (http/https URL)."
                    )
                }
                rewritten.append("--stdio")
                rewritten.append(value)
                didRewrite = true
                index += 1
                continue
            }

            rewritten.append(arg)
            index += 1
        }

        return rewritten
    }

    package struct Options {
        package var requestTimeout: TimeInterval
        package var explicitURL: String?
        package var explicitURLLabel: String

        package init(
            requestTimeout: TimeInterval = 300,
            explicitURL: String? = nil,
            explicitURLLabel: String = "explicit URL"
        ) {
            self.requestTimeout = requestTimeout
            self.explicitURL = explicitURL
            self.explicitURLLabel = explicitURLLabel
        }
    }

    package enum Error: Swift.Error, CustomStringConvertible {
        case message(String)

        package var description: String {
            switch self {
            case .message(let text):
                return text
            }
        }
    }

    package static func parseOptions(_ args: [String]) throws -> Options {
        var options = Options()
        var index = 1
        var didReadURLFlag = false

        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--request-timeout":
                guard index + 1 < args.count else {
                    throw Error.message("--request-timeout requires seconds")
                }
                if let parsed = TimeInterval(args[index + 1]) {
                    options.requestTimeout = parsed
                }
                index += 2
            case "--url":
                guard didReadURLFlag == false else {
                    throw Error.message("--url may only be specified once.")
                }
                guard index + 1 < args.count else {
                    throw Error.message("--url requires a value (http/https URL).")
                }
                let value = args[index + 1]
                guard !value.hasPrefix("-") else {
                    throw Error.message("--url requires a value (http/https URL).")
                }
                options.explicitURL = value
                options.explicitURLLabel = "--url"
                didReadURLFlag = true
                index += 2
            case let value where value.hasPrefix("--url="):
                guard didReadURLFlag == false else {
                    throw Error.message("--url may only be specified once.")
                }
                let explicitURL = String(value.dropFirst("--url=".count))
                guard !explicitURL.isEmpty else {
                    throw Error.message("--url requires a value (http/https URL).")
                }
                options.explicitURL = explicitURL
                options.explicitURLLabel = "--url"
                didReadURLFlag = true
                index += 1
            case "--stdio":
                if index + 1 < args.count {
                    let value = args[index + 1]
                    if !value.hasPrefix("-") {
                        options.explicitURL = value
                        options.explicitURLLabel = "--stdio"
                        index += 2
                        continue
                    }
                }
                index += 1
            case "-h", "--help", "--version":
                index += 1
            default:
                throw Error.message("Unknown argument: \(arg)")
            }
        }

        return options
    }

    package static func usage(
        discoveryFileURL: URL = XcodeMCPProxyAdapterEndpointResolver.discoveryFileURL()
    ) -> String {
        """
        Usage:
          xcode-mcp-proxy [options]

        Description:
          STDIO compatibility adapter that forwards MCP traffic to a running xcode-mcp-proxy-server (Streamable HTTP).

        Options:
          --request-timeout seconds  Request timeout (default: 300, 0 disables)
          --url url                  Explicit upstream URL (default: env/discovery/http://localhost:8765/mcp)
          --version                  Show version
          -h, --help                 Show help

        Environment:
          XCODE_MCP_PROXY_ENDPOINT   Upstream proxy URL (overrides discovery)

        Notes:
          - Proxy server: xcode-mcp-proxy-server
          - --config is only supported by xcode-mcp-proxy-server
          - Discovery file: \(discoveryFileURL.path)
        """
    }

    static func shouldConsumeRequestTimeoutValue(_ token: String) -> Bool {
        ProxyCLIInvocationScanner.shouldConsumeRequestTimeoutValue(token)
    }
}
