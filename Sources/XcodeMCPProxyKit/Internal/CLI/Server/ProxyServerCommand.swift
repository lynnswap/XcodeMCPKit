import ArgumentParser
import Foundation

package struct ProxyServerCommand: ParsableCommand {
    package init() {}

    package static var configuration: CommandConfiguration {
        CommandConfiguration(
            commandName: "xcode-mcp-proxy-server",
            abstract: "Start the Streamable HTTP proxy server for Xcode MCP.",
            discussion: """
                The server locates its native helper and selected Xcode installation automatically.
                MCP clients connect to its Streamable HTTP endpoint.
                """,
            version: XcodeMCPProxyServer.productMetadata.version
        )
    }

    @Option(
        help: ArgumentHelp(
            "Listen address. Cannot be combined with --host or --port.",
            valueName: "host:port"
        )
    )
    var listen: CLIListenAddress?

    @Option(help: "Listen host. Defaults to localhost.")
    var host: String?

    @Option(help: "Listen port in 0...65535. Defaults to 8765.")
    var port: Int?

    @Option(help: "Maximum accepted HTTP request body size in bytes.")
    var maxBodyBytes: Int?

    @Option(
        parsing: .unconditional,
        help: "Request timeout in seconds. Requests have none by default, and zero also means none. Starting a host stays bounded.",
        transform: CLIRequestTimeout.parse
    )
    var requestTimeout: CLIRequestTimeout?

    @Flag(help: "Share compilation caches across worktrees using compiler prefix mapping.")
    var shareCompilationCache = false

    @Flag(help: "Automatically allow Xcode MCP connections for all agents, including external clients. Requires Accessibility permission.")
    var autoApprove = false

    @Flag(help: "Serve /debug/upstreams and /debug/reset on a loopback listener.")
    var debugEndpoints = false

    @Flag(help: "Terminate an existing proxy server on the listen port before starting.")
    var forceRestart = false

    @Flag(help: "Print the resolved server command without starting it.")
    var dryRun = false

    package mutating func validate() throws {
        if listen != nil, host != nil || port != nil {
            throw ValidationError("--listen cannot be combined with --host or --port")
        }
        if let host, host.isEmpty {
            throw ValidationError("--host must not be empty")
        }
        if let port, (0...65_535).contains(port) == false {
            throw ValidationError("--port must be an integer in 0...65535")
        }
        if let maxBodyBytes, maxBodyBytes <= 0 {
            throw ValidationError("--max-body-bytes must be a positive integer")
        }

    }
}

package struct CLIListenAddress: Equatable, Sendable, CustomStringConvertible,
    ExpressibleByArgument
{
    package let host: String
    package let port: Int

    package init(host: String, port: Int) {
        precondition(host.isEmpty == false)
        precondition((0...65_535).contains(port))
        self.host = host
        self.port = port
    }

    package init?(argument: String) {
        guard let colonIndex = argument.lastIndex(of: ":") else {
            return nil
        }
        let host = String(argument[..<colonIndex])
        let portText = String(argument[argument.index(after: colonIndex)...])
        guard let port = Int(portText), (0...65_535).contains(port) else {
            return nil
        }
        self.host = host.isEmpty ? "localhost" : host
        self.port = port
    }

    package var description: String { "\(host):\(port)" }
}
