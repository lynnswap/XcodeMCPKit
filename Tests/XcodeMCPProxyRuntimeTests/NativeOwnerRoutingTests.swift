@testable import XcodeMCPProxyRuntimeTestSupport
@testable import XcodeMCPCore
import Foundation
import NIO
import NIOConcurrencyHelpers
import NIOEmbedded
import Testing
@testable import XcodeMCPProxyRuntime
import XcodeMCPProxyTestSupport

@Suite(.serialized, .asyncTestCleanup)
struct NativeOwnerRoutingTests {
    @Test(arguments: [false, true])
    func canonicalCatalogComesFromTheOwnedHostAndItsFailuresAreExposed(fails: Bool) async throws {
        let native = TestUpstreamClient()
        let gui = TestUpstreamClient()
        let target = xcodeProcessTarget(processID: 992, xcodeVersion: "27.0")
        let fixture = RuntimeCoordinatorFixture(upstreams: [native, gui],
            xcodeProcessRoutes: [XcodeProcessRoute(target: target, upstreamIndices: [1])], startImmediately: false)
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)
        seedCoordinatorSuiteInitialize(on: manager,
            result: try jsonValue(["protocolVersion": MCP.ProtocolVersion.current, "capabilities": [:]]), sourceUpstream: 0)
        let load = Task {
            try await manager.sharedToolsList(sessionID: "native-catalog", requestTimeoutOverride: .seconds(2))
        }
        let request = try await native.nextSent { methodName(from: $0) == "tools/list" }
        let id = try extractUpstreamID(from: request)
        #expect(await gui.sentCount() == 0)
        if fails {
            await native.yield(.message(try JSONRPC.Wire.errorResponseData(
                id: JSONRPC.ID(any: id), code: -32603, message: "Native catalog unavailable")))
            do {
                _ = try await load.value
                Issue.record("An unavailable owned catalog must reach the caller")
            } catch {
                #expect(ControlPlane.ErrorMapper.jsonRPCError(for: error).message == "Native catalog unavailable")
            }
            #expect(await gui.sentCount() == 0)
        } else {
            await native.yield(.message(try makeDocumentationToolsListResponse(
                id: id, tools: [toolDescriptor(name: "FutureNativeTool")])) )
            #expect(toolNames(in: try await load.value) == ["FutureNativeTool"])
        }
    }

    @Test func ordinaryWorkspacePathIsPassedToTheOwnedHostWithoutInventoryOrOpenRPCs() async throws {
        let upstream = TestUpstreamClient()
        let fixture = RuntimeCoordinatorFixture(upstreams: [upstream], startImmediately: false)
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager
        manager.markUpstreamInitialized(upstreamIndex: 0)
        let path = "/Work/NewProject.xcodeproj"
        let decision = await manager.toolRoutingDecision(for: toolsCallObject(
            id: 100, name: "FutureWorkspaceTool", arguments: ["workspaceIdentifier": path]), requestTimeoutOverride: .seconds(1))
        guard case .forwardAdmitted(let indices, let admission) = decision else {
            Issue.record("A workspace path without a GUI owner must reach the owned host")
            return
        }
        #expect(indices == [0])
        #expect(admission.workspaceIdentifier == path)
        #expect(admission.route == nil)
        #expect(await upstream.sentCount() == 0)
    }

    @Test(arguments: [false, true])
    func nativeIdentifiersAndClosePathsRemainBoundToTheOwnedHost(close: Bool) async throws {
        let upstream = TestUpstreamClient()
        let fixture = RuntimeCoordinatorFixture(upstreams: [upstream], startImmediately: false)
        defer { fixture.shutdownAndWait() }
        fixture.manager.markUpstreamInitialized(upstreamIndex: 0)
        let selector = close ? "/Work/Absent.xcodeproj" : "native-workspace-id"
        let decision = await fixture.manager.toolRoutingDecision(for: toolsCallObject(
            id: 101, name: close ? "XcodeCloseWorkspace" : "FutureWorkspaceTool",
            arguments: ["workspaceIdentifier": selector]), requestTimeoutOverride: .seconds(1))
        guard case .forwardAdmitted(let indices, let admission) = decision else {
            Issue.record("Owned native workspace identity must stay with its host")
            return
        }
        #expect(indices == [0])
        #expect(admission.route == nil)
        #expect(await upstream.sentCount() == 0)
    }

    @Test(arguments: ["path", "identifier", "symlink", "failure"])
    func GUIInventorySelectsTheOwnerAndFailuresAreNotHiddenByTheNativeHost(kind: String) async throws {
        let native = TestUpstreamClient()
        let gui = TestUpstreamClient()
        let target = xcodeProcessTarget(processID: 991, xcodeVersion: "27.0")
        let fixture = RuntimeCoordinatorFixture(upstreams: [native, gui],
            xcodeProcessRoutes: [XcodeProcessRoute(target: target, upstreamIndices: [1])], startImmediately: false)
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)
        try seedProcessToolCatalogs(on: manager, entries: [(target, 1, [
            toolDescriptor(name: "XcodeListWindows"), ownerBoundToolDescriptor(name: "FutureWorkspaceTool"),
        ])])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("Project.xcodeproj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("Alias.xcodeproj")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: project)
        let selector = kind == "identifier" ? "gui-tab" : kind == "symlink" ? alias.path : project.path
        let task = Task {
            await manager.toolRoutingDecision(for: toolsCallObject(id: 102, name: "FutureWorkspaceTool",
                arguments: ["workspaceIdentifier": selector]), requestTimeoutOverride: .seconds(2))
        }
        let request = try await gui.nextSent {
            methodName(from: $0) == "tools/call" && toolCallName(from: $0) == "XcodeListWindows"
        }
        let id = try extractUpstreamID(from: request)
        if kind == "failure" {
            await gui.yield(.message(try JSONRPC.Wire.errorResponseData(
                id: JSONRPC.ID(any: id), code: -32603, message: "GUI inventory failed")))
        } else {
            await gui.yield(.message(try makeXcodeListWindowsResponse(id: id,
                message: "* tabIdentifier: gui-tab, workspacePath: \(project.path)")))
        }
        let decision = await task.value
        if kind == "failure" {
            guard case .reject(let errors) = decision else {
                Issue.record("Incomplete GUI inventory must fail instead of falling back")
                return
            }
            #expect(errors.first?.message.contains("Unable to determine GUI workspace ownership") == true)
        } else {
            guard case .forwardAdmitted(let indices, let admission) = decision else {
                Issue.record("Native GUI ownership must take precedence")
                return
            }
            #expect(indices == [1])
            #expect(admission.window?.rewritePlan.tabIdentifier == "gui-tab")
        }
        #expect(await native.sentCount() == 0)
    }

    @Test func requestsShareOneNativeConnectionAndCancellingOneDoesNotBlockTheOthers() {
        let eventLoop = EmbeddedEventLoop()
        let topology = UpstreamTopologyAuthority([TestUpstreamClient()])
        let started = NIOLockedValueBox<[UUID]>([])
        let cancelled = NIOLockedValueBox<[UUID]>([])
        let scheduler = UpstreamSlotScheduler(isLeaseLive: { _ in true }, canUseUpstream: { index in
            .init(proof: topology.snapshot().proof(UpstreamSlotID(rawValue: index)), effects: [])
        }, selectUpstream: { _ in .init(proof: topology.snapshot().proof(UpstreamSlotID(rawValue: 0)), effects: []) },
            operationLease: { topology.operationLease(for: $0) }, validateOperationLease: { topology.validate($0) })
        defer { scheduler.reset(); eventLoop.run() }
        let leases = [UUID(), UUID(), UUID()]
        let descriptor = SessionRequestPipeline.Descriptor(sessionID: "native-multiplex", label: "tools/call",
            expectsResponse: true, isTopLevelClientRequest: true)
        for lease in leases {
            scheduler.enqueueRequest(leaseID: lease, descriptor: descriptor, on: eventLoop, preferredUpstreamIndex: 0,
                starter: { _ in started.withLockedValue { $0.append(lease) } },
                failUnavailable: { Issue.record("The live native connection must accept all requests") },
                failCancelled: { cancelled.withLockedValue { $0.append(lease) } })
        }
        scheduler.cancelQueuedRequest(leaseID: leases[2])
        eventLoop.run()
        #expect(Set(started.withLockedValue { $0 }) == Set(leases.prefix(2)))
        #expect(cancelled.withLockedValue { $0 } == [leases[2]])
        #expect(scheduler.debugSnapshot().activeLeaseCountByUpstream == [0: 2])
        scheduler.releaseUpstreamSlot(upstreamIndex: 0, leaseID: leases[0])
        #expect(scheduler.debugSnapshot().activeLeaseCountByUpstream == [0: 1])
    }
}
