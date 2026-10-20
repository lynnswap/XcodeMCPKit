import Foundation
import NIO
import NIOConcurrencyHelpers
import Testing
@testable import XcodeMCPCore
@testable import XcodeMCPProxyRuntime
import XcodeMCPProxyRuntimeContract
import XcodeMCPProxyTestSupport

@Suite(.serialized, .timeLimit(.minutes(1)), .asyncTestCleanup)
struct NativeHostBrokerTests {
    @Test func guiHandlesKeepIdenticalPathsAndTabsOnTheirNativeHosts() async throws {
        let installation = XcodeHostInstallation(developerDirectory: URL(filePath: "/Fixture/Default.app"))
        let fixture = try BrokerFixture(guiProcesses: [
            .init(processID: 101, launchDate: Date(timeIntervalSince1970: 1), installation: installation),
            .init(processID: 102, launchDate: Date(timeIntervalSince1970: 2), installation: installation),
        ])
        let a = try await fixture.initialize("gui-a")
        let b = try await fixture.initialize("gui-b")
        let before = try await fixture.request(a, method: "tools/list")
        let workspaces = try await fixture.workspaces(a).filter { $0["kind"] == .string("gui") }
        #expect(workspaces.count == 4)
        let first = try #require(workspaces.first?["workspaceIdentifier"])
        let last = try #require(workspaces.last?["workspaceIdentifier"])
        let left = try await fixture.call(a, name: "GetBuildLog", arguments: ["workspaceIdentifier": first])
        let right = try await fixture.call(a, name: "GetBuildLog", arguments: ["workspaceIdentifier": last])
        #expect(left != right)
        let gui = try #require(fixture.factory.transports.withLockedValue { $0.first { $0.gui } })
        let logged = try #require(gui.calls.withLockedValue { $0.last { $0.name == "GetBuildLog" } })
        #expect(logged.arguments["tabIdentifier"] == .string("tab-1"))
        #expect(logged.arguments["workspaceIdentifier"] == nil)
        #expect(try await fixture.request(a, method: "tools/list") == before)
        #expect(try await fixture.request(b, method: "tools/list") == before)
        let rejected = try await fixture.toolResult(b, name: "GetBuildLog", arguments: ["workspaceIdentifier": first])
        #expect(NativeHostBroker.isToolError(rejected))
    }

    @Test func ambiguousGUIOpenDoesNotRetainWorkspaceReferences() async throws {
        let installation = XcodeHostInstallation(developerDirectory: URL(filePath: "/Fixture/Default.app"))
        let fixture = try BrokerFixture(guiProcesses: [
            .init(processID: 101, launchDate: Date(timeIntervalSince1970: 1), installation: installation),
        ])
        let session = try await fixture.initialize("gui-open")
        let host = try #require(try await fixture.list(session).first { $0["kind"] == .string("gui") }?["hostIdentifier"])
        let ambiguous = try await fixture.toolResult(session, name: NativeHostBroker.openWorkspaceTool,
            arguments: ["path": .string("/Fixture/App.xcodeproj"), "hostIdentifier": host])
        #expect(NativeHostBroker.isToolError(ambiguous))
        let gui = try #require(fixture.factory.transports.withLockedValue { $0.first { $0.gui } })
        try await gui.stopped.wait(description: "ambiguous GUI open released its bridge")
    }

