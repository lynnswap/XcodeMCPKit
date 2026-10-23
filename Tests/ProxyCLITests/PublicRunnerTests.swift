@testable import XcodeMCPCore
import Foundation
import Darwin
import Testing
import XcodeMCPKit
import XcodeMCPProxyKit

@Suite
struct PublicRunnerTests {
    @Test func requestTimeoutDefaultsAllowFiveMinutePreviews() {
        #expect(XcodeMCPConfiguration().requestTimeout == .seconds(600))
        #expect(XcodeMCPProxyServerConfiguration().requestTimeout == nil)
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
        #expect(output.snapshot() == [XcodeMCPProxyServer.productMetadata.version])
        #expect(errors.snapshot().isEmpty)
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
        #expect(output.snapshot() == [XcodeMCPProxyServer.productMetadata.version])
        #expect(errors.snapshot().isEmpty)
    }
}
