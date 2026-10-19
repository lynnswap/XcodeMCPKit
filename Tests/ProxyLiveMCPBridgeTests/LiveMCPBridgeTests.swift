import Foundation
import Testing
import XcodeMCPKit
import XcodeMCPProxyKit

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["XCODE_MCP_RUN_NATIVE_TESTS"] == "1"))
struct NativeHostLiveTests {
    @Test func packageManifestAndDirectoryShareOneNativeWorkspace() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PackageWorkspaceProbe-\(UUID().uuidString)", isDirectory: true)
        let source = directory.appendingPathComponent("Sources/PackageWorkspaceProbe/Probe.swift")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = directory.appendingPathComponent("Package.swift")
        let dependencySource = directory.appendingPathComponent("Dependency/Sources/SlowDependency/Dependency.swift")
        try FileManager.default.createDirectory(at: dependencySource.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "public let dependencyValue = 1".write(to: dependencySource, atomically: true, encoding: .utf8)
        // Keep dependency resolution pending beyond the native registry's ten-second destination timer.
        try """
        // swift-tools-version: 6.3
        import Foundation
        import PackageDescription
        Thread.sleep(forTimeInterval: 12)
        let package = Package(name: "SlowDependency", products: [
            .library(name: "SlowDependency", targets: ["SlowDependency"])
        ], targets: [.target(name: "SlowDependency")])
        """.write(to: directory.appendingPathComponent("Dependency/Package.swift"), atomically: true, encoding: .utf8)
        try """
        // swift-tools-version: 6.3
        import PackageDescription
        let package = Package(name: "PackageWorkspaceProbe", products: [
            .library(name: "PackageWorkspaceProbe", targets: ["PackageWorkspaceProbe"])
        ], dependencies: [.package(path: "Dependency")], targets: [
            .target(name: "PackageWorkspaceProbe", dependencies: [.product(name: "SlowDependency", package: "Dependency")])
        ])
        """.write(to: manifest, atomically: true, encoding: .utf8)
        try "public let value = 1".write(to: source, atomically: true, encoding: .utf8)

        let client = try await XcodeMCP(configuration: .init(transport: .localBridge(.nativeHost()), requestTimeout: .seconds(120)))
        do {
            let fromManifest = try await client.callTool("XcodeOpenWorkspace", arguments: ["path": .string(manifest.path)])
            #expect(!fromManifest.isError)
            let fromDirectory = try await client.callTool("XcodeOpenWorkspace", arguments: ["path": .string(directory.path)])
            #expect(!fromDirectory.isError)
            let identifier = try #require(fromManifest.structuredContent?["workspaceIdentifier"])
            #expect(fromDirectory.structuredContent?["workspaceIdentifier"] == identifier)
            let closed = try await client.callTool("XcodeCloseWorkspace", arguments: ["workspaceIdentifier": .string(manifest.path)])
            #expect(!closed.isError)
            let schemes = try await client.callTool("XcodeListSchemes", arguments: ["workspaceIdentifier": .string(manifest.path)])
            #expect(!schemes.isError)
            #expect(schemes.structuredContent?["activeSchemeName"] == .string("PackageWorkspaceProbe"))
            await client.close()
        } catch {
            await client.close()
            throw error
        }
    }

    @Test func standaloneHostProvidesTheDynamicCatalogAndClosesCleanly() async throws {
        let client = try await XcodeMCP(configuration: .init(transport: .localBridge(.nativeHost()), requestTimeout: .seconds(120)))
        do {
            let tools = try await client.listTools()
            #expect(tools.contains { $0.name == "DocumentationSearch" })
            #expect(tools.contains { $0.name == "XcodeOpenWorkspace" })
            let workspaces = try await client.callTool("XcodeListWorkspaces")
            #expect(!workspaces.isError)
            let documents = try await client.callTool("DocumentationSearch", arguments: ["query": "SwiftUI NavigationStack"])
            #expect(!documents.isError)
            #expect(!tools.contains { $0.name == "XcodeListWindows" })
            await client.close()
        } catch {
            await client.close()
            throw error
        }
    }

    @Test func installedProxyPublishesTheNativeCatalogWithoutServiceSetup() async throws {
        let server = XcodeMCPProxyServer(configuration: .init(bindAddress: .localhost(port: 0),
            discovery: .disabled))
        let endpoint = try await server.start()
        do {
            let client = try await XcodeMCP(configuration: .init(transport: .streamableHTTP(endpoint: endpoint.url), requestTimeout: .seconds(120)))
            do {
                let tools = try await client.listTools()
                #expect(tools.contains { $0.name == "XcodeOpenWorkspace" })
                #expect(!tools.contains { $0.name == "XcodeListWindows" })
                #expect(tools.contains { $0.name == "DocumentationSearch" })
                let documents = try await client.callTool("DocumentationSearch", arguments: ["query": "SwiftUI NavigationStack"])
                #expect(!documents.isError)
                await client.close()
            } catch {
                await client.close()
                throw error
            }
            try await server.shutdown()
            try await server.shutdown()
            let stopped = await server.snapshot()
            #expect(stopped.phase == .stopped)
        } catch {
            do { try await server.shutdown() }
            catch let cleanupError {
                Issue.record("Proxy cleanup also failed: \(cleanupError)")
            }
            throw error
        }
    }
}
