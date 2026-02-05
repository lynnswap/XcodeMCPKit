import Foundation
import XcodeMCPProxy

public enum StdioFraming: String, Sendable {
    case ndjson
    case contentLength = "content-length"
}

public struct StdioProxyConfig: Sendable {
    public var spawnProxy: Bool
    public var proxyURL: URL
    public var framing: StdioFraming
    public var proxyConfig: ProxyConfig

    public init(
        spawnProxy: Bool,
        proxyURL: URL,
        framing: StdioFraming,
        proxyConfig: ProxyConfig
    ) {
        self.spawnProxy = spawnProxy
        self.proxyURL = proxyURL
        self.framing = framing
        self.proxyConfig = proxyConfig
    }
}

public enum StdioCLIError: Error, CustomStringConvertible {
    case message(String)

    public var description: String {
        switch self {
        case .message(let text):
            return text
        }
    }
}

public struct StdioCLIParser {
    public static func parse(args: [String], environment: [String: String]) throws -> StdioProxyConfig {
        var spawnProxy = true
        var proxyURL = URL(string: "http://127.0.0.1:8765/mcp")!
        var proxyURLWasSet = false
        var framing: StdioFraming = .ndjson

        var listenHost = "127.0.0.1"
        var listenPort = 8765
        var upstreamCommand = "xcrun"
        var upstreamArgs = ["mcpbridge"]
        var xcodePID: Int?
        var upstreamSessionID: String?
        var maxBodyBytes = 1_048_576
        var requestTimeout: TimeInterval = 300
        var eagerInitialize = true

        var index = 1
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--spawn-proxy":
                spawnProxy = true
                index += 1
            case "--no-spawn-proxy":
                spawnProxy = false
                index += 1
            case "--proxy-url":
                guard index + 1 < args.count else {
                    throw StdioCLIError.message("--proxy-url requires a value")
                }
                let value = args[index + 1]
                guard let url = URL(string: value) else {
                    throw StdioCLIError.message("--proxy-url expects a valid URL (got \(value))")
                }
                proxyURL = url
                proxyURLWasSet = true
                index += 2
            case "--stdio-framing":
                guard index + 1 < args.count else {
                    throw StdioCLIError.message("--stdio-framing requires a value")
                }
                let value = args[index + 1]
                guard let parsed = StdioFraming(rawValue: value) else {
                    throw StdioCLIError.message("--stdio-framing expects ndjson or content-length (got \(value))")
                }
                framing = parsed
                index += 2
            case "--proxy-listen":
                guard index + 1 < args.count else {
                    throw StdioCLIError.message("--proxy-listen requires host:port")
                }
                let value = args[index + 1]
                let parsed = try CLIParser.parseListen(value)
                listenHost = parsed.host
                listenPort = parsed.port
                index += 2
            case "--proxy-host":
                guard index + 1 < args.count else {
                    throw StdioCLIError.message("--proxy-host requires a value")
                }
                listenHost = args[index + 1]
                index += 2
            case "--proxy-port":
                guard index + 1 < args.count else {
                    throw StdioCLIError.message("--proxy-port requires a value")
                }
                listenPort = Int(args[index + 1]) ?? listenPort
                index += 2
            case "--proxy-upstream-command":
                guard index + 1 < args.count else {
                    throw StdioCLIError.message("--proxy-upstream-command requires a value")
                }
                upstreamCommand = args[index + 1]
                index += 2
            case "--proxy-upstream-args":
                guard index + 1 < args.count else {
                    throw StdioCLIError.message("--proxy-upstream-args requires a value")
                }
                let value = args[index + 1]
                let parts = value.split(separator: ",").map { String($0) }.filter { !$0.isEmpty }
                upstreamArgs = parts.isEmpty ? [] : parts
                index += 2
            case "--proxy-upstream-arg":
                guard index + 1 < args.count else {
                    throw StdioCLIError.message("--proxy-upstream-arg requires a value")
                }
                upstreamArgs.append(args[index + 1])
                index += 2
            case "--proxy-xcode-pid":
                guard index + 1 < args.count else {
                    throw StdioCLIError.message("--proxy-xcode-pid requires a value")
                }
                xcodePID = Int(args[index + 1])
                index += 2
            case "--proxy-session-id":
                guard index + 1 < args.count else {
                    throw StdioCLIError.message("--proxy-session-id requires a value")
                }
                upstreamSessionID = args[index + 1]
                index += 2
            case "--proxy-max-body-bytes":
                guard index + 1 < args.count else {
                    throw StdioCLIError.message("--proxy-max-body-bytes requires a value")
                }
                maxBodyBytes = Int(args[index + 1]) ?? maxBodyBytes
                index += 2
            case "--proxy-request-timeout":
                guard index + 1 < args.count else {
                    throw StdioCLIError.message("--proxy-request-timeout requires seconds")
                }
                requestTimeout = TimeInterval(args[index + 1]) ?? requestTimeout
                index += 2
            case "--proxy-lazy-init":
                eagerInitialize = false
                index += 1
            case "-h", "--help":
                throw StdioCLIError.message(usage())
            default:
                throw StdioCLIError.message("Unknown argument: \(arg)\n\n\(usage())")
            }
        }

        if xcodePID == nil, let value = environment["MCP_XCODE_PID"], let parsed = Int(value) {
            xcodePID = parsed
        }
        if upstreamSessionID == nil, let value = environment["MCP_XCODE_SESSION_ID"], !value.isEmpty {
            upstreamSessionID = value
        }

        let proxyConfig = ProxyConfig(
            listenHost: listenHost,
            listenPort: listenPort,
            upstreamCommand: upstreamCommand,
            upstreamArgs: upstreamArgs,
            xcodePID: xcodePID,
            upstreamSessionID: upstreamSessionID,
            maxBodyBytes: maxBodyBytes,
            requestTimeout: requestTimeout,
            eagerInitialize: eagerInitialize
        )

        if !proxyURLWasSet {
            proxyURL = URL(string: "http://\(listenHost):\(listenPort)/mcp") ?? proxyURL
        } else if proxyURL.path.isEmpty {
            proxyURL = URL(string: "\(proxyURL.absoluteString)/mcp") ?? proxyURL
        }

        return StdioProxyConfig(
            spawnProxy: spawnProxy,
            proxyURL: proxyURL,
            framing: framing,
            proxyConfig: proxyConfig
        )
    }

    public static func usage() -> String {
        """
        Usage: xcode-mcp-stdio-proxy [options]

        Options:
          --spawn-proxy               Spawn the HTTP/SSE proxy (default: enabled)
          --no-spawn-proxy            Do not spawn the HTTP/SSE proxy
          --proxy-url url             HTTP/SSE proxy URL (default: http://127.0.0.1:8765/mcp)
          --stdio-framing kind        ndjson | content-length (default: ndjson)

          --proxy-listen host:port    HTTP/SSE proxy listen address
          --proxy-host host           HTTP/SSE proxy listen host
          --proxy-port port           HTTP/SSE proxy listen port
          --proxy-upstream-command c  Upstream command (default: xcrun)
          --proxy-upstream-args a,b   Upstream args (default: mcpbridge)
          --proxy-upstream-arg value  Append a single upstream arg
          --proxy-xcode-pid pid       Target Xcode PID (env MCP_XCODE_PID)
          --proxy-session-id id       Upstream session id (env MCP_XCODE_SESSION_ID)
          --proxy-max-body-bytes n    Max request body size
          --proxy-request-timeout s   Request timeout (default: 300, 0 disables)
          --proxy-lazy-init           Initialize upstream only on first client request
          -h, --help                  Show help
        """
    }
}
