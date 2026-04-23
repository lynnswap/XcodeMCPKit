import Foundation
import XcodeMCPProxy

extension XcodeMCPProxyCLICommand {
    package static func scanInvocation(_ args: [String]) -> CLICommandInvocation {
        let scan = ProxyCLIInvocationScanner.scanAdapter(args)
        var invocation = CLICommandInvocation()
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
                    throw CLIError.message("--url may only be specified once.")
                }
                guard index + 1 < args.count else {
                    throw CLIError.message("--url requires a value (http/https URL).")
                }
                let value = args[index + 1]
                guard !value.hasPrefix("-") else {
                    throw CLIError.message("--url requires a value (http/https URL).")
                }
                rewritten.append("--stdio")
                rewritten.append(value)
                didRewrite = true
                index += 2
                continue
            }

            if arg.hasPrefix("--url=") {
                guard !didRewrite else {
                    throw CLIError.message("--url may only be specified once.")
                }
                let value = String(arg.dropFirst("--url=".count))
                guard !value.isEmpty else {
                    throw CLIError.message("--url requires a value (http/https URL).")
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

    package static func usage(discoveryFileURL: URL = Discovery.defaultFileURL) -> String {
        """
        Usage:
          xcode-mcp-proxy [options]

        Description:
          STDIO adapter that forwards MCP traffic to a running xcode-mcp-proxy-server (HTTP/SSE).

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
