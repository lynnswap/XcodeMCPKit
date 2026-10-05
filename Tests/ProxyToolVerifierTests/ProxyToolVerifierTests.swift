import Foundation
import Testing
import XcodeMCPKit
import XcodeMCPKitTesting
@testable import XcodeMCPProxyToolVerifier

struct ProxyToolVerifierTests {
    @Test func repeatedOutputDirectoryKeepsBothGeneratedProjects() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.outputRoot) }
        let runtime = XcodeMCPTestRuntime(tools: [
            tool("XcodeOpenWorkspace", properties: ["path"]),
            tool("XcodeCloseWorkspace", properties: ["workspaceIdentifier"]),
            tool("XcodeNewProject", properties: ["templateIdentifier", "productName", "destinationPath", "organizationIdentifier", "options"]),
        ])
        await runtime.setToolHandler { call in
            if call.name == "XcodeOpenWorkspace" { return result(["workspaceIdentifier": "owned-native-id"]) }
            if call.name == "XcodeNewProject" {
                let destination = URL(fileURLWithPath: try #require(call.arguments["destinationPath"]?.stringValue))
                let name = try #require(call.arguments["productName"]?.stringValue)
                let project = destination.appendingPathComponent(name + ".xcodeproj")
                try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
                try Data("native generated contents".utf8).write(to: project.appendingPathComponent("project.pbxproj"))
                return result(["projectPath": .string(project.path)])
            }
            return result(["message": "closed"])
        }
        for _ in 0..<2 {
            #expect(try await !verify(runtime: runtime, fixture: fixture))
        }
        let calls = await runtime.recordedToolCalls().filter { $0.name == "XcodeNewProject" }
        #expect(calls.count == 2)
        let destinations = try calls.map { URL(fileURLWithPath: try #require($0.arguments["destinationPath"]?.stringValue)) }
        #expect(Set(destinations).count == 2)
        for destination in destinations {
            var relationship = FileManager.URLRelationship.other
            try FileManager.default.getRelationship(&relationship, ofDirectoryAt: fixture.outputRoot, toItemAt: destination)
            #expect(relationship == .contains)
            let contents = destination.appendingPathComponent("ProxyVerifierGeneratedCLI.xcodeproj/project.pbxproj")
            #expect(try String(contentsOf: contents, encoding: .utf8) == "native generated contents")
        }
    }

    @Test(arguments: ["success", "result"])
    func nativeFalseCompletionIsReportedAsFailure(flag: String) async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.outputRoot) }
        let runtime = XcodeMCPTestRuntime(tools: [
            tool("XcodeOpenWorkspace", properties: ["path"]),
            tool("XcodeCloseWorkspace", properties: ["workspaceIdentifier"]),
            tool("AddEntitlement", properties: ["workspaceIdentifier", "targetName", "entitlementKey", "entitlementValueType", "entitlementValue"]),
        ])
        await runtime.setToolHandler { call in
            if call.name == "XcodeOpenWorkspace" { return result(["workspaceIdentifier": "owned-native-id"]) }
            if call.name == "AddEntitlement" {
                return result([flag: false, "errorDescription": "Native rejected the entitlement"])
            }
            return result(["message": "closed"])
        }
        #expect(try await verify(runtime: runtime, fixture: fixture))
    }

    @Test func navigatorOperationsUseNativeCreatedDirectoryPath() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.outputRoot) }
        let directory = "ProxyToolVerifierFixture/VerifierScratch 2"
        let runtime = XcodeMCPTestRuntime(tools: [
            tool("XcodeOpenWorkspace", properties: ["path"]),
            tool("XcodeCloseWorkspace", properties: ["workspaceIdentifier"]),
            tool("XcodeMakeDir", properties: ["workspaceIdentifier", "directoryPath"]),
            tool("XcodeWrite", properties: ["workspaceIdentifier", "filePath", "content"]),
            tool("XcodeUpdate", properties: ["workspaceIdentifier", "filePath", "oldString", "newString", "replaceAll"]),
            tool("XcodeMV", properties: ["workspaceIdentifier", "sourcePath", "destinationPath", "operation", "overwriteExisting"]),
            tool("XcodeRM", properties: ["workspaceIdentifier", "path", "recursive", "deleteFiles"]),
        ])
        await runtime.setToolHandler { call in
            switch call.name {
            case "XcodeOpenWorkspace": return result(["workspaceIdentifier": "owned-native-id"])
            case "XcodeMakeDir": return result(["createdPath": .string(directory), "success": true])
            case "XcodeWrite", "XcodeUpdate": #expect(call.arguments["filePath"] == .string(directory + "/probe.txt"))
            case "XcodeMV":
                #expect(call.arguments["sourcePath"] == .string(directory + "/probe.txt"))
                #expect(call.arguments["destinationPath"] == .string(directory + "/probe-moved.txt"))
            case "XcodeRM": #expect(call.arguments["path"] == .string(directory + "/probe-moved.txt"))
            default: break
            }
            return result(["message": "ok"])
        }
        #expect(try await !verify(runtime: runtime, fixture: fixture))
        #expect(await runtime.recordedToolCalls().contains { $0.name == "XcodeRM" })
    }

    @Test(arguments: ["XcodeSwitchScheme", "XcodeSwitchRunDestination", "XcodeSwitchTestPlan"])
    func selectionFailureStopsRuntimeOperationsAndClosesOwnedWorkspace(selectionTool: String) async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.outputRoot) }
        let runtime = XcodeMCPTestRuntime(tools: [
            tool("XcodeOpenWorkspace", properties: ["path"]),
            tool("XcodeCloseWorkspace", properties: ["workspaceIdentifier"]),
            tool("XcodeListTestPlans", properties: ["workspaceIdentifier"]),
            tool(selectionTool, properties: ["workspaceIdentifier", "schemeName", "displayTitle", "testPlanName"]),
            tool("BuildProject", properties: ["workspaceIdentifier", "buildForTesting"]),
        ])
        await runtime.setToolHandler { call in
            switch call.name {
            case "XcodeOpenWorkspace": return result(["workspaceIdentifier": "owned-native-id"])
            case "XcodeListTestPlans": return result(["activeTestPlanName": "Native Plan"])
            case selectionTool: return MCPToolResult(content: [], isError: true)
            case "XcodeCloseWorkspace": return result(["message": "closed"])
            default:
                Issue.record("runtime operation followed a failed fixture selection")
                return result(["message": "unexpected"])
            }
        }
        do {
            _ = try await verify(runtime: runtime, fixture: fixture)
            Issue.record("verification continued after a failed fixture selection")
        } catch {}
        let calls = await runtime.recordedToolCalls()
        #expect(!calls.contains { $0.name == "BuildProject" })
        #expect(calls.last?.name == "XcodeCloseWorkspace")
    }

    @Test func bothDeviceSessionKindsCloseTheirOwnedSession() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.outputRoot) }
        let recentIdentifiers = RecentDeviceSessionIdentifiers()
        let runtime = XcodeMCPTestRuntime(tools: [
            tool("XcodeOpenWorkspace", properties: ["path"]),
            tool("XcodeCloseWorkspace", properties: ["workspaceIdentifier"]),
            tool("DeviceInteractionStartSession", properties: ["sessionIdentifier", "deviceIdentifier"]),
            tool("DeviceInteractionStartWorkspaceSession", properties: ["workspaceIdentifier", "sessionIdentifier", "deviceIdentifier"]),
            tool("DeviceInteractionEndSession", properties: ["interactionSessionKey"]),
        ])
        await runtime.setToolHandler { call in
            switch call.name {
            case "XcodeOpenWorkspace": return result(["workspaceIdentifier": "owned-native-id"])
            case "DeviceInteractionStartSession", "DeviceInteractionStartWorkspaceSession":
                let identifier = try #require(call.arguments["sessionIdentifier"]?.stringValue)
                #expect(await recentIdentifiers.insert(identifier))
                #expect(call.arguments["deviceIdentifier"] == "owned-device-id")
                #expect(call.arguments["workspaceIdentifier"] == (call.name == "DeviceInteractionStartSession" ? nil : "owned-native-id"))
                return result(["interactionSessionKey": .string(call.name)])
            default: return result(["message": "ok"])
            }
        }
        #expect(try await !verify(runtime: runtime, fixture: fixture,
            deviceIdentifier: "owned-device-id"))
        let calls = await runtime.recordedToolCalls()
        #expect(calls.filter { $0.name == "DeviceInteractionEndSession" }
            .compactMap { $0.arguments["interactionSessionKey"]?.stringValue }
            == ["DeviceInteractionStartSession", "DeviceInteractionStartWorkspaceSession"])
    }

    @Test func nativeConfigurationPlansUseDisposableProjectAndRunCreationAfterBuild() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.outputRoot) }
        let original = fixture.projectRootURL.appendingPathComponent("ownership-marker")
        try Data("original".utf8).write(to: original)
        let ownership = HeadlessFixtureState()
        let tools = [
            tool("XcodeOpenWorkspace", properties: ["path"]),
            tool("XcodeCloseWorkspace", properties: ["workspaceIdentifier"]),
            tool("XcodeListTestPlans", properties: ["workspaceIdentifier"]),
            tool("XcodeSwitchTestPlan", properties: ["workspaceIdentifier", "testPlanName"]),
            tool("XcodeListTemplates", properties: ["templateIdentifier"]),
            tool("AddEntitlement", properties: ["workspaceIdentifier", "targetName", "entitlementKey", "entitlementValueType", "entitlementValue"]),
            tool("AddInfoPlist", properties: ["workspaceIdentifier", "targetName", "infoPlistKey", "infoPlistValueType", "infoPlistValue"]),
            tool("UpdateTargetBuildSetting", properties: ["workspaceIdentifier", "targetName", "buildSettingName", "buildSettingValue", "appendValue"]),
            tool("BuildProject", properties: ["workspaceIdentifier", "buildForTesting"]),
            tool("XcodeNewProject", properties: ["templateIdentifier", "productName", "destinationPath", "organizationIdentifier", "options"]),
            tool("XcodeNewTarget", properties: ["workspaceIdentifier", "templateIdentifier", "productName", "organizationIdentifier", "options"]),
        ]
        let runtime = XcodeMCPTestRuntime(tools: tools)
        await runtime.setToolHandler { call in
            switch call.name {
            case "XcodeOpenWorkspace":
                await ownership.open(try #require(call.arguments["path"]?.stringValue))
                return result(["workspaceIdentifier": "owned-native-id"])
            case "XcodeListTestPlans":
                return result(["activeTestPlanName": "Native Reported Plan"])
            case "XcodeSwitchTestPlan":
                #expect(call.arguments["testPlanName"] == "Native Reported Plan")
            case "XcodeListTemplates":
                #expect(call.arguments["templateIdentifier"] == "com.apple.dt.unit.iosFramework")
            case "AddEntitlement":
                #expect(call.arguments["workspaceIdentifier"] == "owned-native-id")
                let workspace = try #require(await ownership.path)
                let project = try referencedProject(in: URL(fileURLWithPath: workspace))
                try Data("native mutation".utf8).write(to: project.deletingLastPathComponent().appendingPathComponent("ownership-marker"))
            case "XcodeNewProject":
                let destination = URL(fileURLWithPath: try #require(call.arguments["destinationPath"]?.stringValue))
                var relationship = FileManager.URLRelationship.other
                try FileManager.default.getRelationship(&relationship, ofDirectoryAt: fixture.outputRoot, toItemAt: destination)
                #expect(relationship == .contains)
            case "XcodeCloseWorkspace":
                await ownership.close()
            default:
                #expect(call.arguments["workspaceIdentifier"] == "owned-native-id")
            }
            return result(["message": "ok"])
        }
        #expect(try await !verify(runtime: runtime, fixture: fixture))
        #expect(try String(contentsOf: original, encoding: .utf8) == "original")
        let workspace = try #require(await ownership.path)
        let copiedProject = try referencedProject(in: URL(fileURLWithPath: workspace))
        #expect(try String(contentsOf: copiedProject.deletingLastPathComponent()
            .appendingPathComponent("ownership-marker"), encoding: .utf8) == "native mutation")
        let calls = await runtime.recordedToolCalls()
        #expect(Set(calls.map(\.name)) == Set(tools.map(\.name)))
        let buildIndex = try #require(calls.firstIndex { $0.name == "BuildProject" })
        #expect(try #require(calls.firstIndex { $0.name == "XcodeNewTarget" }) > buildIndex)
    }

    @Test(arguments: [false, true])
    func requestedDestinationSurvivesNativeInventory(explicitDestination: Bool) async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.outputRoot) }
        let ownedTitle = "Verifier Owned iPhone (27.0)"
        let automaticTitle = "Existing iPhone (27.0)"
        let runtime = XcodeMCPTestRuntime(tools: [
            tool("XcodeOpenWorkspace", properties: ["path"]),
            tool("XcodeCloseWorkspace", properties: ["workspaceIdentifier"]),
            tool("XcodeListRunDestinations", properties: ["workspaceIdentifier", "includeIncompatible"]),
            tool("XcodeSwitchRunDestination", properties: ["workspaceIdentifier", "displayTitle"]),
        ])
        await runtime.setToolHandler { call in
            switch call.name {
            case "XcodeOpenWorkspace":
                return result(["workspaceIdentifier": "owned-native-id"])
            case "XcodeListRunDestinations":
                return result(["destinations": [[
                    "displayTitle": .string(automaticTitle),
                    "isSimulator": true, "isEligible": true,
                    "platformIdentifier": "com.apple.platform.iphonesimulator", "osVersion": "27.0",
                ]]])
            case "XcodeSwitchRunDestination":
                #expect(call.arguments["displayTitle"] == .string(explicitDestination ? ownedTitle : automaticTitle))
                return result(["message": "switched"])
            case "XcodeCloseWorkspace":
                return result(["message": "closed"])
            default:
                Issue.record("unexpected destination verification call: \(call.name)")
                return MCPToolResult(content: [], isError: true)
            }
        }
        let failed = try await verify(runtime: runtime, fixture: fixture,
            runDestination: explicitDestination ? ownedTitle : nil)
        #expect(!failed)
        #expect(await runtime.recordedToolCalls().contains { $0.name == "XcodeSwitchRunDestination" })
    }

    @Test(arguments: [false, true])
    func nativeHostOpensDedicatedWorkspaceAndClosesOnlyThatHandle(toolFails: Bool) async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.outputRoot) }
        let previousRun = fixture.outputRoot.appendingPathComponent("Fixture")
        try FileManager.default.createDirectory(at: previousRun, withIntermediateDirectories: false)
        let runtime = XcodeMCPTestRuntime(tools: workspaceTools)
        let ownership = HeadlessFixtureState()
        await runtime.setToolHandler { call in
            switch call.name {
            case "XcodeOpenWorkspace":
                let path = try #require(call.arguments["path"]?.stringValue)
                #expect(path != fixture.rootWorkspaceURL.path)
                #expect(path.hasPrefix(fixture.outputRoot.path + "/HeadlessFixture-"))
                let project = try referencedProject(in: URL(fileURLWithPath: path))
                #expect(project.lastPathComponent == fixture.xcodeProjectURL.lastPathComponent)
                #expect(project != fixture.xcodeProjectURL)
                var relationship = FileManager.URLRelationship.other
                try FileManager.default.getRelationship(&relationship, ofDirectoryAt: fixture.outputRoot, toItemAt: project)
                #expect(relationship == .contains)
                await ownership.open(path)
                return result(["workspaceIdentifier": "owned-native-id", "workspacePath": .string(path)])
            case "XcodeListWorkspaces":
                guard await ownership.path != nil else {
                    return MCPToolResult(content: [.text("Call XcodeOpenWorkspace for approval", raw: ["type": "text", "text": "Call XcodeOpenWorkspace for approval"])], isError: true)
                }
                return result(["message": .string("* workspaceIdentifier: existing-shared-id, workspacePath: \(fixture.rootWorkspaceURL.path)")])
            case "XcodeCloseWorkspace":
                #expect(call.arguments["workspaceIdentifier"] == "owned-native-id")
                await ownership.close()
                return result(["message": "closed"])
            case "XcodeListSchemes", "DeviceInteractionStartWorkspaceSession":
                #expect(call.arguments["workspaceIdentifier"] == "owned-native-id")
                return MCPToolResult(content: [], structuredContent: ["message": "ProxyToolVerifierFixture"], isError: toolFails)
            default:
                Issue.record("Unexpected fixture call: \(call.name)")
                return MCPToolResult(content: [], isError: true)
            }
        }
        let failed = try await verify(runtime: runtime, fixture: fixture)
        #expect(failed == toolFails)
        #expect(await ownership.closeCount == 1)
        let calls = await runtime.recordedToolCalls()
        let openIndex = try #require(calls.firstIndex { $0.name == "XcodeOpenWorkspace" })
        let listIndex = try #require(calls.firstIndex { $0.name == "XcodeListWorkspaces" })
        #expect(openIndex < listIndex)
    }

    private func makeFixture() throws -> FixtureLayout {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("verifier-test-\(UUID())")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let fixture = FixtureLayout(repoRoot: output.appendingPathComponent("Fixture & Project"), outputRoot: output)
        try FileManager.default.createDirectory(at: fixture.xcodeProjectURL, withIntermediateDirectories: true)
        return fixture
    }

    private func verify(runtime: XcodeMCPTestRuntime, fixture: FixtureLayout,
        runDestination: String? = nil, deviceIdentifier: String? = nil) async throws -> Bool {
        let client = try await runtime.makeClient()
        do {
            let options = try VerifierOptions(arguments: ["--request-timeout", "2"]
                + (runDestination.map { ["--run-destination", $0] } ?? [])
                + (deviceIdentifier.map { ["--device-identifier", $0] } ?? []))
            let failed = try await ProxyToolVerifier(options: options).verify(client: client, fixture: fixture, outputRoot: fixture.outputRoot)
            await client.close()
            return failed
        } catch {
            await client.close()
            throw error
        }
    }
}

private actor HeadlessFixtureState {
    var path: String?
    var closeCount = 0
    func open(_ path: String) { self.path = path }
    func close() { closeCount += 1 }
}

private actor RecentDeviceSessionIdentifiers {
    private var identifiers: Set<String> = []
    func insert(_ identifier: String) -> Bool { identifiers.insert(identifier).inserted }
}

private func referencedProject(in workspace: URL) throws -> URL {
    let document = try XMLDocument(contentsOf: workspace.appendingPathComponent("contents.xcworkspacedata"))
    let reference = try #require(try document.nodes(forXPath: "/Workspace/FileRef/@location").first?.stringValue)
    return URL(fileURLWithPath: String(reference.dropFirst("absolute:".count)))
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

private let nativeTools = [
    tool("XcodeOpenWorkspace", properties: ["path"]),
    tool("XcodeListWorkspaces", properties: []),
    tool("XcodeCloseWorkspace", properties: ["workspaceIdentifier"]),
    tool("DeviceInteractionStartWorkspaceSession", properties: ["workspaceIdentifier", "sessionIdentifier"]),
]

private let workspaceTools = nativeTools + [
    tool("XcodeListSchemes", properties: ["workspaceIdentifier"]),
]
