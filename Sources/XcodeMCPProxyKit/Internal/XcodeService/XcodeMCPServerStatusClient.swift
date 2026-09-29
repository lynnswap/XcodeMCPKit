import XcodeMCPCore
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
