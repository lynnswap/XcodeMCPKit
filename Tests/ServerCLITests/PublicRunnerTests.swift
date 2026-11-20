@testable import XcodeMCPCore
import Foundation
import Darwin
import Testing
import XcodeMCPKit
import XcodeMCPServerKit

@Suite
struct PublicRunnerTests {
    @Test func requestTimeoutDefaultsAllowFiveMinutePreviews() {
        #expect(XcodeMCPConfiguration().requestTimeout == .seconds(600))
        #expect(XcodeMCPServerConfiguration().requestTimeout == nil)
    }

    @Test func serverRunnerPrintsVersionThroughPublicAPI() async throws {
        let output = CapturedLines()
        let errors = CapturedLines()

        let exitCode = await XcodeMCPServer.run(
            arguments: ["xcode-mcp-server", "--version"],
            environment: [:],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )

        #expect(exitCode == 0)
        #expect(output.snapshot() == [XcodeMCPServer.productMetadata.version])
        #expect(errors.snapshot().isEmpty)
    }

    @Test func installerRunnerPrintsVersionThroughPublicAPI() throws {
        let output = CapturedLines()
        let errors = CapturedLines()

        let exitCode = XcodeMCPInstaller.run(
            arguments: ["xcode-mcp-install", "--version"],
            environment: [:],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )

        #expect(exitCode == 0)
        #expect(output.snapshot() == [XcodeMCPServer.productMetadata.version])
        #expect(errors.snapshot().isEmpty)
    }
}
