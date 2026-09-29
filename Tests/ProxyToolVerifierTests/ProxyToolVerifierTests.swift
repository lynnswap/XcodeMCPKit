import Foundation
import Testing
import XcodeMCPKit
import XcodeMCPKitTesting
@testable import XcodeMCPProxyToolVerifier

struct ProxyToolVerifierTests {
    @Test func serviceFirstCatalogWaitsForGUIAndPreservesSelectedTab() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.outputRoot) }
        let runtime = XcodeMCPTestRuntime(tools: serviceTools)
        let path = fixture.rootWorkspaceURL.path
        await runtime.setToolHandler { call in
            switch call.name {
            case "XcodeListWindows":
                return result(["message": .string([
                    "* tabIdentifier: first-tab, workspacePath: \(path)",
                    "* tabIdentifier: second-tab, workspacePath: \(path)",
                ].joined(separator: "\n"))])
            case "XcodeListWorkspaces":
                return result(["message": ""])
            case "XcodeListSchemes", "XcodeGetCurrentFile", "XcodeListNavigatorIssues":
                #expect(call.arguments["tabIdentifier"] == "first-tab")
                #expect(call.arguments["workspaceIdentifier"] == nil)
                return result(["message": "ProxyToolVerifierFixture"])
            default:
                Issue.record("unexpected GUI fixture call: \(call.name)")
                return MCPToolResult(content: [], isError: true)
            }
        }
        let catalogUpdate = Task {
            while !Task.isCancelled, !(await runtime.recordedMessages()).contains(where: { $0.method == "tools/list" }) {
                await Task.yield()
            }
            guard !Task.isCancelled else { return }
            await runtime.setTools(mixedTools)
        }
        defer { catalogUpdate.cancel() }
        let failed = try await verify(runtime: runtime, fixture: fixture, noOpenXcode: false)
        #expect(!failed)
        let calls = await runtime.recordedToolCalls()
        #expect(calls.contains { $0.name == "XcodeListSchemes" })
        #expect(calls.contains { $0.name == "XcodeGetCurrentFile" })
        #expect(!calls.contains { $0.name == "XcodeOpenWorkspace" || $0.name == "DeviceInteractionStartWorkspaceSession" })
    }

    @Test(arguments: [false, true])
    func serviceOpensDedicatedWorkspaceBeforeApprovalAndClosesOnlyThatHandle(toolFails: Bool) async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.outputRoot) }
        let runtime = XcodeMCPTestRuntime(tools: mixedTools)
        let ownership = ServiceFixtureState()
        await runtime.setToolHandler { call in
            switch call.name {
            case "XcodeListWindows":
                return result(["message": "* tabIdentifier: unrelated, workspacePath: /Other/App.xcworkspace"])
            case "XcodeOpenWorkspace":
                let path = try #require(call.arguments["path"]?.stringValue)
                #expect(path != fixture.rootWorkspaceURL.path)
                #expect(path.hasPrefix(fixture.outputRoot.path + "/ServiceFixture-"))
                let document = try XMLDocument(contentsOf: URL(fileURLWithPath: path)
                    .appendingPathComponent("contents.xcworkspacedata"))
                let locations = try document.nodes(forXPath: "/Workspace/FileRef/@location")
                    .compactMap(\.stringValue)
                #expect(locations == ["absolute:" + fixture.xcodeProjectURL.path])
                await ownership.open(path)
                return result(["workspaceIdentifier": "owned-service-id", "workspacePath": .string(path)])
            case "XcodeListWorkspaces":
                guard await ownership.path != nil else {
                    return MCPToolResult(content: [.text("Call XcodeOpenWorkspace for approval", raw: ["type": "text", "text": "Call XcodeOpenWorkspace for approval"])], isError: true)
                }
                return result(["message": .string("* workspaceIdentifier: existing-shared-id, workspacePath: \(fixture.rootWorkspaceURL.path)")])
            case "XcodeCloseWorkspace":
                #expect(call.arguments["workspaceIdentifier"] == "owned-service-id")
                await ownership.close()
                return result(["message": "closed"])
            case "XcodeListSchemes", "DeviceInteractionStartWorkspaceSession":
                #expect(call.arguments["workspaceIdentifier"] == "owned-service-id")
                #expect(call.arguments["tabIdentifier"] == nil)
                return MCPToolResult(content: [], structuredContent: ["message": "ProxyToolVerifierFixture"], isError: toolFails)
            default:
                Issue.record("GUI-only tool reached Service: \(call.name)")
                return MCPToolResult(content: [], isError: true)
            }
        }
        let failed = try await verify(runtime: runtime, fixture: fixture, noOpenXcode: true)
        #expect(failed == toolFails)
        #expect(await ownership.closeCount == 1)
        let calls = await runtime.recordedToolCalls()
        let openIndex = try #require(calls.firstIndex { $0.name == "XcodeOpenWorkspace" })
        let listIndex = try #require(calls.firstIndex { $0.name == "XcodeListWorkspaces" })
        #expect(openIndex < listIndex)
        #expect(!calls.contains { ["XcodeGetCurrentFile", "XcodeListNavigatorIssues"].contains($0.name) })
    }

    private func makeFixture() throws -> FixtureLayout {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("verifier-test-\(UUID())")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        return FixtureLayout(repoRoot: URL(fileURLWithPath: "/Fixture & Project"), outputRoot: output)
    }

    private func verify(runtime: XcodeMCPTestRuntime, fixture: FixtureLayout, noOpenXcode: Bool) async throws -> Bool {
        let client = try await runtime.makeClient()
        do {
            let options = try VerifierOptions(arguments: ["--request-timeout", "2"] + (noOpenXcode ? ["--no-open-xcode"] : []))
            let failed = try await ProxyToolVerifier(options: options).verify(client: client, fixture: fixture, outputRoot: fixture.outputRoot)
            await client.close()
            return failed
        } catch {
            await client.close()
            throw error
        }
    }
}

private actor ServiceFixtureState {
    var path: String?
    var closeCount = 0
    func open(_ path: String) { self.path = path }
    func close() { closeCount += 1 }
}

private func result(_ content: [String: MCPJSONValue]) -> MCPToolResult {
    MCPToolResult(content: [], structuredContent: .object(content))
}

private func tool(_ name: String, properties: [String]) -> MCPTool {
    let schema: MCPJSONValue = ["type": "object", "properties": .object(Dictionary(uniqueKeysWithValues:
        properties.map { ($0, MCPJSONValue.object(["type": "string"])) }
    ))]
    return MCPTool(name: name, inputSchema: schema, raw: ["name": .string(name), "inputSchema": schema])
}

private let serviceTools = [
    tool("XcodeOpenWorkspace", properties: ["path"]),
    tool("XcodeListWorkspaces", properties: []),
    tool("XcodeCloseWorkspace", properties: ["workspaceIdentifier"]),
    tool("DeviceInteractionStartWorkspaceSession", properties: ["workspaceIdentifier", "sessionIdentifier"]),
]

private let mixedTools = serviceTools + [
    tool("XcodeListWindows", properties: []),
    tool("XcodeListSchemes", properties: ["tabIdentifier", "workspaceIdentifier"]),
    tool("XcodeGetCurrentFile", properties: ["tabIdentifier", "workspaceIdentifier", "includeContent", "includeSelection"]),
    tool("XcodeListNavigatorIssues", properties: ["tabIdentifier", "workspaceIdentifier", "severity"]),
]
