import Foundation
import Testing
@testable import XcodeMCPCore

@Suite
struct NativeHostInvocationTests {
    @Test func explicitBundlePreservesTheSelectedXcodeAndGUIOwner() throws {
        var fileSystem = FileSystemClient.testValue
        fileSystem.isExecutableFile = { $0 == "/embedded/Owned.app/Contents/MacOS/xcode-mcp-native-host" }
        let invocation = try NativeHostInvocation.resolve(
            bundleURL: URL(fileURLWithPath: "/embedded/Owned.app"),
            developerDirectoryURL: URL(fileURLWithPath: "/Applications/Xcode.app"), guiPID: 73,
            environment: [:], executableURL: nil, fileSystem: fileSystem)
        #expect(invocation.command == "/embedded/Owned.app/Contents/MacOS/xcode-mcp-native-host")
        #expect(invocation.arguments == ["--developer-dir", "/Applications/Xcode.app", "--gui-pid", "73"])
    }

    @Test func explicitMissingBundleDoesNotSelectAnotherInstalledHelper() {
        var fileSystem = FileSystemClient.testValue
        fileSystem.isExecutableFile = { $0 == "/installed/XcodeMCPNativeHost.app/Contents/MacOS/xcode-mcp-native-host" }
        #expect(throws: MCPBridgeRuntimeError.self) {
            try NativeHostInvocation.resolve(bundleURL: URL(fileURLWithPath: "/missing.app"),
                environment: ["PATH": "/installed"], executableURL: nil, fileSystem: fileSystem)
        }
    }

    @Test func environmentBundleOverrideIsAuthoritative() throws {
        var fileSystem = FileSystemClient.testValue
        fileSystem.isExecutableFile = { $0 == "/embedded/Helper.app/Contents/MacOS/xcode-mcp-native-host" }
        let invocation = try NativeHostInvocation.resolve(
            environment: ["XCODE_MCP_NATIVE_HOST_BUNDLE": "/embedded/Helper.app"],
            executableURL: nil, fileSystem: fileSystem)
        #expect(invocation.command == "/embedded/Helper.app/Contents/MacOS/xcode-mcp-native-host")
        #expect(invocation.arguments.isEmpty)
    }

    @Test(arguments: [true, false])
    func installedHelperIsDiscoveredAdjacentToTheExecutableOrOnPATH(adjacent: Bool) throws {
        var fileSystem = FileSystemClient.testValue
        fileSystem.isExecutableFile = { $0 == "/installed/XcodeMCPNativeHost.app/Contents/MacOS/xcode-mcp-native-host" }
        let invocation = try NativeHostInvocation.resolve(
            environment: adjacent ? [:] : ["PATH": "/missing:/installed"],
            executableURL: adjacent ? URL(fileURLWithPath: "/installed/xcode-mcp-proxy-server") : nil,
            fileSystem: fileSystem)
        #expect(invocation.command == "/installed/XcodeMCPNativeHost.app/Contents/MacOS/xcode-mcp-native-host")
    }
}
