@testable import XcodeMCPCore
import Foundation
import Testing
import XcodeMCPKit
@testable import XcodeMCPProxyKit
import XcodeMCPProxyRuntime

@Suite
struct XcodeMCPServerStatusClientTests {
    @Test func unavailableToolIsANormalAvailabilityResult() async throws {
        let requests = StatusLockedBox<[ProcessRequest]>([])
        let client = makeClient(requests: requests) { _ in
            ProcessOutput(
                terminationStatus: XcodeMCPServerStatusClient.toolNotFoundExitStatus,
                stdout: "",
                stderr: "xcrun: error: unable to find utility"
            )
        }

        #expect(try await client.availability() == .unavailable)
        #expect(requests.withLockedValue { $0.count } == 1)
    }

    @Test func disabledStatusDecodesOnlyPermissionEnabled() async throws {
        let client = makeClient { request in
            if request.label == "discover-xcode-mcp-server" {
                return foundToolOutput()
            }
            return ProcessOutput(
                terminationStatus: 0,
                stdout: """
                    {
                      "openWorkspaces": [],
                      "permission": {
                        "enabled": false,
                        "unsafeAlwaysAllowAllAgents": false
                      },
                      "running": false,
                      "futureField": { "value": 1 }
                    }
                    """,
                stderr: ""
            )
        }

        #expect(try await client.availability() == .disabled)
    }

    @Test func emptyDiscoveredExecutablePathIsRejectedBeforeStatus() async {
        let requests = StatusLockedBox<[ProcessRequest]>([])
        let client = makeClient(requests: requests) { _ in
            ProcessOutput(terminationStatus: 0, stdout: " \n", stderr: "")
        }

        await #expect(throws: XcodeMCPServerStatusClient.Failure.discoveryReturnedNoPath) {
            _ = try await client.availability()
        }
        #expect(requests.withLockedValue { $0.count } == 1)
    }

    @Test func enabledStatusAcceptsDynamicOpenWorkspacesAndNonzeroExit() async throws {
        let client = makeClient { request in
            if request.label == "discover-xcode-mcp-server" {
                return foundToolOutput()
            }
            return ProcessOutput(
                terminationStatus: 1,
                stdout: """
                    {
                      "openWorkspaces": [
                        {
                          "path": "/tmp/App.xcworkspace",
                          "displayName": "App",
                          "activeSchemeName": "App"
                        }
                      ],
                      "permission": {
                        "enabled": true,
                        "unsafeAlwaysAllowAllAgents": false
                      },
                      "running": true
                    }
                    """,
                stderr: "mcp-server: warning: live service query timed out"
            )
        }

        #expect(try await client.availability() == .enabled)
    }

    @Test func malformedSuccessfulStatusIsDiagnosticFailure() async {
        let client = makeClient { request in
            request.label == "discover-xcode-mcp-server"
                ? foundToolOutput()
                : ProcessOutput(terminationStatus: 0, stdout: "{}", stderr: "")
        }

        await #expect(throws: XcodeMCPServerStatusClient.Failure.malformedStatus) {
            _ = try await client.availability()
        }
    }

    @Test func statusFailurePreservesExitDiagnosticsWhenJSONIsInvalid() async {
        let client = makeClient { request in
            request.label == "discover-xcode-mcp-server"
                ? foundToolOutput()
                : ProcessOutput(
                    terminationStatus: 2,
                    stdout: "not-json",
                    stderr: "status failed"
                )
        }

        await #expect(
            throws: XcodeMCPServerStatusClient.Failure.statusFailed(
                exitStatus: 2,
                stderr: "status failed"
            )
        ) {
            _ = try await client.availability()
        }
    }

    @Test func timeoutIsReportedAndCancellationRemainsCancellation() async {
        let timeoutClient = makeClient { request in
            throw ProcessTimeoutError(label: request.label)
        }
        await #expect(
            throws: XcodeMCPServerStatusClient.Failure.timedOut(
                operation: "mcp-server discovery"
            )
        ) {
            _ = try await timeoutClient.availability()
        }

        let cancelledClient = makeClient { _ in
            throw CancellationError()
        }
        await #expect(throws: CancellationError.self) {
            _ = try await cancelledClient.availability()
        }
    }

    @Test func statusCommandsUseBoundedProcessRunnerRequests() async throws {
        let requests = StatusLockedBox<[ProcessRequest]>([])
        let client = makeClient(requests: requests) { request in
            request.label == "discover-xcode-mcp-server"
                ? foundToolOutput()
                : enabledStatusOutput()
        }

        _ = try await client.availability()
        let recorded = requests.withLockedValue { $0 }
        #expect(recorded.count == 2)
        #expect(recorded[0].executablePath == MCPBridgeInvocation.xcrunCommand)
        #expect(recorded[0].arguments == ["--find", "mcp-server"])
        #expect(
            recorded[0].timeoutNanoseconds
                == XcodeMCPServerStatusClient.discoveryTimeoutNanoseconds
        )
        #expect(
            recorded[1].executablePath
                == "/Applications/Xcode.app/Contents/Developer/usr/bin/mcp-server"
        )
        #expect(recorded[1].arguments == ["status", "--format", "json"])
        #expect(
            recorded[1].timeoutNanoseconds
                == XcodeMCPServerStatusClient.statusTimeoutNanoseconds
        )
    }
}

private struct StubProcessRunner: ProcessRunning {
    let runOperation: @Sendable (ProcessRequest) async throws -> ProcessOutput

    func run(_ request: ProcessRequest) async throws -> ProcessOutput {
        try await runOperation(request)
    }
}

private func makeClient(
    requests: StatusLockedBox<[ProcessRequest]>? = nil,
    run: @escaping @Sendable (ProcessRequest) async throws -> ProcessOutput
) -> XcodeMCPServerStatusClient {
    XcodeMCPServerStatusClient(
        processRunner: StubProcessRunner { request in
            requests?.withLockedValue { $0.append(request) }
            return try await run(request)
        }
    )
}

private func foundToolOutput() -> ProcessOutput {
    ProcessOutput(
        terminationStatus: 0,
        stdout: "/Applications/Xcode.app/Contents/Developer/usr/bin/mcp-server\n",
        stderr: ""
    )
}

private func enabledStatusOutput() -> ProcessOutput {
    ProcessOutput(
        terminationStatus: 0,
        stdout: #"{"permission":{"enabled":true}}"#,
        stderr: ""
    )
}

private enum ProbeFailure: Error {
    case expected
}

private final class StatusLockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withLockedValue<Result>(_ operation: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return operation(&value)
    }
}
