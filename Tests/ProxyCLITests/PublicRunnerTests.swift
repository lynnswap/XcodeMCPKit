import Foundation
import Testing
import XcodeMCPKit
import XcodeMCPProxyKit

@Suite
struct PublicRunnerTests {
    @Test func adapterPublicLifecycleIsOneShotAndStopIsIdempotent() async throws {
        let input = Pipe()
        let output = Pipe()
        let adapter = try XcodeMCPProxyStdioAdapter(
            configuration: .init(
                endpoint: .url(URL(string: "http://127.0.0.1:1/mcp")!),
                requestTimeout: nil
            ),
            input: input.fileHandleForReading,
            output: output.fileHandleForWriting
        )

        try await adapter.start()
        #expect(await adapter.connectionState().phase == .initializing)
        await #expect(throws: XcodeMCPError.invalidRequest(
            "STDIO adapter can only be started once"
        )) {
            try await adapter.start()
        }
        await adapter.stop()
        await adapter.stop()
        await adapter.waitUntilStopped()
        #expect(await adapter.connectionState().phase == .closed(.requested))

        input.fileHandleForWriting.closeFile()
        output.fileHandleForWriting.closeFile()
    }

    @Test func adapterInitializerRejectsInvalidEndpointAndTimeout() {
        #expect(throws: XcodeMCPError.invalidRequest(
            "endpoint must be an http/https URL"
        )) {
            _ = try XcodeMCPProxyStdioAdapter(
                configuration: .init(endpoint: .url(URL(fileURLWithPath: "/tmp/mcp")))
            )
        }
        #expect(throws: XcodeMCPError.invalidRequest(
            "requestTimeout must be greater than zero; use nil to disable timeouts"
        )) {
            _ = try XcodeMCPProxyStdioAdapter(
                configuration: .init(requestTimeout: .zero)
            )
        }
    }

    @Test func adapterExplicitDiscoveryDoesNotFallback() {
        let fileURL = URL(fileURLWithPath: "/tmp/missing-adapter-discovery-\(UUID()).json")
        #expect(throws: XcodeMCPError.transportUnavailable(
            "Proxy discovery file is missing or invalid: \(fileURL.path)"
        )) {
            _ = try XcodeMCPProxyStdioAdapter(
                configuration: .init(endpoint: .discoveryFile(fileURL))
            )
        }
    }

    @Test func serverRunnerPrintsVersionThroughPublicAPI() async throws {
        let output = CapturedLines()
        let errors = CapturedLines()

        let exitCode = await XcodeMCPProxyServer.run(
            arguments: ["xcode-mcp-proxy-server", "--version"],
            environment: [:],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )

        #expect(exitCode == 0)
        #expect(output.snapshot() == ["xcode-mcp-proxy-server \(XcodeMCPProxyServer.productMetadata.version)"])
        #expect(errors.snapshot().isEmpty)
    }

    @Test func stdioAdapterRunnerRoutesValidationErrorsToStderr() async throws {
        let output = CapturedLines()
        let errors = CapturedLines()

        let exitCode = await XcodeMCPProxyStdioAdapter.run(
            arguments: [
                "xcode-mcp-proxy",
                "--stdio",
            ],
            environment: [:],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )

        #expect(exitCode == 1)
        #expect(output.snapshot().isEmpty)
        let errorLines = errors.snapshot()
        #expect(errorLines.contains("Unknown argument: --stdio"))
        #expect(errorLines.contains { $0.contains("Usage:") })
    }

    @Test func installerRunnerPrintsVersionThroughPublicAPI() throws {
        let output = CapturedLines()
        let errors = CapturedLines()

        let exitCode = XcodeMCPProxyInstaller.run(
            arguments: ["xcode-mcp-proxy-install", "--version"],
            environment: [:],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )

        #expect(exitCode == 0)
        #expect(output.snapshot() == ["xcode-mcp-proxy-install \(XcodeMCPProxyServer.productMetadata.version)"])
        #expect(errors.snapshot().isEmpty)
    }
}
