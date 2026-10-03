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
            let windows = try await client.callTool("XcodeListWindows")
            #expect(!windows.isError)
            await client.close()
        } catch {
            await client.close()
            throw error
        }
    }

    @Test func installedProxyPublishesTheNativeCatalogWithoutServiceSetup() async throws {
        let server = XcodeMCPProxyServer(configuration: .init(bindAddress: .localhost(port: 0),
            discovery: .disabled, approvalPolicy: .automatic))
        let endpoint = try await server.start()
        do {
            let client = try await XcodeMCP(configuration: .init(transport: .streamableHTTP(endpoint: endpoint.url), requestTimeout: .seconds(120)))
            do {
                let tools = try await client.listTools()
                #expect(tools.contains { $0.name == "XcodeOpenWorkspace" })
                #expect(tools.contains { $0.name == "XcodeListWindows" })
                #expect(tools.contains { $0.name == "DocumentationSearch" })
                await client.close()
            } catch {
                await client.close()
                throw error
            }
            try await server.shutdown()
        } catch {
            do { try await server.shutdown() }
            catch let cleanupError {
                Issue.record("Proxy cleanup also failed: \(cleanupError)")
            }
            throw error
        }
    }
}
