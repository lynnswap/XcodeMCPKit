import Foundation
import Testing
@testable import XcodeMCPProxyKit

@Suite
struct ServerCommandTests {
    @Test func serverCommandResolvesCanonicalDefaults() throws {
        let config = try resolvedConfiguration()
        #expect(config.bindAddress == .localhost())
        #expect(config.nativeHostBundleURL == nil)
        #expect(config.developerDirectoryURL == nil)
        #expect(config.maxBodyBytes == 1_048_576)
        #expect(config.requestTimeout == .seconds(300))
    }

    @Test func serverCommandMapsTypedOptionsToConfiguration() throws {
        let config = try resolvedConfiguration(arguments: [
            "--listen", "0.0.0.0:9999",
            "--max-body-bytes", "2048",
            "--request-timeout", "12.5",
        ])
        #expect(config.bindAddress == .init(host: "0.0.0.0", port: 9999))
        #expect(config.maxBodyBytes == 2048)
        #expect(config.requestTimeout == .seconds(12.5))
    }

    @Test func serverCommandAllowsPortZeroAndZeroTimeout() throws {
        let config = try resolvedConfiguration(arguments: [
            "--host", "localhost", "--port", "0", "--request-timeout", "0",
        ])
        #expect(config.bindAddress == .localhost(port: 0))
        #expect(config.requestTimeout == nil)
    }

    @Test(arguments: [
        ["--listen", "localhost"], ["--port", "-1"], ["--port", "65536"],
        ["--port", "not-a-port"], ["--max-body-bytes", "0"], ["--max-body-bytes", "-1"],
        ["--request-timeout", "-1"], ["--request-timeout", "nan"], ["--request-timeout", "inf"],
    ])
    func serverCommandRejectsInvalidValues(arguments: [String]) {
        #expect(throws: CLICommandError.self) {
            _ = try resolvedConfiguration(arguments: arguments)
        }
    }

    @Test(arguments: [
        "--auto-approve", "--config", "--native-host-bundle", "--developer-dir", "--refresh-code-issues-mode",
        "--upstream-processes", "--xcode-mode", "--session-id", "--upstream-command",
        "--upstream-args", "--upstream-arg",
    ])
    func serverCommandRejectsRemovedOptions(option: String) {
        #expect(throws: CLICommandError.self) {
            _ = try resolvedConfiguration(arguments: [option, "value"])
        }
        #expect(!XcodeMCPProxyServer.serverUsage.contains(option + " "))
    }

    @Test func nativeSelectionIsPreservedFromTheLaunchEnvironment() throws {
        let config = try resolvedConfiguration(environment: [
            "DEVELOPER_DIR": "/Applications/Selected Xcode.app",
            "XCODE_MCP_NATIVE_HOST_BUNDLE": "/tmp/Native Host.app",
        ])
        #expect(config.nativeHostBundleURL?.path == "/tmp/Native Host.app")
        #expect(config.developerDirectoryURL?.path == "/Applications/Selected Xcode.app")
    }

    @Test func emptyNativeEnvironmentValuesRemainExplicitOverrides() throws {
        let config = try resolvedConfiguration(environment: [
            "DEVELOPER_DIR": "",
            "XCODE_MCP_NATIVE_HOST_BUNDLE": "",
        ])
        #expect(config.nativeHostBundleURL != nil)
        #expect(config.developerDirectoryURL != nil)
    }

    @Test func removedConfigurationEnvironmentDoesNotAffectTheServer() throws {
        let config = try resolvedConfiguration(environment: [
            "MCP_XCODE_CONFIG": "/missing/old-config.toml",
            "MCP_XCODE_REFRESH_CODE_ISSUES_MODE": "invalid",
            "MCP_XCODE_AUTO_APPROVE": "1",
            "LAZY_INIT": "true",
        ])
        #expect(config.initializeHandshake == nil)
        #expect(config.prewarmToolsList)
    }

    @Test func dryRunUsesAutomaticNativeSelection() throws {
        let action = try XcodeMCPProxyServer.resolveLaunchAction(
            arguments: ["xcode-mcp-proxy-server", "--dry-run"],
            environment: ["DEVELOPER_DIR": "/Applications/Selected Xcode.app"]
        )
        guard case .dryRun(let command) = action else { Issue.record("expected dry run"); return }
        #expect(command == "xcode-mcp-proxy-server --listen localhost:8765")
    }

    @Test func serverCommandRejectsConflictingAddressOptions() {
        #expect(throws: CLICommandError.self) {
            _ = try resolvedConfiguration(arguments: ["--listen", "localhost:8765", "--port", "9000"])
        }
    }

    @Test func serverCommandResolvesAddressEnvironment() throws {
        let config = try resolvedConfiguration(environment: ["HOST": "127.0.0.1", "PORT": "9001"])
        #expect(config.bindAddress == .init(host: "127.0.0.1", port: 9001))
        let explicit = try resolvedConfiguration(
            arguments: ["--listen", "127.0.0.1:9002"],
            environment: ["LISTEN": "0.0.0.0:9003"]
        )
        #expect(explicit.bindAddress == .init(host: "127.0.0.1", port: 9002))
    }

    @Test func blankAddressEnvironmentValuesUseCanonicalDefaults() throws {
        let config = try resolvedConfiguration(environment: [
            "HOST": " \t\n", "PORT": "", "LISTEN": " ",
        ])
        #expect(config.bindAddress == .localhost())
    }

    @Test(arguments: [["LISTEN": "localhost"], ["PORT": "65536"]])
    func serverCommandRejectsInvalidAddressEnvironment(environment: [String: String]) {
        #expect(throws: CLICommandError.self) {
            _ = try resolvedConfiguration(environment: environment)
        }
    }
}

private func resolvedConfiguration(
    arguments: [String] = [], environment: [String: String] = [:]
) throws -> XcodeMCPProxyServerConfiguration {
    let action = try XcodeMCPProxyServer.resolveLaunchAction(
        arguments: ["xcode-mcp-proxy-server"] + arguments, environment: environment
    )
    guard case .start(let configuration, _) = action else { throw UnexpectedServerCommandAction() }
    return configuration
}

private struct UnexpectedServerCommandAction: Error {}
