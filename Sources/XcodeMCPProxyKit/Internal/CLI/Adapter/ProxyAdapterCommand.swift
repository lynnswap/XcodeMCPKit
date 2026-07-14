import ArgumentParser
import Foundation

package struct ProxyAdapterCommand: ParsableCommand {
    package init() {}

    package static var configuration: CommandConfiguration {
        CommandConfiguration(
            commandName: "xcode-mcp-proxy",
            abstract: "Forward STDIO MCP traffic to a running Xcode MCP proxy server.",
            discussion: """
                The endpoint is resolved from --url, XCODE_MCP_PROXY_ENDPOINT, the proxy
                discovery file, or http://localhost:8765/mcp, in that order.
                """,
            version: XcodeMCPProxyServer.productMetadata.version
        )
    }

    @Option(
        help: ArgumentHelp("Explicit upstream proxy endpoint.", valueName: "url"),
        transform: CLIHTTPURL.parse
    )
    var url: CLIHTTPURL?

    @Option(
        parsing: .unconditional,
        help: "Request timeout in seconds. Zero disables request timeouts.",
        transform: CLIRequestTimeout.parse
    )
    var requestTimeout: CLIRequestTimeout?
}

package struct CLIHTTPURL: Equatable, Sendable {
    package let url: URL

    package static func parse(_ argument: String) throws -> Self {
        guard let url = URL(string: argument),
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https"
        else {
            throw ValidationError("--url must be an http/https URL")
        }
        return Self(url: url)
    }
}