    @Test func openingOneGUIWorkspaceDoesNotRetainOtherProjectTabs() async throws {
        let installation = XcodeHostInstallation(developerDirectory: URL(filePath: "/Fixture/Default.app"))
        let fixture = try BrokerFixture(guiProcesses: [
            .init(processID: 101, launchDate: Date(timeIntervalSince1970: 1), installation: installation),
        ])
        fixture.factory.guiWorkspacePaths.withLockedValue { $0 = ["/Fixture/App.xcodeproj", "/Fixture/Other.xcodeproj"] }
        let session = try await fixture.initialize("gui-open-one")
        let host = try #require(try await fixture.list(session).first { $0["kind"] == .string("gui") }?["hostIdentifier"])
        let identifier = try await fixture.open(session, host: host)
        _ = try await fixture.call(session, name: "GetBuildLog", arguments: ["workspaceIdentifier": identifier])
        let gui = try #require(fixture.factory.transports.withLockedValue { $0.first { $0.gui } })
        #expect(gui.calls.withLockedValue { $0.last { $0.name == "GetBuildLog" }?.arguments["tabIdentifier"] } == .string("tab-1"))
        let closed = try await fixture.call(session, name: NativeHostBroker.closeWorkspaceTool,
                                             arguments: ["workspaceIdentifier": identifier])
        #expect(closed["released"] == .bool(true))
        try await gui.stopped.wait(description: "the opened GUI workspace released its only reference")
        #expect(gui.calls.withLockedValue { !$0.contains { $0.name == NativeHostBroker.closeWorkspaceTool } })
        #expect(NativeHostBroker.isToolError(try await fixture.toolResult(session, name: "GetBuildLog",
            arguments: ["workspaceIdentifier": identifier])))
    }

    @Test func exitedGUIProcessDoesNotReuseAWorkspaceHandleWhenPIDIsReused() async throws {
        let installation = XcodeHostInstallation(developerDirectory: URL(filePath: "/Fixture/Default.app"))
        let original = XcodeGUIProcess(processID: 101, launchDate: Date(timeIntervalSince1970: 1), installation: installation)
        let fixture = try BrokerFixture(guiProcesses: [original])
        let session = try await fixture.initialize("gui-exit")
        let identifier = try #require(try await fixture.workspaces(session).first { $0["kind"] == .string("gui") }?["workspaceIdentifier"])
        fixture.guiProcesses.withLockedValue {
            $0 = [.init(processID: 101, launchDate: Date(timeIntervalSince1970: 2), installation: installation)]
        }
        let result = try await fixture.toolResult(session, name: "GetBuildLog", arguments: ["workspaceIdentifier": identifier])
        #expect(NativeHostBroker.isToolError(result))
        #expect(fixture.factory.transports.withLockedValue { $0.count } == 2)
    }

    @Test(arguments: ["XcodeOpenWorkspace", "XcodeNewProject"])
    func nonStringHostDoesNotDispatchAnOperationOnTheDefaultHost(operation: String) async throws {
        let fixture = try BrokerFixture()
        let session = try await fixture.initialize("invalid-host")
        var arguments: [String: JSONValue] = ["hostIdentifier": .bool(true)]
        if operation == NativeHostBroker.openWorkspaceTool {
            arguments["path"] = .string("/Fixture/App.xcodeproj")
        } else {
            arguments["templateIdentifier"] = .string("fixture-template")
            arguments["productName"] = .string("FixtureProject")
            arguments["destinationPath"] = .string("/Fixture/NewProject")
        }
        let result = try await fixture.toolResult(session, name: operation, arguments: arguments)
        #expect(NativeHostBroker.isToolError(result))
        let calls = fixture.factory.transports.withLockedValue { $0 }.flatMap { transport in
            transport.calls.withLockedValue { $0 }
        }
        #expect(!calls.contains { $0.name == operation })
    }

    @Test func nonStringWorkspaceIsNotReplacedByTheDeviceSessionsParent() async throws {
        let fixture = try BrokerFixture()
        let session = try await fixture.initialize("invalid-workspace")
        let workspace = try await fixture.open(session)
        let started = try await fixture.call(session, name: "DeviceInteractionStartSession", arguments: [
            "workspaceIdentifier": workspace, "sessionIdentifier": .string("fixture"),
        ])
        let key = try #require(started["interactionSessionKey"])
        let result = try await fixture.toolResult(session, name: "DeviceInteractionInstallAndRun", arguments: [
            "workspaceIdentifier": .bool(true), "interactionSessionKey": key,
        ])
        #expect(NativeHostBroker.isToolError(result))
        let native = try #require(fixture.factory.transports.withLockedValue { $0.first })
        #expect(native.calls.withLockedValue { !$0.contains { $0.name == "DeviceInteractionInstallAndRun" } })
    }

    @Test func absolutePathsUseTheDefaultHeadlessHostAndReuseItsWorkspaceHandle() async throws {
        let fixture = try BrokerFixture()
        let session = try await fixture.initialize("paths")
        let path = JSONValue.string("/Fixture/App.xcodeproj")
        let result = try await fixture.call(session, name: "GetBuildLog", arguments: ["workspaceIdentifier": path])
        #expect(result["host"] == .number(.int(1)))
        let entries = try await fixture.workspaces(session)
        let identifier = try #require(entries.first?["workspaceIdentifier"])
        #expect(identifier != .string("native-w-1"))
        let transport = try #require(fixture.factory.transports.withLockedValue { $0.first })
        #expect(transport.calls.withLockedValue { $0.last { $0.name == "GetBuildLog" }?.arguments["workspaceIdentifier"] } == .string("native-w-1"))
        #expect(try await fixture.open(session) == identifier)
    }

    @Test func independentWorkspacesRetainTheirHostsAndCloseAfterFinalRelease() async throws {
        let fixture = try BrokerFixture()
        let a = try await fixture.initialize("independent-a")
        let b = try await fixture.initialize("independent-b")
        let knownHosts = try await fixture.list(a).compactMap { $0["hostIdentifier"] }
        let left = try await fixture.open(a, independent: true)
        let transport = try #require(fixture.factory.transports.withLockedValue { $0.first })
        let host = try #require(try await fixture.list(a).first {
            !knownHosts.contains($0["hostIdentifier"] ?? .null)
        }?["hostIdentifier"])
        let right = try await fixture.open(b, host: host)
        fixture.broker.removeSession(a)
        #expect(!transport.stopped.isSignaled())
        #expect(try await fixture.call(b, name: "GetBuildLog", arguments: ["workspaceIdentifier": right])["host"] == .number(.int(1)))
        _ = try await fixture.call(b, name: NativeHostBroker.closeWorkspaceTool, arguments: ["workspaceIdentifier": right])
        try await transport.stopped.wait(description: "last workspace reference released")
        #expect(try await fixture.list(b).allSatisfy { $0["hostIdentifier"] != host })
        #expect(left != right)
    }

    @Test func admittedWorkRetainsItsScopeWhenTheWorkspaceReferenceIsClosed() async throws {
        let fixture = try BrokerFixture()
        let session = try await fixture.initialize("inflight")
        let workspace = try await fixture.open(session, independent: true)
        let transport = try #require(fixture.factory.transports.withLockedValue { $0.first })
        let pending = Task { try await fixture.toolResult(session, name: "BuildProject",
            arguments: ["workspaceIdentifier": workspace], id: 71) }
        try await transport.waiting.wait(description: "build admitted")
        _ = try await fixture.call(session, name: NativeHostBroker.closeWorkspaceTool,
                                  arguments: ["workspaceIdentifier": workspace])
        #expect(!transport.stopped.isSignaled())
        await transport.releaseWait()
        #expect(!NativeHostBroker.isToolError(try await pending.value))
        try await transport.stopped.wait(description: "admitted work released its host")
    }

    @Test func numericCancellationAndServerCallbacksStayOnTheOriginalHost() async throws {
        let fixture = try BrokerFixture()
        let session = try await fixture.initialize("callbacks")
        let workspace = try await fixture.open(session, independent: true)
        let original = try #require(fixture.factory.transports.withLockedValue { $0.first })
        let pending = Task { try await fixture.reply(session, method: "tools/call", parameters: .object([
            "name": .string("BuildProject"), "arguments": .object(["workspaceIdentifier": workspace]),
        ]), id: 73) }
        try await original.waiting.wait(description: "cancellable build admitted")
        _ = try await fixture.open(session)
        try original.emitServerRequest()
        try await fixture.serverRequestDelivered.wait(description: "server request delivered")
        let routed = try #require(fixture.events.withLockedValue { events in
            events.compactMap { event -> JSONRPC.ID? in
                guard case .notification(_, let data) = event,
                      let object = try? JSONRPC.Wire.object(fromData: data),
                      case .request("sampling/createMessage", let id) = JSONRPC.Message.Inspector.kind(of: object) else { return nil }
                return id
            }.first
        })
        let response = try ProxyRuntimeRequest(json: .object([
            "jsonrpc": .string("2.0"), "id": routed.value, "result": .object([:]),
        ]), headerSessionExists: true, prefersEventStream: false)
        let operation = try #require(fixture.broker.beginRequest(response, in: session))
        _ = try await withCheckedThrowingContinuation { continuation in
            operation.whenComplete { continuation.resume(with: $0) }
        }
        fixture.broker.clientRequestFinished(session)
        try await original.serverResponseReceived.wait(description: "server response returned to original host")
        #expect(original.serverResponseIDs.withLockedValue { $0 } == [.string("native-server-request")])
        _ = try await fixture.reply(session, method: "notifications/cancelled",
                                   parameters: .object(["requestId": .number(.int(73))]), id: nil)
        guard case .mcpError(_, -32800, _, _, _) = try await pending.value else {
            Issue.record("build was not cancelled"); return
        }
        try await original.cancelled.wait(description: "cancellation reached original host")
        let other = try #require(fixture.factory.transports.withLockedValue { $0.last })
        #expect(!other.cancelled.isSignaled())
        #expect(other.serverResponseIDs.withLockedValue { $0.isEmpty })
        await original.releaseWait()
    }

    @Test func deviceAndLaunchReferencesCarryTheirHostAndParentWorkspace() async throws {
        let fixture = try BrokerFixture()
        let session = try await fixture.initialize("sessions")
        let workspace = try await fixture.open(session, independent: true)
        let started = try await fixture.call(session, name: "DeviceInteractionStartSession", arguments: [
            "workspaceIdentifier": workspace, "sessionIdentifier": .string("fixture"),
        ])
        let key = try #require(started["interactionSessionKey"])
        _ = try await fixture.call(session, name: "DeviceInteractionSynthesize", arguments: ["interactionSessionKey": key])
        _ = try await fixture.call(session, name: "DeviceInteractionInstallAndRun", arguments: ["interactionSessionKey": key])
        let transport = try #require(fixture.factory.transports.withLockedValue { $0.first })
        #expect(transport.calls.withLockedValue { $0.contains { $0.name == "DeviceInteractionStartWorkspaceSession" } })
        let synthesized = try #require(transport.calls.withLockedValue { $0.last { $0.name == "DeviceInteractionSynthesize" } })
        #expect(synthesized.arguments["interactSessionKey"] == .string("native-device-1"))
        #expect(synthesized.arguments["interactionSessionKey"] == nil)
        let install = try #require(transport.calls.withLockedValue { $0.last { $0.name == "DeviceInteractionInstallAndRun" } })
        #expect(install.arguments["workspaceIdentifier"] == .string("native-w-1"))
        #expect(NativeHostBroker.isToolError(try await fixture.toolResult(session, name: "DeviceInteractionInstallAndRun",
            arguments: ["interactionSessionKey": key, "workspaceIdentifier": .string("/Fixture/Other.xcodeproj")])))
        #expect(fixture.factory.transports.withLockedValue { transports in
            transports.allSatisfy { transport in
                transport.calls.withLockedValue { calls in
                    !calls.contains { $0.name == "XcodeOpenWorkspace" && $0.arguments["path"] == .string("/Fixture/Other.xcodeproj") }
                }
            }
        })
        let run = try await fixture.call(session, name: "RunProject", arguments: ["workspaceIdentifier": workspace])
        let launch = try #require(run["launchSessionReference"])
        #expect(launch != .string("native-launch-1"))
        _ = try await fixture.call(session, name: "GetConsoleOutput", arguments: ["launchSessionReference": launch])
        let console = try #require(transport.calls.withLockedValue { $0.last { $0.name == "GetConsoleOutput" } })
        #expect(console.arguments["launchSessionReference"] == .string("native-launch-1"))
        #expect(console.arguments["workspaceIdentifier"] == .string("native-w-1"))
        _ = try await fixture.call(session, name: "DeviceInteractionEndSession", arguments: ["interactionSessionKey": key])
        #expect(NativeHostBroker.isToolError(try await fixture.toolResult(session, name: "DeviceInteractionSynthesize",
            arguments: ["interactionSessionKey": key])))
    }

    @Test func guiSessionReferencesRetainTheirOriginalTabAfterTheWorkspaceReferenceCloses() async throws {
        let installation = XcodeHostInstallation(developerDirectory: URL(filePath: "/Fixture/Default.app"))
        let fixture = try BrokerFixture(guiProcesses: [
            .init(processID: 101, launchDate: Date(timeIntervalSince1970: 1), installation: installation),
        ])
        let session = try await fixture.initialize("gui-dependent-sessions")
        let entries = try await fixture.workspaces(session).filter { $0["kind"] == .string("gui") }
        let workspace = try #require(entries.first?["workspaceIdentifier"])
        let otherTab = try #require(entries.last?["workspaceIdentifier"])
        let started = try await fixture.call(session, name: "DeviceInteractionStartSession", arguments: [
            "workspaceIdentifier": workspace, "sessionIdentifier": .string("fixture"),
        ])
        let key = try #require(started["interactionSessionKey"])
        let run = try await fixture.call(session, name: "RunProject", arguments: ["workspaceIdentifier": workspace])
        let launch = try #require(run["launchSessionReference"])
        _ = try await fixture.call(session, name: NativeHostBroker.closeWorkspaceTool,
                                  arguments: ["workspaceIdentifier": workspace])
        #expect(NativeHostBroker.isToolError(try await fixture.toolResult(session, name: "GetBuildLog",
            arguments: ["workspaceIdentifier": workspace])))
        #expect(NativeHostBroker.isToolError(try await fixture.toolResult(session, name: "DeviceInteractionInstallAndRun",
            arguments: ["interactionSessionKey": key, "workspaceIdentifier": otherTab])))
        let console = try await fixture.toolResult(session, name: "GetConsoleOutput",
                                                   arguments: ["launchSessionReference": launch])
        let installed = try await fixture.toolResult(session, name: "DeviceInteractionInstallAndRun",
                                                     arguments: ["interactionSessionKey": key])
        #expect(!NativeHostBroker.isToolError(console))
        #expect(!NativeHostBroker.isToolError(installed))
        let gui = try #require(fixture.factory.transports.withLockedValue { $0.first { $0.gui } })
        let consoleCall = try #require(gui.calls.withLockedValue { $0.last { $0.name == "GetConsoleOutput" } })
        let installCall = try #require(gui.calls.withLockedValue { $0.last { $0.name == "DeviceInteractionInstallAndRun" } })
        #expect(consoleCall.arguments["tabIdentifier"] == .string("tab-1"))
        #expect(installCall.arguments["tabIdentifier"] == .string("tab-1"))
    }

    @Test func nativeCatalogChangesUpdateTheAdapterWithoutChangingThePublicCatalog() async throws {
        let fixture = try BrokerFixture()
        let session = try await fixture.initialize("catalog-change")
        let workspace = try await fixture.open(session)
        let before = try await fixture.request(session, method: "tools/list")
        let started = try await fixture.call(session, name: "DeviceInteractionStartSession", arguments: [
            "workspaceIdentifier": workspace, "sessionIdentifier": .string("fixture"),
        ])
        let key = try #require(started["interactionSessionKey"])
        _ = try await fixture.call(session, name: "DeviceInteractionSynthesize", arguments: ["interactionSessionKey": key])
        let native = try #require(fixture.factory.transports.withLockedValue { $0.first })
        #expect(native.calls.withLockedValue { $0.last { $0.name == "DeviceInteractionSynthesize" }?.arguments["interactSessionKey"] } != nil)
        let changeIndex = fixture.factory.catalogChanges.count()
        native.interactionKeyProperty.withLockedValue { $0 = "interactionSessionKey" }
        try native.emitCatalogChanged()
        try await waitWithTimeout("native catalog invalidation reached the runtime", timeout: .seconds(2)) {
            try await fixture.factory.catalogChanges.nextValue(at: changeIndex)
        }
        _ = try await fixture.call(session, name: "DeviceInteractionSynthesize", arguments: ["interactionSessionKey": key])
        let call = try #require(native.calls.withLockedValue { $0.last { $0.name == "DeviceInteractionSynthesize" } })
        #expect(call.arguments["interactionSessionKey"] != nil)
        #expect(call.arguments["interactSessionKey"] == nil)
        #expect(try await fixture.request(session, method: "tools/list") == before)
    }

    @Test func recoveredNativeProcessesDoNotReuseWorkspaceOrDependentReferences() async throws {
        let fixture = try BrokerFixture()
        let session = try await fixture.initialize("native-recovery")
        let workspace = try await fixture.open(session)
        let started = try await fixture.call(session, name: "DeviceInteractionStartSession", arguments: [
            "workspaceIdentifier": workspace, "sessionIdentifier": .string("fixture"),
        ])
        let device = try #require(started["interactionSessionKey"])
        let launched = try await fixture.call(session, name: "RunProject", arguments: ["workspaceIdentifier": workspace])
        let launch = try #require(launched["launchSessionReference"])
        let original = try #require(fixture.factory.transports.withLockedValue { $0.first })
        original.emitExit()
        let replacement = try await waitWithTimeout("native process replaced after exit", timeout: .seconds(5)) {
            try await fixture.factory.replacements.nextValue(at: 0)
        }
        try await replacement.initializationStarted.wait(description: "replacement initialized")
        _ = try await fixture.call(session, name: "DocumentationSearch", arguments: ["query": .string("SwiftUI")])
        for (name, arguments) in [
            ("GetBuildLog", ["workspaceIdentifier": workspace]),
            ("DeviceInteractionInstallAndRun", ["interactionSessionKey": device]),
            ("GetConsoleOutput", ["launchSessionReference": launch]),
        ] {
            #expect(NativeHostBroker.isToolError(try await fixture.toolResult(session, name: name, arguments: arguments)))
        }
        #expect(replacement.calls.withLockedValue { calls in
            !calls.contains { ["GetBuildLog", "DeviceInteractionInstallAndRun", "GetConsoleOutput"].contains($0.name) }
        })
        let newPath = JSONValue.string("/Fixture/Recovered.xcodeproj")
        let reopened = try await fixture.call(session, name: NativeHostBroker.openWorkspaceTool, arguments: ["path": newPath])
        let newWorkspace = try #require(reopened["workspaceIdentifier"])
        #expect(newWorkspace != workspace)
        let entries = try await fixture.workspaces(session)
        let entry = try #require(entries.first { $0["workspaceIdentifier"] == newWorkspace })
        #expect(entry["path"] == newPath)
        #expect(entry["name"] == .string("Recovered"))
        _ = try await fixture.call(session, name: "GetBuildLog", arguments: ["workspaceIdentifier": newWorkspace])
        #expect(replacement.calls.withLockedValue { $0.last { $0.name == "GetBuildLog" }?.arguments["workspaceIdentifier"] }
            == .string("native-w-\(original.index)"))
    }

    @Test func expiredGenerationReferencesDoNotRetainAnIndependentHost() async throws {
        let fixture = try BrokerFixture()
        let session = try await fixture.initialize("recovery-lifetime")
        let initialHosts = try await fixture.list(session).compactMap { NativeHostBroker.string($0["hostIdentifier"]) }
        let workspace = try await fixture.open(session, independent: true)
        let host = try #require(try await fixture.list(session).first {
            NativeHostBroker.string($0["hostIdentifier"]).map { !initialHosts.contains($0) } == true
        }?["hostIdentifier"])
        let started = try await fixture.call(session, name: "DeviceInteractionStartSession", arguments: [
            "workspaceIdentifier": workspace, "sessionIdentifier": .string("fixture"),
        ])
        _ = try #require(started["interactionSessionKey"])
        let launched = try await fixture.call(session, name: "RunProject", arguments: ["workspaceIdentifier": workspace])
        _ = try #require(launched["launchSessionReference"])
        let original = try #require(fixture.factory.transports.withLockedValue { $0.first })
        original.emitExit()
        let stoppedHost = try await waitWithTimeout("expired references released the independent runtime", timeout: .seconds(5)) {
            try await fixture.factory.shutdowns.nextValue(at: 0)
        }
        #expect(stoppedHost == original.index)
        #expect(fixture.factory.transports.withLockedValue { $0.allSatisfy { $0.stopped.isSignaled() } })
        #expect(try await fixture.list(session).allSatisfy { $0["hostIdentifier"] != host })
    }

    @Test func explicitNonObjectArgumentsAreRejectedBeforeNativeDispatchWhileOmittedArgumentsWork() async throws {
        let fixture = try BrokerFixture()
        let session = try await fixture.initialize("argument-shape")
        let invalid = try await fixture.reply(session, method: "tools/call", parameters: .object([
            "name": .string("XcodeListTemplates"), "arguments": .array([]),
        ]))
        guard case .mcpError(_, -32602, _, _, _) = invalid else {
            Issue.record("Non-object tool arguments were not rejected as invalid parameters"); return
        }
        #expect(fixture.factory.transports.withLockedValue { $0.isEmpty })
        let omitted = try await fixture.request(session, method: "tools/call", parameters: .object([
            "name": .string("XcodeListTemplates"),
        ]))
        #expect(!NativeHostBroker.isToolError(omitted))
        let native = try #require(fixture.factory.transports.withLockedValue { $0.first })
        #expect(native.calls.withLockedValue { $0.last { $0.name == "XcodeListTemplates" }?.arguments } == [:])
    }

    @Test func handlelessQueriesReuseTheDefaultChannelAndNativeCatalog() async throws {
        let fixture = try BrokerFixture()
        let session = try await fixture.initialize("global-queries")
        _ = try await fixture.call(session, name: "DocumentationSearch", arguments: ["query": .string("SwiftUI")])
        let native = try #require(fixture.factory.transports.withLockedValue { $0.first })
        let startupRequests = native.methods.withLockedValue { $0.filter { $0 == "initialize" || $0 == "tools/list" } }
        _ = try await fixture.call(session, name: "DocumentationSearch", arguments: ["query": .string("Foundation")])
        #expect(fixture.factory.transports.withLockedValue { $0.count } == 1)
        #expect(native.methods.withLockedValue { $0.filter { $0 == "initialize" || $0 == "tools/list" } } == startupRequests)
    }

    @Test func packageManifestPathsReuseTheDeviceSessionsParentWorkspace() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BrokerPackage-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { Issue.record(error) }
        }
        let manifest = directory.appendingPathComponent("Package.swift")
        try "// swift-tools-version: 6.3\nimport PackageDescription\nlet package = Package(name: \"Fixture\")\n"
            .write(to: manifest, atomically: true, encoding: .utf8)
        let fixture = try BrokerFixture()
        fixture.factory.manifestOpensDirectory.withLockedValue { $0 = true }
        let session = try await fixture.initialize("manifest-parent")
        let opened = try await fixture.call(session, name: NativeHostBroker.openWorkspaceTool,
                                            arguments: ["path": .string(manifest.path)])
        let workspace = try #require(opened["workspaceIdentifier"])
        let started = try await fixture.call(session, name: "DeviceInteractionStartSession", arguments: [
            "workspaceIdentifier": workspace, "sessionIdentifier": .string("fixture"),
        ])
        let key = try #require(started["interactionSessionKey"])
        let installed = try await fixture.toolResult(session, name: "DeviceInteractionInstallAndRun", arguments: [
            "interactionSessionKey": key, "workspaceIdentifier": .string(manifest.path),
        ])
        #expect(!NativeHostBroker.isToolError(installed))
        let native = try #require(fixture.factory.transports.withLockedValue { $0.first })
        #expect(native.calls.withLockedValue { $0.filter { $0.name == "XcodeOpenWorkspace" }.count } == 1)
    }

    @Test func failedOpenReleasesItsIndependentHostWithoutPublishingAWorkspace() async throws {
        let fixture = try BrokerFixture()
        let session = try await fixture.initialize("failed-open")
        fixture.factory.failNewHosts.withLockedValue { $0 = true }
        let result = try await fixture.toolResult(session, name: NativeHostBroker.openWorkspaceTool,
            arguments: ["path": .string("/Fixture/App.xcodeproj"), "createsNewHost": .bool(true)])
        #expect(NativeHostBroker.isToolError(result))
        #expect(try NativeHostBroker.toolPayload(result)["workspaceIdentifier"] == nil)
        #expect(try await fixture.list(session).count == 2)
    }

    @Test(arguments: ["GetBuildLog", "tools/list"])
    func runtimeTransportFailuresKeepTheirClassificationAndExternalSession(operation: String) async throws {
        let fixture = try BrokerFixture()
        let session = try await fixture.initialize("runtime-failure")
        let workspace = try await fixture.open(session)
        fixture.factory.replyOverrides.withLockedValue {
            $0[operation] = .failure(kind: .invalidUpstreamResponse, message: "invalid upstream response",
                                    sessionID: ProxySessionID(rawValue: "internal-runtime-session"))
        }
        let reply: ProxyRuntimeReply
        if operation == "tools/list" {
            reply = try await fixture.reply(session, method: "tools/list")
        } else {
            reply = try await fixture.reply(session, method: "tools/call", parameters: .object([
                "name": .string(operation), "arguments": .object(["workspaceIdentifier": workspace]),
            ]))
        }
        guard case .failure(.invalidUpstreamResponse, let message, let replySession) = reply else {
            Issue.record("runtime transport failure became a tool result"); return
        }
        #expect(message == "invalid upstream response")
        #expect(replySession == session)
    }

    @Test func nativeProtocolErrorsKeepTheirPayloadAndClientCorrelation() async throws {
        let fixture = try BrokerFixture()
        let session = try await fixture.initialize("native-protocol-error")
        let workspace = try await fixture.open(session)
        let transport = try #require(fixture.factory.transports.withLockedValue { $0.first })
        transport.returnsProtocolError.withLockedValue { $0 = true }
        let reply = try await fixture.reply(session, method: "tools/call", parameters: .object([
            "name": .string("GetBuildLog"), "arguments": .object(["workspaceIdentifier": workspace]),
        ]), id: 91)
        guard case .response(let data, let replySession, _) = reply else {
            Issue.record("native JSON-RPC error lost its original response"); return
        }
        let object = try JSONRPC.Wire.object(fromData: data)
        #expect(JSONRPC.Message.Inspector.responseID(from: object)?.value == .number(.int(91)))
        #expect(replySession == session)
        #expect(object["error"].flatMap(JSONValue.init(any:)) == .object([
            "code": .number(.int(-32010)), "message": .string("native protocol failure"),
            "data": .object(["reason": .string("fixture")]),
        ]))
    }

    @Test func nativeFailuresAndUserPayloadArePreserved() async throws {
        let fixture = try BrokerFixture()
        let session = try await fixture.initialize("native-failure")
        let workspace = try await fixture.open(session)
        let transport = try #require(fixture.factory.transports.withLockedValue { $0.first })
        _ = transport.toolFailures.withLockedValue { $0.insert("GetBuildLog") }
        let failure = try await fixture.toolResult(session, name: "GetBuildLog", arguments: ["workspaceIdentifier": workspace])
        #expect(NativeHostBroker.isToolError(failure))
        #expect(try NativeHostBroker.toolPayload(failure)["message"] == .string("native failure"))
        _ = transport.toolFailures.withLockedValue { $0.remove("GetBuildLog") }
        let result = try await fixture.call(session, name: "GetBuildLog", arguments: ["workspaceIdentifier": workspace])
        #expect(result["data"] == .object(["workspaceIdentifier": .string("native-w-1"),
                                           "tabIdentifier": .string("user-data")]))
    }

    @Test(arguments: [false, true])
    func listWorkspacesReportsPartialNativeFailures(transportFailure: Bool) async throws {
        let installation = XcodeHostInstallation(developerDirectory: URL(filePath: "/Fixture/Default.app"))
        let fixture = try BrokerFixture(guiProcesses: [
            .init(processID: 101, launchDate: Date(timeIntervalSince1970: 1), installation: installation),
        ])
        let session = try await fixture.initialize("partial-list")
        _ = try await fixture.workspaces(session)
        let gui = try #require(fixture.factory.transports.withLockedValue { $0.first { $0.gui } })
        if transportFailure {
            fixture.factory.replyOverrides.withLockedValue {
                $0["XcodeListWindows"] = .failure(kind: .invalidUpstreamResponse,
                    message: "invalid upstream response", sessionID: nil)
            }
        } else {
            _ = gui.toolFailures.withLockedValue { $0.insert("XcodeListWindows") }
        }
        _ = try await fixture.open(session)
        let result = try await fixture.toolResult(session, name: NativeHostBroker.listWorkspacesTool)
        #expect(NativeHostBroker.isToolError(result))
        let payload = try NativeHostBroker.toolPayload(result)
        guard case .array(let workspaces)? = payload["workspaces"], case .array(let errors)? = payload["errors"] else {
            Issue.record("missing partial workspace list"); return
        }
        #expect(workspaces.count == 1)
        #expect(errors.count == 1)
        if transportFailure, case .object(let error)? = errors.first {
            #expect(error["failureKind"] == .string("invalidUpstreamResponse"))
        }
    }

    @Test(arguments: [false, true])
    func independentHostStopsAfterItsSessionClosesOrExpires(expires: Bool) async throws {
        let fixture = try BrokerFixture()
        let session = try await fixture.initialize("expiry")
        _ = try await fixture.open(session, independent: true)
        let transport = try #require(fixture.factory.transports.withLockedValue { $0.first })
        if expires { fixture.broker.expireInactiveSessions(inactiveFor: .nanoseconds(1)) }
        else { fixture.broker.removeSession(session) }
        try await transport.stopped.wait(description: "session released independent host")
    }

    @Test func eventStreamsKeepIdleSessionsAliveUntilTheyClose() async throws {
        let fixture = try BrokerFixture()
        let session = try await fixture.initialize("events")
        #expect(fixture.broker.clientEventStreamOpened(session))
        fixture.broker.expireInactiveSessions(inactiveFor: .nanoseconds(1))
        #expect(fixture.broker.sessionState(session) == .initialized(protocolVersion: MCPProtocolVersion.current))
        fixture.broker.clientEventStreamClosed(session)
        fixture.broker.expireInactiveSessions(inactiveFor: .nanoseconds(1))
        #expect(fixture.broker.sessionState(session) == .missing)
    }

    @Test func resetWaitsForTheIndependentHostToStop() async throws {
        let fixture = try BrokerFixture()
        let session = try await fixture.initialize("reset")
        _ = try await fixture.open(session, independent: true)
        let transport = try #require(fixture.factory.transports.withLockedValue { $0.first })
        transport.holdsStop.withLockedValue { $0 = true }
        defer { transport.releaseStop.signal() }
        let completed = TestSignal()
        let resetting = Task { await fixture.broker.reset(); completed.signal() }
        try await transport.stopped.wait(description: "independent host stop began")
        #expect(!completed.isSignaled())
        transport.releaseStop.signal()
        await resetting.value
        #expect(fixture.broker.sessionState(session) == .missing)
        let next = try await fixture.initialize("after-reset")
        _ = try await fixture.open(next)
    }

    @Test func unissuedCursorRemainsAnInputError() async throws {
        let fixture = try BrokerFixture()
        let session = try await fixture.initialize("cursor")
        do {
            _ = try await fixture.request(session, method: "tools/list", parameters: .object(["cursor": .string("unissued")]))
            Issue.record("unissued cursor was accepted")
        } catch let error as NativeHostBrokerReplyError {
            guard case .mcpError(_, let code, _, _, _) = error.reply else {
                Issue.record("cursor error lost its protocol reply"); return
            }
            #expect(code == -32602)
        }
    }

    @Test func toolsListTimeoutDoesNotPublishAnIncompleteCatalog() async throws {
        let clocks = makeRuntimeCoordinatorDeterministicClocks()
        let fixture = try BrokerFixture(clock: clocks.clock, holdsInitialization: true)
        let session = try await fixture.initialize("timeout")
        let pending = Task { try await fixture.request(session, method: "tools/list") }
        try await fixture.factory.created.wait(description: "native runtime created")
        let transport = try #require(fixture.factory.transports.withLockedValue { $0.first })
        try await transport.initializationStarted.wait(description: "catalog waits for initialization")
        try await waitForSuspendedSleepers(on: clocks.timeoutClock)
        clocks.uptimeClock.advance(by: .seconds(5))
        clocks.timeoutClock.advance(by: .seconds(5))
        do {
            _ = try await pending.value
            Issue.record("timeout published an incomplete catalog")
        } catch let error as NativeHostBrokerReplyError {
            guard case .mcpError(_, let code, _, _, _) = error.reply else {
                Issue.record("timeout lost its protocol reply"); return
            }
            #expect(code == -32000)
        }
        try transport.releaseInitialization()
    }
}

