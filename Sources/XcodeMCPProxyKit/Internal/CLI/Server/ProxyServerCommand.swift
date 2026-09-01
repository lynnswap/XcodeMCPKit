import ArgumentParser
import Foundation

package struct ProxyServerCommand: ParsableCommand {
    package init() {}

    package static var configuration: CommandConfiguration {
        CommandConfiguration(
            commandName: "xcode-mcp-proxy-server",
            abstract: "Start the Streamable HTTP proxy server for Xcode MCP.",
            discussion: """
                The server manages xcrun mcpbridge upstream processes. HTTP-capable clients
                should connect directly; use xcode-mcp-proxy only for STDIO compatibility.
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

    @Option(help: ArgumentHelp("TOML configuration file.", valueName: "path"))
    var config: String?

    @Flag(help: "Automatically approve the Xcode permission dialog.")
    var autoApprove = false

    @Option(help: "Maximum accepted HTTP request body size in bytes.")
    var maxBodyBytes: Int?

    @Option(
        parsing: .unconditional,
        help: "Request timeout in seconds. Zero disables non-initialize timeouts.",
        transform: CLIRequestTimeout.parse
    )
    var requestTimeout: CLIRequestTimeout?

    @Option(help: ArgumentHelp("Upstream executable.", valueName: "command"))
    var upstreamCommand: String?

    @Option(
        parsing: .unconditional,
        help: "Comma-separated replacement for the default upstream arguments."
    )
    var upstreamArgs: String?

    @Option(
        parsing: .unconditionalSingleValue,
        help: "Append one argument to the upstream invocation. May be repeated."
    )
    var upstreamArg: [String] = []

    @Option(help: "Upstream mcpbridge processes per running Xcode process, in 1...10.")
    var upstreamProcesses: Int?

    @Option(help: "Explicit upstream Xcode MCP session identifier.")
    var sessionID: String?

    @Option(help: "Xcode connection mode: automatic, gui, or headless.")
    var xcodeMode: ProxyConfig.XcodeMode = .automatic

    @Option(help: "Code issue refresh owner: proxy or upstream.")
    var refreshCodeIssuesMode: ProxyConfig.RefreshCodeIssuesMode?

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
        if let config, config.isEmpty {
            throw ValidationError("--config must not be empty")
        }
        if let port, (0...65_535).contains(port) == false {
            throw ValidationError("--port must be an integer in 0...65535")
        }
        if let maxBodyBytes, maxBodyBytes <= 0 {
            throw ValidationError("--max-body-bytes must be a positive integer")
        }
        if let upstreamProcesses, (1...10).contains(upstreamProcesses) == false {
            throw ValidationError("--upstream-processes must be an integer in 1...10")
        }
        if let upstreamCommand, upstreamCommand.isEmpty {
            throw ValidationError("--upstream-command must not be empty")
        }
        if let sessionID, sessionID.isEmpty {
            throw ValidationError("--session-id must not be empty")
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

extension ProxyConfig.RefreshCodeIssuesMode: ExpressibleByArgument {}
extension ProxyConfig.XcodeMode: ExpressibleByArgument {}
