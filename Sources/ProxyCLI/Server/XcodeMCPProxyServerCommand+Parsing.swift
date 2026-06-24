import Foundation
import ProxyCLICommon
import ProxyCore
import XcodeMCPProxyKit

extension XcodeMCPProxyServerCommand {
    package static func parseOptions(args: [String]) throws -> XcodeMCPProxyServerCommand.Options {
        let scan: CLI.InvocationScanner.ServerScan
        do {
            scan = try CLI.InvocationScanner.scanServer(args)
        } catch let error as CLIError {
            throw XcodeMCPProxyServerCommand.Error.message(error.description)
        }
        return XcodeMCPProxyServerCommand.Options(
            forwardedArgs: scan.forwardedArgs,
            showHelp: scan.showHelp,
            showVersion: scan.showVersion,
            hasListenFlag: scan.hasListenFlag,
            hasHostFlag: scan.hasHostFlag,
            hasPortFlag: scan.hasPortFlag,
            hasConfigFlag: scan.hasConfigFlag,
            hasAutoApproveFlag: scan.hasAutoApproveFlag,
            hasRefreshCodeIssuesModeFlag: scan.hasRefreshCodeIssuesModeFlag,
            forceRestart: scan.forceRestart,
            dryRun: scan.dryRun
        )
    }

    package static func applyDefaults(
        from environment: [String: String],
        to options: inout XcodeMCPProxyServerCommand.Options
    ) throws {
        if !options.hasListenFlag && !options.hasHostFlag && !options.hasPortFlag {
            if let listen = nonEmpty(environment["LISTEN"]) {
                options.forwardedArgs += ["--listen", listen]
            } else {
                let envHost = nonEmpty(environment["HOST"])
                let envPort = nonEmpty(environment["PORT"])
                if envHost != nil || envPort != nil {
                    let host = envHost ?? "localhost"
                    let port = envPort ?? "8765"
                    options.forwardedArgs += ["--listen", "\(host):\(port)"]
                } else {
                    options.forwardedArgs += ["--listen", "localhost:8765"]
                }
            }
        }

        if !options.hasListenFlag, options.hasHostFlag, !options.hasPortFlag {
            options.forwardedArgs += ["--port", "8765"]
        }

        if isTruthy(environment["LAZY_INIT"]) {
            throw XcodeMCPProxyServerCommand.Error.message(CLIParser.removedLazyInitMessage)
        }

        // MCP_XCODE_CONFIG and MCP_XCODE_REFRESH_CODE_ISSUES_MODE are
        // resolved by CLIParser itself; synthesizing flags here would handle
        // the same variables in two layers.
    }

    /// The dry-run echo reflects the resolved configuration, so values the
    /// parser pulled from the environment stay visible even though they
    /// never existed as argv flags.
    package static func dryRunCommandLine(
        options: XcodeMCPProxyServerCommand.Options,
        config: XcodeMCPProxyServer.Configuration
    ) -> String {
        var parts = ["xcode-mcp-proxy-server"] + options.forwardedArgs
        if options.hasConfigFlag == false, let configPath = config.configPath {
            parts += ["--config", configPath]
        }
        if options.hasRefreshCodeIssuesModeFlag == false, config.refreshCodeIssuesMode != .proxy {
            parts += ["--refresh-code-issues-mode", config.refreshCodeIssuesMode.rawValue]
        }
        return parts.joined(separator: " ")
    }

    package static func serverUsage() -> String {
        """
        Usage:
          xcode-mcp-proxy-server [options]

        Options:
          --listen host:port
          --host host
          --port port
          --config path
          --auto-approve
          --upstream-processes n
          --refresh-code-issues-mode proxy|upstream
          --force-restart
          --dry-run
          --version
          -h, --help

        Notes:
          - Starts the Streamable HTTP proxy server (and spawns xcrun mcpbridge as upstream processes).
          - HTTP-capable clients should connect directly; xcode-mcp-proxy is the STDIO compatibility adapter.
          - Default listen: localhost:8765 (override via --listen / --host / --port or env LISTEN/HOST/PORT).
          - --auto-approve opt-in enables automatic approval of the Xcode permission dialog.
          - Initialize config path: --config or env \(CLIParser.configPathEnv)
          - When the listen port is already in use, rerun with --force-restart to terminate an existing xcode-mcp-proxy-server.
        """
    }

    package static func portInUseMessage(host: String, port: Int, pids: [Int]) -> String {
        let displayHost: String = {
            if host.contains(":"), !host.hasPrefix("[") {
                return "[\(host)]"
            }
            return host
        }()

        var lines: [String] = []
        lines.reserveCapacity(8)
        lines.append("error: listen \(displayHost):\(port) is already in use (Address already in use).")
        if pids.count == 1 {
            lines.append("Detected a running xcode-mcp-proxy-server (pid: \(pids[0])).")
        } else if pids.count > 1 {
            let formatted = pids.map(String.init).joined(separator: ", ")
            lines.append("Detected running xcode-mcp-proxy-server processes (pids: \(formatted)).")
        }
        lines.append("Terminate the existing process and try again.")
        lines.append(
            "To force a restart, rerun with `--force-restart`; this will terminate the existing xcode-mcp-proxy-server and start a new one."
        )
        lines.append("")
        lines.append("Examples:")
        lines.append("  pkill -x xcode-mcp-proxy-server")
        lines.append("  xcode-mcp-proxy-server --force-restart")
        return lines.joined(separator: "\n")
    }

    package static func nonEmpty(_ value: String?) -> String? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return raw
    }

    package static func isTruthy(_ value: String?) -> Bool {
        guard let raw = nonEmpty(value) else { return false }
        return ["1", "true", "yes", "on"].contains(raw.lowercased())
    }

    package static func isAddressAlreadyInUse(_ error: Swift.Error) -> Bool {
        let text = String(describing: error)
        if text.localizedCaseInsensitiveContains("Address already in use") {
            return true
        }
        return text.contains("errno: \(EADDRINUSE)")
    }
}
