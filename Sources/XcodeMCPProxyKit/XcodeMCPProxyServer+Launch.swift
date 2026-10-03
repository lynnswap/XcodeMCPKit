import Foundation

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
        case start(configuration: XcodeMCPProxyServerConfiguration, forceRestart: Bool)
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
        let command: ProxyServerCommand
        switch try CLICommandParser.parse(ProxyServerCommand.self, arguments: arguments) {
        case .cleanExit(let message):
            return .display(message)
        case .command(let parsedCommand):
            command = parsedCommand
        }

        let configuration = try command.resolveConfiguration(environment: environment)
        _ = try configuration.runtimeConfiguration()
        if command.dryRun || isTruthy(environment["DRY_RUN"]) {
            return .dryRun(command.renderResolvedCommand(configuration: configuration))
        }
        return .start(
            configuration: configuration,
            forceRestart: command.forceRestart
        )
    }

    package static func bootstrapLogging(environment: [String: String]) {
        XcodeMCPProxyLogging.bootstrap(environment: environment)
    }
}

private extension ProxyServerCommand {
    func resolveConfiguration(environment: [String: String]) throws -> XcodeMCPProxyServerConfiguration {
        let listenAddress = try resolvedListenAddress(environment: environment)
        let timeout = requestTimeout?.seconds ?? 300
        return XcodeMCPProxyServerConfiguration(
            bindAddress: .init(host: listenAddress.host, port: listenAddress.port),
            nativeHostBundleURL: environment["XCODE_MCP_NATIVE_HOST_BUNDLE"].map { URL(fileURLWithPath: $0) },
            developerDirectoryURL: environment["DEVELOPER_DIR"].map { URL(fileURLWithPath: $0) },
            maxBodyBytes: maxBodyBytes ?? 1_048_576,
            requestTimeout: timeout > 0 ? .seconds(timeout) : nil,
            discovery: .file(ProxyFilesystemLocations.discoveryFileURL(environment: environment)),
            approvalPolicy: autoApprove ? .automatic : .manual
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

    func renderResolvedCommand(configuration: XcodeMCPProxyServerConfiguration) -> String {
        var arguments = [
            "xcode-mcp-proxy-server",
            "--listen",
            "\(configuration.bindAddress.host):\(configuration.bindAddress.port)",
        ]
        if autoApprove {
            arguments.append("--auto-approve")
        }
        if let maxBodyBytes {
            arguments += ["--max-body-bytes", String(maxBodyBytes)]
        }
        if let requestTimeout {
            arguments += ["--request-timeout", requestTimeout.description]
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