private final class BrokerTransport: UpstreamSlotControlling, Sendable {
    let events: AsyncStream<Upstream.Event>
    private let continuation: AsyncStream<Upstream.Event>.Continuation
    let waiting = TestSignal()
    let stopped = TestSignal()
    let holdsStop = NIOLockedValueBox(false)
    let releaseStop = TestSignal()
    let initializationStarted = TestSignal()
    private let initialization = NIOLockedValueBox((held: false, pending: [JSONRPC.ID]()))
    let cancelled = TestSignal()
    let serverResponseReceived = TestSignal()
    let serverResponseIDs = NIOLockedValueBox<[JSONValue]>([])
    let index: Int64
    let processID: Int64
    let gui: Bool
    let guiWorkspacePaths: [String]
    let manifestOpensDirectory: Bool
    let interactionKeyProperty = NIOLockedValueBox("interactSessionKey")
    let methods = NIOLockedValueBox<[String]>([])
    private let pending = NIOLockedValueBox<[JSONRPC.ID]>([])
    struct Call: Sendable {
        let name: String
        let arguments: [String: JSONValue]
    }
    let calls = NIOLockedValueBox<[Call]>([])
    let toolFailures = NIOLockedValueBox<Set<String>>([])
    let returnsProtocolError = NIOLockedValueBox(false)
    private let openedPath = NIOLockedValueBox<String?>(nil)

