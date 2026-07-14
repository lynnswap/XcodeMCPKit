import Foundation
import XcodeMCPKit
import XcodeMCPProxyRuntime

package struct XcodeMCPProxyProductMetadata: Equatable, Sendable {
    package let name: String
    package let version: String

    package init(name: String = "XcodeMCPProxyKit", version: String) {
        self.name = name
        self.version = version
    }
}

extension XcodeMCPProxyServer {
    package enum LaunchAction: Sendable {
        case display(String)
        case dryRun(String)
        case start(preparedConfiguration: PreparedConfiguration, forceRestart: Bool)
    }

    package static var productMetadata: XcodeMCPProxyProductMetadata {
        XcodeMCPProxyProductMetadata(version: ProxyBuildInfo.version)
    }

    package static var serverUsage: String {
        ProxyServerCommand.helpMessage()
    }

    package static func resolveLaunchAction(
        arguments: [String],
        environment: [String: String]
    ) throws -> LaunchAction {
        try resolveLaunchAction(
            arguments: arguments,
            environment: environment,
            loadFileConfiguration: {
                try ProxyConfig.File.Loader.loadStrict(configURL: $0)
            }
        )
    }

    static func resolveLaunchAction(
        arguments: [String],
        environment: [String: String],
        loadFileConfiguration:
            @Sendable (URL) throws ->
            ProxyConfig.File.LoadedConfiguration
    ) throws -> LaunchAction {
        let command: ProxyServerCommand
        switch try CLICommandParser.parse(ProxyServerCommand.self, arguments: arguments) {
        case .cleanExit(let message):
            return .display(message)
        case .command(let parsedCommand):
            command = parsedCommand
        }

        if isTruthy(environment["LAZY_INIT"]) {
            throw CLICommandParser.validationError(
                for: ProxyServerCommand.self,
                message: removedLazyInitializationMessage
            )
        }

        let proxyConfig: ProxyConfig
        do {
            proxyConfig = try command.resolveConfiguration(environment: environment)
            try proxyConfig.validateModernProtocolConfiguration()
        } catch let error as CLICommandError {
            throw error
        } catch {
            throw CLICommandParser.validationError(
                for: ProxyServerCommand.self,
                message: String(describing: error)
            )
        }

        let configuration = XcodeMCPProxyServerConfiguration(serverProxyConfig: proxyConfig)
        let resolved: ProxyConfig
        do {
            resolved = try ProxyConfig.resolving(
                configuration,
                loadFileConfiguration: loadFileConfiguration
            )
            try resolved.validateModernProtocolConfiguration()
        } catch {
            throw CLICommandParser.validationError(
                for: ProxyServerCommand.self,
                message: String(describing: error)
            )
        }

        if command.dryRun || isTruthy(environment["DRY_RUN"]) {
            return .dryRun(command.renderResolvedCommand(configuration: configuration))
        }
        return .start(
            preparedConfiguration: PreparedConfiguration(
                configuration: configuration,
                proxyConfig: resolved
            ),
            forceRestart: command.forceRestart
        )
    }

    package static func bootstrapLogging(environment: [String: String]) {
        ProxyLogging.bootstrap(environment: environment)
    }
}

private extension ProxyServerCommand {
    func resolveConfiguration(environment: [String: String]) throws -> ProxyConfig {
        let listenAddress = try resolvedListenAddress(environment: environment)
        let bridge = MCPBridgeInvocation.defaultMCPBridge
        var resolvedUpstreamArguments = bridge.arguments
        if let upstreamArgs {
            resolvedUpstreamArguments =
                upstreamArgs
                .split(separator: ",")
                .map(String.init)
                .filter { $0.isEmpty == false }
        }
        resolvedUpstreamArguments.append(contentsOf: upstreamArg)

        let refreshCodeIssuesMode = try resolvedRefreshCodeIssuesMode(
            environment: environment
        )
        return ProxyConfig(
            listenHost: listenAddress.host,
            listenPort: listenAddress.port,
            upstreamCommand: upstreamCommand ?? bridge.command,
            upstreamArgs: resolvedUpstreamArguments,
            upstreamProcessCount: upstreamProcesses ?? 1,
            upstreamSessionID: sessionID ?? nonEmpty(environment["MCP_XCODE_SESSION_ID"]),
            maxBodyBytes: maxBodyBytes ?? 1_048_576,
            requestTimeout: requestTimeout?.seconds ?? 300,
            configPath: config ?? nonEmpty(environment["MCP_XCODE_CONFIG"]),
            discoveryFileURL: ProxyFilesystemLocations.discoveryFileURL(
                environment: environment
            ),
            autoApproveXcodeDialog: autoApprove,
            refreshCodeIssuesMode: refreshCodeIssuesMode
        )
    }

