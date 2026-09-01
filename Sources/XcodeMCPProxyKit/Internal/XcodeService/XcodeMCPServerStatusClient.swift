import Foundation
import XcodeMCPKit
import XcodeMCPProxyRuntime

enum XcodeMCPServerAvailability: Equatable, Sendable {
    case unavailable
    case disabled
    case enabled
}

struct XcodeMCPServerStatusClient: Sendable {
    enum Failure: Error, Equatable, CustomStringConvertible, Sendable {
        case discoveryFailed(exitStatus: Int32, stderr: String)
        case discoveryReturnedNoPath
        case statusFailed(exitStatus: Int32, stderr: String)
        case malformedStatus
        case timedOut(operation: String)
        case executionFailed(operation: String, message: String)

        var description: String {
            switch self {
            case .discoveryFailed(let exitStatus, let stderr):
                return Self.processFailureDescription(
                    operation: "discover mcp-server",
                    exitStatus: exitStatus,
                    stderr: stderr
                )
            case .discoveryReturnedNoPath:
                return "xcrun --find mcp-server returned no executable path"
            case .statusFailed(let exitStatus, let stderr):
                return Self.processFailureDescription(
                    operation: "read mcp-server status",
                    exitStatus: exitStatus,
                    stderr: stderr
                )
            case .malformedStatus:
                return "mcp-server returned malformed status JSON"
            case .timedOut(let operation):
                return "\(operation) timed out"
            case .executionFailed(let operation, let message):
                return "\(operation) failed: \(message)"
            }
        }

        private static func processFailureDescription(
            operation: String,
            exitStatus: Int32,
            stderr: String
        ) -> String {
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.isEmpty {
                return "\(operation) exited with status \(exitStatus)"
            }
            return "\(operation) exited with status \(exitStatus): \(detail)"
        }
    }

    private struct StatusPayload: Decodable {
        struct Permission: Decodable {
            let enabled: Bool
        }

        let permission: Permission
    }

    static let toolNotFoundExitStatus: Int32 = 72
    static let discoveryTimeoutNanoseconds: Int64 = 5_000_000_000
    static let statusTimeoutNanoseconds: Int64 = 15_000_000_000

    private let processRunner: any ProcessRunning

    init(processRunner: any ProcessRunning = ProcessRunner()) {
        self.processRunner = processRunner
    }

    func availability() async throws -> XcodeMCPServerAvailability {
        let discovery = try await run(
            operation: "mcp-server discovery",
            request: ProcessRequest(
                label: "discover-xcode-mcp-server",
                executablePath: MCPBridgeInvocation.xcrunCommand,
                arguments: ["--find", "mcp-server"],
                input: nil,
                timeoutNanoseconds: Self.discoveryTimeoutNanoseconds
            )
        )
        if discovery.terminationStatus == Self.toolNotFoundExitStatus {
            return .unavailable
        }
        guard discovery.terminationStatus == 0 else {
            throw Failure.discoveryFailed(
                exitStatus: discovery.terminationStatus,
                stderr: discovery.stderr
            )
        }
        let mcpServerPath = discovery.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard mcpServerPath.isEmpty == false else {
            throw Failure.discoveryReturnedNoPath
        }

        let status = try await run(
            operation: "mcp-server status",
            request: ProcessRequest(
                label: "read-xcode-mcp-server-status",
                executablePath: mcpServerPath,
                arguments: ["status", "--format", "json"],
                input: nil,
                timeoutNanoseconds: Self.statusTimeoutNanoseconds
            )
        )
        if let payload = try? JSONDecoder().decode(
            StatusPayload.self,
            from: Data(status.stdout.utf8)
        ) {
            return payload.permission.enabled ? .enabled : .disabled
        }
        guard status.terminationStatus == 0 else {
            throw Failure.statusFailed(
                exitStatus: status.terminationStatus,
                stderr: status.stderr
            )
        }
        throw Failure.malformedStatus
    }

    private func run(
        operation: String,
        request: ProcessRequest
    ) async throws -> ProcessOutput {
        do {
            return try await processRunner.run(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch is ProcessTimeoutError {
            throw Failure.timedOut(operation: operation)
        } catch {
            throw Failure.executionFailed(
                operation: operation,
                message: String(describing: error)
            )
        }
    }
}

enum XcodeConnectionModeResolver {
    enum Diagnostic: Equatable, Sendable {
        case notice(String)
        case warning(String)
    }

    struct Resolution: Equatable, Sendable {
        let xcodeMode: ProxyRuntimeConfiguration.XcodeMode
        let diagnostic: Diagnostic?
    }

    static let disabledNotice = """
        Xcode 27 headless MCP is available but disabled.

        To enable it, run:

            sudo xcrun mcp-server enable

        XcodeMCPKit will continue using GUI Xcode routing.
        """

    static func resolve(
        config: ProxyConfig,
        availability: @Sendable () async throws -> XcodeMCPServerAvailability
    ) async throws -> Resolution {
        if config.upstreamKind == .custom {
            guard config.xcodeMode == .automatic else {
                throw XcodeMCPProxyServer.LifecycleError.invalidConfiguration(
                    "xcodeMode must be automatic when using a custom upstream"
                )
            }
            return Resolution(xcodeMode: .custom, diagnostic: nil)
        }

        switch config.xcodeMode {
        case .gui:
            return Resolution(xcodeMode: .gui, diagnostic: nil)
        case .automatic:
            do {
                switch try await availability() {
                case .unavailable:
                    return Resolution(xcodeMode: .gui, diagnostic: nil)
                case .disabled:
                    return Resolution(
                        xcodeMode: .gui,
                        diagnostic: .notice(disabledNotice)
                    )
                case .enabled:
                    return Resolution(xcodeMode: .headless, diagnostic: nil)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return Resolution(
                    xcodeMode: .gui,
                    diagnostic: .warning(automaticFailureWarning(error))
                )
            }
        case .headless:
            do {
                switch try await availability() {
                case .enabled:
                    return Resolution(xcodeMode: .headless, diagnostic: nil)
                case .disabled:
                    throw XcodeMCPProxyServer.LifecycleError.invalidConfiguration(
                        explicitDisabledMessage
                    )
                case .unavailable:
                    throw XcodeMCPProxyServer.LifecycleError.invalidConfiguration(
                        "Xcode headless MCP is unavailable because the selected Xcode does not provide mcp-server."
                    )
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as XcodeMCPProxyServer.LifecycleError {
                throw error
            } catch {
                throw XcodeMCPProxyServer.LifecycleError.invalidConfiguration(
                    "Unable to determine Xcode headless MCP status: \(error)"
                )
            }
        }
    }

    private static let explicitDisabledMessage = """
        Xcode headless MCP is disabled.

        To enable it, run:

            sudo xcrun mcp-server enable
        """

    private static func automaticFailureWarning(_ error: any Error) -> String {
        """
        Unable to determine Xcode headless MCP status: \(error)

        XcodeMCPKit will continue using GUI Xcode routing.
        """
    }
}