    init(index: Int64, holdsInitialization: Bool, gui: Bool = false,
         guiWorkspacePaths: [String] = ["/Fixture/App.xcodeproj", "/Fixture/App.xcodeproj"],
         manifestOpensDirectory: Bool = false, processID: Int64? = nil) {
        self.index = index
        self.processID = processID ?? 1000 + index
        self.gui = gui
        self.guiWorkspacePaths = guiWorkspacePaths
        self.manifestOpensDirectory = manifestOpensDirectory
        initialization.withLockedValue { $0.held = holdsInitialization }
        let pair = AsyncStream<Upstream.Event>.makeStream()
        events = pair.stream
        continuation = pair.continuation
    }
    func start() async {}
    func stop() async {
        stopped.signal()
        if holdsStop.withLockedValue({ $0 }) {
            do { try await releaseStop.wait(description: "release held bridge stop") }
            catch { Issue.record(error) }
        }
        continuation.finish()
    }

    func send(_ data: Data) async -> Upstream.SendResult {
        do {
            let object = try JSONRPC.Wire.object(fromData: data)
            if case .response(let id) = JSONRPC.Message.Inspector.kind(of: object) {
                serverResponseIDs.withLockedValue { $0.append(id.value) }
                serverResponseReceived.signal()
                return .accepted
            }
            let method = object["method"] as? String
            if let method { methods.withLockedValue { $0.append(method) } }
            if method == "notifications/cancelled" { cancelled.signal(); return .accepted }
            guard let id = JSONRPC.Message.Inspector.requestID(from: object) else { return .accepted }
            let result: JSONValue
            switch method {
            case "initialize":
                let held = initialization.withLockedValue { state in
                    guard state.held else { return false }
                    state.pending.append(id)
                    return true
                }
                initializationStarted.signal()
                if held { return .accepted }
                result = initializeResult
            case "tools/list":
                let scoped = ["GetBuildLog", "BuildProject", "XcodeCloseWorkspace", "RunProject", "GetConsoleOutput",
                              "DeviceInteractionInstallAndRun"]
                var tools = scoped.map { descriptor($0, properties: [gui ? "tabIdentifier" : "workspaceIdentifier": .object(["type": .string("string")])]) }
                tools.append(contentsOf: [
                    descriptor("DocumentationSearch", properties: ["query": .object(["type": .string("string")])]),
                    descriptor("XcodeListTemplates"),
                    descriptor("XcodeNewProject", properties: [
                        "templateIdentifier": .object(["type": .string("string")]),
                        "productName": .object(["type": .string("string")]),
                        "destinationPath": .object(["type": .string("string")]),
                    ]),
                    descriptor("XcodeOpenWorkspace", properties: ["path": .object(["type": .string("string")])]),
                    descriptor(gui ? "XcodeListWindows" : "XcodeListWorkspaces"),
                    descriptor("DeviceInteractionStartSession", properties: ["deviceIdentifier": .object(["type": .string("string")]),
                        "sessionIdentifier": .object(["type": .string("string")])]),
                    descriptor("DeviceInteractionSynthesize", properties: [interactionKeyProperty.withLockedValue { $0 }: .object(["type": .string("string")])]),
                    descriptor("DeviceInteractionEndSession", properties: ["interactionSessionKey": .object(["type": .string("string")])]),
                ])
                tools.append(descriptor("DeviceInteractionStartWorkspaceSession", properties: [
                    gui ? "tabIdentifier" : "workspaceIdentifier": .object(["type": .string("string")]),
                    "sessionIdentifier": .object(["type": .string("string")]),
                ]))
                result = .object(["tools": .array(tools), "_meta": .object([
                    "com.lynnswap.xcode-mcpkit/origin": .object([
                        "kind": .string("nativeHost"), "processID": .number(.int(processID)),
                    ]),
                ])])
            case "tools/call":
                let parameters = object["params"] as? [String: Any] ?? [:]
                let name = parameters["name"] as? String ?? ""
                let arguments: [String: JSONValue]
                if case .object(let fields)? = (parameters["arguments"] as? [String: Any]).flatMap(JSONValue.init(any:)) {
                    arguments = fields
                } else { arguments = [:] }
                calls.withLockedValue { $0.append(Call(name: name, arguments: arguments)) }
                if name == "GetBuildLog", returnsProtocolError.withLockedValue({ $0 }) {
                    continuation.yield(.message(try JSONRPC.Wire.errorResponseData(id: id, code: -32010,
                        message: "native protocol failure", data: .object(["reason": .string("fixture")]))))
                    return .accepted
                }
                if toolFailures.withLockedValue({ $0.contains(name) }) {
                    result = try NativeHostBroker.toolResult(.object(["message": .string("native failure")]), isError: true)
                } else if name == "BuildProject" {
                    pending.withLockedValue { $0.append(id) }
                    waiting.signal()
                    return .accepted
                } else {
                    switch name {
                    case "XcodeOpenWorkspace":
                        let path = NativeHostBroker.string(arguments["path"]) ?? "/Fixture/App.xcodeproj"
                        let workspacePath = manifestOpensDirectory && URL(filePath: path).lastPathComponent == "Package.swift"
                            ? URL(filePath: path).deletingLastPathComponent().path : path
                        openedPath.withLockedValue { $0 = workspacePath }
                        result = try NativeHostBroker.toolResult(.object([
                            "workspaceIdentifier": .string("native-w-\(index)"),
                            "workspacePath": .string(workspacePath),
                        ]))
                    case "XcodeListWorkspaces":
                        let message = openedPath.withLockedValue { $0 }.map {
                            "* workspaceIdentifier: native-w-\(index), workspacePath: \($0)\n"
                        } ?? "No open workspaces."
                        result = try NativeHostBroker.toolResult(.object(["message": .string(message)]))
                    case "XcodeListWindows":
                        let message = guiWorkspacePaths.enumerated().map { offset, path in
                            "* tabIdentifier: tab-\(offset + 1), workspacePath: \(path)"
                        }.joined(separator: "\n")
                        result = try NativeHostBroker.toolResult(.object(["message": .string(message)]))
                    case "XcodeCloseWorkspace":
                        openedPath.withLockedValue { $0 = nil }
                        result = try NativeHostBroker.toolResult(.object(["closed": .bool(true),
                            "workspaceIdentifier": arguments["workspaceIdentifier"] ?? .null]))
                    case "DeviceInteractionStartSession", "DeviceInteractionStartWorkspaceSession":
                        result = try NativeHostBroker.toolResult(.object(["interactionSessionKey": .string("native-device-\(index)")]))
                    case "RunProject":
                        result = try NativeHostBroker.toolResult(.object(["launchSessionReference": .string("native-launch-\(index)")]))
                    default: result = echoResult
                    }
                }
            default: result = .object([:])
            }
            continuation.yield(.message(try JSONRPC.Wire.resultResponseData(id: id, result: result)))
        } catch { Issue.record(error) }
        return .accepted
    }

