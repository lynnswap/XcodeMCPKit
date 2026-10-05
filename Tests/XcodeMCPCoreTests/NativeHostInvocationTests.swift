import Foundation
import Testing
@testable import XcodeMCPCore

@Suite
struct NativeHostInvocationTests {
    @Test func standaloneClientFindsTheHelperThroughAHomebrewServerLink() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? manager.removeItem(at: root) }
        let bin = root.appendingPathComponent("bin")
        let libexec = root.appendingPathComponent("Cellar/xcode-mcpkit/1.0.0/libexec")
        let helper = libexec.appendingPathComponent("XcodeMCPNativeHost.app/Contents/MacOS/xcode-mcp-native-host")
        try manager.createDirectory(at: bin, withIntermediateDirectories: true)
        try manager.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: helper)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let server = libexec.appendingPathComponent("xcode-mcp-proxy-server")
        try Data().write(to: server)
        try manager.createSymbolicLink(at: bin.appendingPathComponent("xcode-mcp-proxy-server"), withDestinationURL: server)

        let invocation = try NativeHostInvocation.resolve(
            environment: ["PATH": bin.path], executableURL: nil)
        #expect(invocation.command == helper.resolvingSymlinksInPath().path)
    }

    @Test func explicitBundlePreservesTheSelectedXcode() throws {
        var fileSystem = FileSystemClient.testValue
        fileSystem.isExecutableFile = { $0 == "/embedded/Owned.app/Contents/MacOS/xcode-mcp-native-host" }
        let invocation = try NativeHostInvocation.resolve(
            bundleURL: URL(fileURLWithPath: "/embedded/Owned.app"),
            developerDirectoryURL: URL(fileURLWithPath: "/Applications/Xcode.app"),
            environment: [:], executableURL: nil, fileSystem: fileSystem)
        #expect(invocation.command == "/embedded/Owned.app/Contents/MacOS/xcode-mcp-native-host")
        #expect(invocation.arguments == ["--developer-dir", "/Applications/Xcode.app"])
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
