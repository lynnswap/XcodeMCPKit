import Foundation
import XcodeMCPKit

enum CLIError: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let text):
            return text
        }
    }
}

struct CLIParser {
    private static let refreshCodeIssuesModeEnv = "MCP_XCODE_REFRESH_CODE_ISSUES_MODE"
    static let configPathEnv = "MCP_XCODE_CONFIG"
    static let removedLazyInitMessage =
        "The proxy always uses eager initialization; --lazy-init has been removed."
    static let removedXcodePIDMessage =
        "Xcode PID support has been removed; --xcode-pid is no longer supported."

    static func parse(args: [String], environment: [String: String]) throws -> ProxyConfig {
        var listenHost = "localhost"
        var listenPort = 0
        let defaultBridgeInvocation = MCPBridgeInvocation.defaultMCPBridge
        var upstreamCommand = defaultBridgeInvocation.command
        var upstreamArgs = defaultBridgeInvocation.arguments
        var upstreamProcessCount = 1
        var upstreamSessionID: String?
        var maxBodyBytes = 1_048_576
        var requestTimeout: TimeInterval = 300
        var configPath: String?
        var autoApproveXcodeDialog = false
        var refreshCodeIssuesMode: ProxyConfig.RefreshCodeIssuesMode = .proxy
        var hasExplicitRefreshCodeIssuesMode = false

        var index = 1
        while index < args.count {
            let arg = args[index]
            guard let flag = CLI.Flag(rawValue: arg) else {
                throw CLIError.message("Unknown argument: \(arg)")
            }
            switch flag {
            case .listen:
                guard index + 1 < args.count else {
                    throw CLIError.message("--listen requires host:port")
                }
                let value = args[index + 1]
                if value.contains(":") {
                    let parsed = try parseListen(value)
                    listenHost = parsed.host
                    listenPort = parsed.port
                } else if let port = Int(value) {
                    listenPort = port
                } else {
                    listenHost = value
                }
                index += 2
            case .host:
                guard index + 1 < args.count else {
                    throw CLIError.message("--host requires a value")
                }
                listenHost = args[index + 1]
                index += 2
            case .port:
                guard index + 1 < args.count else {
                    throw CLIError.message("--port requires a value")
                }
                listenPort = Int(args[index + 1]) ?? listenPort
                index += 2
            case .upstreamCommand:
                guard index + 1 < args.count else {
                    throw CLIError.message("--upstream-command requires a value")
                }
                upstreamCommand = args[index + 1]
                index += 2
            case .upstreamArgs:
                guard index + 1 < args.count else {
                    throw CLIError.message("--upstream-args requires a value")
                }
                let value = args[index + 1]
                let parts = value.split(separator: ",").map { String($0) }.filter { !$0.isEmpty }
                upstreamArgs = parts.isEmpty ? [] : parts
                index += 2
            case .upstreamArg:
                guard index + 1 < args.count else {
                    throw CLIError.message("--upstream-arg requires a value")
                }
                upstreamArgs.append(args[index + 1])
                index += 2
            case .upstreamProcesses:
                guard index + 1 < args.count else {
                    throw CLIError.message("--upstream-processes requires a value")
                }
                guard let parsed = Int(args[index + 1]), (1...10).contains(parsed) else {
                    throw CLIError.message("--upstream-processes must be an integer in 1..10")
                }
                upstreamProcessCount = parsed
                index += 2
            case .xcodePID:
                throw CLIError.message(Self.removedXcodePIDMessage)
            case .sessionID:
                guard index + 1 < args.count else {
                    throw CLIError.message("--session-id requires a value")
                }
                upstreamSessionID = args[index + 1]
                index += 2
            case .maxBodyBytes:
                guard index + 1 < args.count else {
                    throw CLIError.message("--max-body-bytes requires a value")
                }
                maxBodyBytes = Int(args[index + 1]) ?? maxBodyBytes
                index += 2
            case .requestTimeout:
                guard index + 1 < args.count else {
                    throw CLIError.message("--request-timeout requires seconds")
                }
                requestTimeout = TimeInterval(args[index + 1]) ?? requestTimeout
                index += 2
            case .config:
                guard index + 1 < args.count else {
                    throw CLIError.message("--config requires a value")
                }
                configPath = args[index + 1]
                index += 2
            case .autoApprove:
                autoApproveXcodeDialog = true
                index += 1
            case .refreshCodeIssuesMode:
                guard index + 1 < args.count else {
                    throw CLIError.message("--refresh-code-issues-mode requires proxy|upstream")
                }
                guard let parsed = ProxyConfig.RefreshCodeIssuesMode(rawValue: args[index + 1]) else {
                    throw CLIError.message("--refresh-code-issues-mode must be proxy or upstream")
                }
                refreshCodeIssuesMode = parsed
                hasExplicitRefreshCodeIssuesMode = true
                index += 2
            case .lazyInit:
                throw CLIError.message(Self.removedLazyInitMessage)
            case .helpShort, .help, .version, .url, .printURL, .dryRun, .forceRestart,
                 .prefix, .bindir:
                throw CLIError.message("Unknown argument: \(arg)")
            }
        }

        if upstreamSessionID == nil, let value = environment["MCP_XCODE_SESSION_ID"], !value.isEmpty {
            upstreamSessionID = value
        }
        if let value = nonEmpty(environment[refreshCodeIssuesModeEnv]),
            hasExplicitRefreshCodeIssuesMode == false
        {
            guard let parsed = ProxyConfig.RefreshCodeIssuesMode(rawValue: value) else {
                throw CLIError.message(
                    "\(refreshCodeIssuesModeEnv) must be proxy or upstream"
                )
            }
            refreshCodeIssuesMode = parsed
        }
        if configPath == nil, let value = nonEmpty(environment[configPathEnv]) {
            configPath = value
        }
        return ProxyConfig(
            listenHost: listenHost,
            listenPort: listenPort,
            upstreamCommand: upstreamCommand,
            upstreamArgs: upstreamArgs,
            upstreamProcessCount: upstreamProcessCount,
            upstreamSessionID: upstreamSessionID,
            maxBodyBytes: maxBodyBytes,
            requestTimeout: requestTimeout,
            configPath: configPath,
            discoveryFileURL: ProxyFilesystemLocations.discoveryFileURL(
                environment: environment
            ),
            autoApproveXcodeDialog: autoApproveXcodeDialog,
            refreshCodeIssuesMode: refreshCodeIssuesMode
        )
    }

    private static func parseListen(_ value: String) throws -> (host: String, port: Int) {
        guard let colonIndex = value.lastIndex(of: ":") else {
            throw CLIError.message("--listen expects host:port (got \(value))")
        }
        let hostPart = String(value[..<colonIndex])
        let portPart = String(value[value.index(after: colonIndex)...])
        guard let port = Int(portPart), port >= 0 else {
            throw CLIError.message("--listen expects host:port (got \(value))")
        }
        let host = hostPart.isEmpty ? "localhost" : hostPart
        return (host, port)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}