    private func descriptor(_ name: String, properties: [String: JSONValue] = [:]) -> JSONValue {
        .object(["name": .string(name), "description": .string(name),
            "inputSchema": .object(["type": .string("object"), "properties": .object(properties)])])
    }

    private var initializeResult: JSONValue {
        .object(["protocolVersion": .string(MCPProtocolVersion.current),
            "capabilities": .object(["tools": .object([:])]),
            "serverInfo": .object(["name": .string("Native-\(index)"), "version": .string("1")])])
    }

    func releaseInitialization() throws {
        let ids = initialization.withLockedValue { state in
            state.held = false
            let ids = state.pending
            state.pending.removeAll()
            return ids
        }
        for id in ids {
            continuation.yield(.message(try JSONRPC.Wire.resultResponseData(id: id, result: initializeResult)))
        }
    }

    func emitServerRequest() throws {
        continuation.yield(.message(try JSONRPC.Wire.data(from: [
            "jsonrpc": "2.0", "id": "native-server-request",
            "method": "sampling/createMessage", "params": [String: Any](),
        ])))
    }

    func emitCatalogChanged() throws {
        continuation.yield(.message(try JSONRPC.Wire.data(from:
            JSONRPC.Wire.notificationObject(method: "notifications/tools/list_changed"))))
    }