    func resolvedListenAddress(environment: [String: String]) throws -> CLIListenAddress {
        if let listen {
            return listen
        }
        if host != nil || port != nil {
            return CLIListenAddress(host: host ?? "localhost", port: port ?? 8765)
        }
        if let value = nonEmpty(environment["LISTEN"]) {
            guard let address = CLIListenAddress(argument: value) else {
                throw CLICommandParser.validationError(
                    for: ProxyServerCommand.self,
                    message: "LISTEN must be a host:port value with a port in 0...65535"
                )
            }
            return address
        }

        let environmentHost = nonEmpty(environment["HOST"]) ?? "localhost"
        let environmentPort: Int
        if let value = nonEmpty(environment["PORT"]) {
            guard let port = Int(value), (0...65_535).contains(port) else {
                throw CLICommandParser.validationError(
                    for: ProxyServerCommand.self,
                    message: "PORT must be an integer in 0...65535"
                )
            }
            environmentPort = port
        } else {
            environmentPort = 8765
        }
        return CLIListenAddress(host: environmentHost, port: environmentPort)
    }

    func resolvedRefreshCodeIssuesMode(
        environment: [String: String]
    ) throws -> ProxyConfig.RefreshCodeIssuesMode {
        if let refreshCodeIssuesMode {
            return refreshCodeIssuesMode
        }
        guard let value = nonEmpty(environment["MCP_XCODE_REFRESH_CODE_ISSUES_MODE"]) else {
            return .proxy
        }
        guard let mode = ProxyConfig.RefreshCodeIssuesMode(rawValue: value) else {
            throw CLICommandParser.validationError(
                for: ProxyServerCommand.self,
                message: "MCP_XCODE_REFRESH_CODE_ISSUES_MODE must be proxy or upstream"
            )
        }
        return mode
    }

    func renderResolvedCommand(configuration: XcodeMCPProxyServerConfiguration) -> String {
        var arguments = [
            "xcode-mcp-proxy-server",
            "--listen",
            "\(configuration.bindAddress.host):\(configuration.bindAddress.port)",
        ]
        if let configPath = configuration.configurationFileURL?.path {
            arguments += ["--config", configPath]
        }
        if autoApprove {
            arguments.append("--auto-approve")
        }
        if let maxBodyBytes {
            arguments += ["--max-body-bytes", String(maxBodyBytes)]
        }
        if let requestTimeout {
            arguments += ["--request-timeout", requestTimeout.description]
        }
        if let upstreamCommand {
            arguments += ["--upstream-command", upstreamCommand]
        }
        if let upstreamArgs {
            arguments += ["--upstream-args", upstreamArgs]
        }
        for argument in upstreamArg {
            arguments += ["--upstream-arg", argument]
        }
        if let upstreamProcesses {
            arguments += ["--upstream-processes", String(upstreamProcesses)]
        }
        if let sessionID = configuration.upstream.sessionID {
            arguments += ["--session-id", sessionID]
        }
        if let refreshCodeIssuesMode {
            arguments += [
                "--refresh-code-issues-mode",
                refreshCodeIssuesMode.rawValue,
            ]
        } else if configuration.featurePolicy.refreshCodeIssuesMode != .proxy {
            arguments += [
                "--refresh-code-issues-mode",
                configuration.featurePolicy.refreshCodeIssuesMode.rawValue,
            ]
        }
        if forceRestart {
            arguments.append("--force-restart")
        }
        return arguments.map(shellQuoted).joined(separator: " ")
    }
}

private func nonEmpty(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
        value.isEmpty == false
    else {
        return nil
    }
    return value
}

private func isTruthy(_ value: String?) -> Bool {
    guard let value = nonEmpty(value) else {
        return false
    }
    return ["1", "true", "yes", "on"].contains(value.lowercased())
}

private let removedLazyInitializationMessage =
    "The proxy always uses eager initialization; --lazy-init has been removed."

private func shellQuoted(_ value: String) -> String {
    let safeCharacters = CharacterSet.alphanumerics.union(
        CharacterSet(charactersIn: "-._/:,@")
    )
    if value.isEmpty == false,
        value.unicodeScalars.allSatisfy(safeCharacters.contains)
    {
        return value
    }
    return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
