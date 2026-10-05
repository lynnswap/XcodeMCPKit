import Foundation
import Testing
import XcodeMCPKit
import XcodeMCPProxyKit

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["XCODE_MCP_RUN_NATIVE_TESTS"] == "1"))
struct NativeHostLiveTests {
    @Test func standaloneHostProvidesTheDynamicCatalogAndClosesCleanly() async throws {
        let client = try await XcodeMCP(configuration: .init(transport: .localBridge(.nativeHost()), requestTimeout: .seconds(120)))
        do {
            let tools = try await client.listTools()
            #expect(tools.contains { $0.name == "DocumentationSearch" })
            #expect(tools.contains { $0.name == "XcodeOpenWorkspace" })
            let workspaces = try await client.callTool("XcodeListWorkspaces")
            #expect(!workspaces.isError)
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