    func emitExit() { continuation.yield(.exit(1)) }

    private var echoResult: JSONValue {
        .object(["content": .array([.object(["type": .string("text"), "text": .string("host \(index)")])]),
            "structuredContent": .object(["host": .number(.int(index)),
                "data": .object(["workspaceIdentifier": .string("native-w-\(index)"), "tabIdentifier": .string("user-data")])]),
                "isError": .bool(false)])
    }
    func releaseWait() async {
        for id in pending.withLockedValue({ values in let ids = values; values.removeAll(); return ids }) {
            do { continuation.yield(.message(try JSONRPC.Wire.resultResponseData(id: id, result: echoResult))) }
            catch { Issue.record(error) }
        }
    }
}

private final class BrokerRuntimeFactory: Sendable {
    let transports = NIOLockedValueBox<[BrokerTransport]>([])
    let guiWorkspacePaths = NIOLockedValueBox(["/Fixture/App.xcodeproj", "/Fixture/App.xcodeproj"])
    let manifestOpensDirectory = NIOLockedValueBox(false)
    let catalogChanges = LockedRecordedValues<Void>()
    let replacements = LockedRecordedValues<BrokerTransport>()
    let shutdowns = LockedRecordedValues<Int64>()
    let failNewHosts = NIOLockedValueBox(false)
    let holdsInitialization = NIOLockedValueBox(false)
    let replyOverrides = NIOLockedValueBox<[String: ProxyRuntimeReply]>([:])
    let created = TestSignal()
    func make(_ configuration: ProxyRuntimeConfiguration) throws -> any ProxyRuntimeServing {
        if failNewHosts.withLockedValue({ $0 }) { throw NativeHostBrokerError("fixture startup failed") }
        let upstream = transports.withLockedValue { values in
            let transport = BrokerTransport(index: Int64(values.count + 1),
                                            holdsInitialization: holdsInitialization.withLockedValue { $0 },
                                            gui: configuration.guiProcess != nil,
                                            guiWorkspacePaths: guiWorkspacePaths.withLockedValue { $0 },
                                            manifestOpensDirectory: manifestOpensDirectory.withLockedValue { $0 })
            values.append(transport)
            return transport
        }
        created.signal()
        let runtime = ProxyRuntime.testing(configuration: configuration) { eventLoop, notification, closed, catalogChanged in
            let coordinator = RuntimeCoordinator(
                config: configuration, eventLoop: eventLoop, upstreams: [upstream],
                nativeUpstreamFactory: { [self] in
                    let replacement = BrokerTransport(index: upstream.index,
                        holdsInitialization: holdsInitialization.withLockedValue { $0 }, gui: upstream.gui,
                        guiWorkspacePaths: guiWorkspacePaths.withLockedValue { $0 },
                        manifestOpensDirectory: manifestOpensDirectory.withLockedValue { $0 },
                        processID: transports.withLockedValue { Int64(1001 + $0.count) })
                    transports.withLockedValue { $0.append(replacement) }
                    replacements.append(replacement)
                    return replacement
                }, notificationSink: notification, sessionClosedSink: closed,
                catalogChangedSink: { [self] in catalogChanged(); catalogChanges.append(()) }, startImmediately: false)
            return coordinator
        }
        return BrokerReplyRuntime(base: runtime, overrides: replyOverrides,
                                  shutdownCompleted: { [self] in shutdowns.append(upstream.index) })
    }
}

private struct BrokerReplyRuntime: ProxyRuntimeServing {
    let base: any ProxyRuntimeServing
    let overrides: NIOLockedValueBox<[String: ProxyRuntimeReply]>
    let shutdownCompleted: @Sendable () -> Void

    func start() { base.start() }
    func cancelForDeinit() { base.cancelForDeinit() }
    func shutdown() async { await base.shutdown(); shutdownCompleted() }
    func subscribeToEvents(_ receive: @escaping @Sendable (ProxyRuntimeEvent) -> Void) -> @Sendable () -> Void {
        base.subscribeToEvents(receive)
    }
    func beginRequest(_ message: ProxyRuntimeRequest, in session: ProxySessionID?) -> (any ProxyRuntimeRequestOperating)? {
        guard let operation = base.beginRequest(message, in: session) else { return nil }
        let method = (message.decodedJSON?.foundationObject as? [String: Any])?["method"] as? String
        let key = NativeHostBroker.toolName(in: message) ?? method ?? ""
        guard let reply = overrides.withLockedValue({ $0[key] }) else { return operation }
        return BrokerReplyOperation(base: operation, reply: reply)
    }
    func clientRequestFinished(_ id: ProxySessionID) { base.clientRequestFinished(id) }
    func sessionState(_ id: ProxySessionID) -> ProxyRuntimeSessionState { base.sessionState(id) }
    func clientEventStreamOpened(_ id: ProxySessionID) -> Bool { base.clientEventStreamOpened(id) }
    func clientEventStreamClosed(_ id: ProxySessionID) { base.clientEventStreamClosed(id) }
    func expireInactiveSessions(inactiveFor: TimeAmount) { base.expireInactiveSessions(inactiveFor: inactiveFor) }
    func removeSession(_ id: ProxySessionID) { base.removeSession(id) }
    func snapshot() -> ProxyRuntimeSnapshot { base.snapshot() }
    func debugSnapshotData(includeSensitivePayloads: Bool) -> Data? {
        base.debugSnapshotData(includeSensitivePayloads: includeSensitivePayloads)
    }
    func reset() async { await base.reset() }
}

private struct BrokerReplyOperation: ProxyRuntimeRequestOperating {
    let base: any ProxyRuntimeRequestOperating
    let reply: ProxyRuntimeReply

    func whenComplete(_ completion: @escaping @Sendable (Result<ProxyRuntimeReply, any Error>) -> Void) {
        base.whenComplete { result in completion(result.map { _ in reply }) }
    }
    func cancel(reason: ProxyRuntimeCancellationReason) { base.cancel(reason: reason) }
}

private final class BrokerFixture: Sendable {
    let broker: NativeHostBroker
    let factory = BrokerRuntimeFactory()
    let events = NIOLockedValueBox<[ProxyRuntimeEvent]>([])
    let serverRequestDelivered = TestSignal()
    let guiProcesses = NIOLockedValueBox<[XcodeGUIProcess]>([])
    let defaultInstallation = XcodeHostInstallation(developerDirectory: URL(fileURLWithPath: "/Fixture/Default.app"))

    init(clock: ClockClient = .liveValue, holdsInitialization: Bool = false,
         guiProcesses: [XcodeGUIProcess] = []) throws {
        let factory = factory
        factory.holdsInitialization.withLockedValue { $0 = holdsInitialization }
        let events = events
        let defaultInstallation = defaultInstallation
        let processes = self.guiProcesses
        processes.withLockedValue { $0 = guiProcesses }
        let inventory = XcodeHostInventory(defaultInstallation: defaultInstallation,
            runningGUIProcesses: { processes.withLockedValue { $0 } },
            isGUIProcessRunning: { process in processes.withLockedValue { $0.contains(process) } }) {
            [defaultInstallation, XcodeHostInstallation(developerDirectory: URL(fileURLWithPath: "/Fixture/Other.app"))]
        }
        broker = try NativeHostBroker(configuration: makeConfig(requestTimeout: 5),
                                  inventory: inventory, clock: clock, factory: factory.make)
        let delivered = serverRequestDelivered
        let cancel = broker.subscribeToEvents { event in
            events.withLockedValue { $0.append(event) }
            if case .notification(_, let data) = event,
               let object = try? JSONRPC.Wire.object(fromData: data),
               case .request("sampling/createMessage", _) = JSONRPC.Message.Inspector.kind(of: object) {
                delivered.signal()
            }

        }
        let broker = broker
        #expect(registerAsyncTestCleanup(description: "broker shutdown") {
            await broker.shutdown()
            cancel()
        })
    }

    func open(_ session: ProxySessionID, host: JSONValue? = nil,
              independent: Bool = false) async throws -> JSONValue {
        var arguments: [String: JSONValue] = ["path": .string("/Fixture/App.xcodeproj")]
        if let host { arguments["hostIdentifier"] = host }
        if independent { arguments["createsNewHost"] = .bool(true) }
        let result = try await call(session, name: NativeHostBroker.openWorkspaceTool, arguments: arguments)
        guard let identifier = result["workspaceIdentifier"] else {
            throw NativeHostBrokerError("missing workspace reference")
        }
        return identifier
    }

    func workspaces(_ session: ProxySessionID) async throws -> [[String: JSONValue]] {
        let result = try await call(session, name: NativeHostBroker.listWorkspacesTool)
        guard case .array(let values)? = result["workspaces"] else {
            throw NativeHostBrokerError("missing workspace list")
        }
        return values.compactMap { if case .object(let fields) = $0 { fields } else { nil } }
    }

    func toolResult(_ session: ProxySessionID, name: String,
                    arguments: [String: JSONValue] = [:], id: Int64 = 19) async throws -> JSONValue {
        try await request(session, method: "tools/call", parameters: .object([
            "name": .string(name), "arguments": .object(arguments),
        ]), id: id)
    }

    func initialize(_ name: String) async throws -> ProxySessionID {
        let id = ProxySessionID(rawValue: name)
        _ = try await request(id, method: "initialize", parameters: .object([
            "protocolVersion": .string(MCPProtocolVersion.current),
            "capabilities": .object([:]),
            "clientInfo": .object(["name": .string(name), "version": .string("1")]),
        ]))
        return id
    }

    func reply(_ session: ProxySessionID, method: String, parameters: JSONValue? = nil,
               id: Int64? = 19) async throws -> ProxyRuntimeReply {
        var json: [String: JSONValue] = ["jsonrpc": .string("2.0"), "method": .string(method)]
        if let id { json["id"] = .number(.int(id)) }
        if let parameters { json["params"] = parameters }
        let request = try ProxyRuntimeRequest(json: .object(json),
            headerSessionExists: method != "initialize", prefersEventStream: false)
        let operation = try #require(broker.beginRequest(request, in: session))
        defer { broker.clientRequestFinished(session) }
        return try await waitWithTimeout("broker request", timeout: .seconds(10)) {
            try await withCheckedThrowingContinuation { continuation in
                operation.whenComplete { continuation.resume(with: $0) }
            }
        }
    }

    func request(_ session: ProxySessionID, method: String, parameters: JSONValue? = nil,
                 id: Int64? = 19) async throws -> JSONValue {
        try NativeHostBroker.result(in: await reply(session, method: method, parameters: parameters, id: id))
    }
    func call(_ session: ProxySessionID, name: String,
              arguments: [String: JSONValue] = [:]) async throws -> [String: JSONValue] {
        let result = try await request(session, method: "tools/call", parameters: .object([
            "name": .string(name), "arguments": .object(arguments),
        ]))
        guard case .object(let object) = result, case .object(let content)? = object["structuredContent"] else {
            throw NativeHostBrokerError("missing tool result")
        }
        return content
    }
    func list(_ session: ProxySessionID) async throws -> [[String: JSONValue]] {
        let value = try await call(session, name: NativeHostBroker.listTool)
        guard case .array(let hosts)? = value["hosts"] else {
            throw NativeHostBrokerError("missing host list")
        }
        return hosts.compactMap { if case .object(let fields) = $0 { fields } else { nil } }
    }

}
