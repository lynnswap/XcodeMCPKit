@testable import XcodeMCPProxyRuntimeTestSupport
import Foundation
import NIO
import Testing
import XcodeMCPProxyTestSupport
@testable import XcodeMCPProxyRuntime

@Suite(.serialized, .asyncTestCleanup)
struct DeviceInteractionRoutingTests {
    @Test func continuationRoutesToTheExactUpstreamThatCreatedTheSession() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let target = xcodeProcessTarget(processID: 701, xcodeVersion: "27.0")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: group.next(),
            upstreams: [TestUpstreamClient(), TestUpstreamClient()],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0, 1])
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)

        let creatingLease = manager.operationLeaseForTest(upstreamIndex: 1)
        manager.recordDeviceInteractionAffinityIfNeeded(
            requestData: try requestData(
                name: "DeviceInteractionStartSession",
                arguments: ["sessionIdentifier": "Verify Flow"]
            ),
            responseData: try successfulToolResponse(
                structuredContent: ["interactionSessionKey": "device-key"]
            ),
            operationLease: creatingLease
        )

        let decision = await manager.toolRoutingDecision(
            for: toolsCallObject(
                id: 2,
                name: "DeviceInteractionSynthesize",
                arguments: ["interactSessionKey": "device-key"]
            ),
            requestTimeoutOverride: nil
        )
        guard case .forwardAdmitted(let indices, let admission) = decision else {
            Issue.record("expected affinity-bound routing")
            return
        }
        #expect(indices == [1])
        #expect(admission.upstreamProofs == [creatingLease.proof])
        #expect(admission.route?.routeID == manager.xcodeProcessRoutes[0].id)

        #expect(
            manager.recordXcodeWindowOwners(
                from: try jsonValue([
                    "structuredContent": [
                        "message": "* tabIdentifier: raw-tab, workspacePath: /Work/App.xcworkspace"
                    ]
                ]),
                upstreamIndex: 1
            )
        )
        let proxyTabIdentifier = try #require(
            manager.windowOwnershipAuthority.snapshot().identities.first?.proxyTabIdentifier
        )
        let installRequest = toolsCallObject(
            id: 5,
            name: "DeviceInteractionInstallAndRun",
            arguments: [
                "interactionSessionKey": "device-key",
                "tabIdentifier": proxyTabIdentifier,
            ]
        )
        let installDecision = await manager.toolRoutingDecision(for: installRequest, requestTimeoutOverride: nil)
        guard case .forwardAdmitted(let installIndices, let installAdmission) = installDecision else {
            Issue.record("expected affinity-bound workspace routing")
            return
        }
        #expect(installIndices == [1])
        #expect(installAdmission.window != nil)
        let installData = try JSONSerialization.data(withJSONObject: installRequest)
        let rewritten = manager.rewriteOwnerBoundRequest(
            bodyData: installData,
            parsedRequestJSON: installRequest,
            operationLease: creatingLease,
            admission: installAdmission
        )
        let rewrittenObject = try #require(
            JSONSerialization.jsonObject(with: rewritten.bodyData) as? [String: Any]
        )
        let rewrittenParams = try #require(rewrittenObject["params"] as? [String: Any])
        let rewrittenArguments = try #require(
            rewrittenParams["arguments"] as? [String: Any]
        )
        #expect(rewrittenArguments["tabIdentifier"] as? String == "raw-tab")
    }

    @Test func successfulEndRemovesTheRecordedAffinity() async throws {
        let fixture = try makeSingleRouteFixture(processID: 702)
        defer { fixture.shutdown() }

        fixture.manager.recordDeviceInteractionAffinityIfNeeded(
            requestData: try requestData(
                name: "DeviceInteractionStartSession",
                arguments: ["sessionIdentifier": "Verify Flow"]
            ),
            responseData: try successfulToolResponse(
                structuredContent: ["interactionSessionKey": "device-key"]
            ),
            operationLease: fixture.operationLease
        )
        fixture.manager.recordDeviceInteractionAffinityIfNeeded(
            requestData: try requestData(
                name: "DeviceInteractionEndSession",
                arguments: ["interactionSessionKey": "device-key"]
            ),
            responseData: try successfulToolResponse(structuredContent: [:]),
            operationLease: fixture.operationLease
        )

        let decision = await fixture.manager.toolRoutingDecision(
            for: toolsCallObject(
                id: 3,
                name: "DeviceInteractionEndSession",
                arguments: ["interactionSessionKey": "device-key"]
            ),
            requestTimeoutOverride: nil
        )
        guard case .forwardAdmitted(let indices, _) = decision else {
            Issue.record("an ended session delegates native validation when only one connection exists: \(decision)")
            return
        }
        #expect(indices == [0])
        #expect(fixture.manager.deviceInteractionAffinityAuthority.affinity(for: "device-key") == nil)
    }

    @Test func upstreamReplacementInvalidatesAffinity() async throws {
        let fixture = try makeSingleRouteFixture(processID: 703)
        defer { fixture.shutdown() }

        fixture.manager.recordDeviceInteractionAffinityIfNeeded(
            requestData: try requestData(
                name: "DeviceInteractionStartSession",
                arguments: ["sessionIdentifier": "Verify Flow"]
            ),
            responseData: try successfulToolResponse(
                structuredContent: ["interactionSessionKey": "device-key"]
            ),
            operationLease: fixture.operationLease
        )
        let transition = fixture.manager.commitUpstreamTopologyMutation {
            fixture.manager.upstreamTopology.replace(
                fixture.operationLease.proof,
                with: TestUpstreamClient()
            )
        }
        #expect(transition != nil)
        #expect(fixture.manager.deviceInteractionAffinityAuthority.count() == 0)
    }

    @Test func servicePoolRoutesToExactCreatingUpstreamAndEvictsOnReplacement() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        var config = makeConfig(requestTimeout: 5)
        config.includesXcodeService = true
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: group.next(),
            upstreams: [TestUpstreamClient(), TestUpstreamClient()],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)

        let creatingLease = manager.operationLeaseForTest(upstreamIndex: 1)
        manager.recordDeviceInteractionAffinityIfNeeded(
            requestData: try requestData(
                name: "DeviceInteractionStartWorkspaceSession",
                arguments: ["sessionIdentifier": "Verify Headless Flow"]
            ),
            responseData: try successfulToolResponse(
                structuredContent: ["interactionSessionKey": "headless-device-key"]
            ),
            operationLease: creatingLease
        )

        let affinity = try #require(
            manager.deviceInteractionAffinityAuthority.affinity(for: "headless-device-key")
        )
        #expect(affinity.upstreamProof == creatingLease.proof)
        #expect(affinity.routeID == nil)
        let routed = await manager.toolRoutingDecision(
            for: toolsCallObject(
                id: 6,
                name: "DeviceInteractionSynthesize",
                arguments: ["interactSessionKey": "headless-device-key"]
            ),
            requestTimeoutOverride: nil
        )
        guard case .forwardAdmitted(let routedIndices, let routedAdmission) = routed else {
            Issue.record("expected exact unbound affinity routing")
            return
        }
        #expect(routedIndices == [1])
        #expect(routedAdmission.route == nil)
        #expect(routedAdmission.upstreamProofs == [creatingLease.proof])

        let transition = manager.commitUpstreamTopologyMutation {
            manager.upstreamTopology.replace(
                creatingLease.proof,
                with: TestUpstreamClient()
            )
        }
        #expect(transition != nil)
        #expect(manager.deviceInteractionAffinityAuthority.count() == 0)

        let afterReplacement = await manager.toolRoutingDecision(
            for: toolsCallObject(
                id: 7,
                name: "DeviceInteractionSynthesize",
                arguments: ["interactSessionKey": "headless-device-key"]
            ),
            requestTimeoutOverride: nil
        )
        guard case .reject(let errors) = afterReplacement else {
            Issue.record("replaced unbound affinity should be rejected")
            return
        }
        #expect(errors.map(\.message) == ["unknown device interaction session"])
    }

    @Test func serviceWorkspacePathPreservesTheCreatingConnection() async throws {
        let first = TestUpstreamClient()
        let owner = TestUpstreamClient()
        var config = makeConfig(requestTimeout: 5)
        config.includesXcodeService = true
        let fixture = RuntimeCoordinatorFixture(
            config: config, upstreams: [first, owner], startImmediately: false
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)
        let creatingLease = manager.operationLeaseForTest(upstreamIndex: 1)
        manager.recordDeviceInteractionAffinityIfNeeded(
            requestData: try requestData(name: "DeviceInteractionStartWorkspaceSession", arguments: ["sessionIdentifier": "test"]),
            responseData: try successfulToolResponse(structuredContent: ["interactionSessionKey": "device-key"]),
            operationLease: creatingLease
        )
        let request = toolsCallObject(id: 3, name: "DeviceInteractionInstallAndRun", arguments: [
            "interactionSessionKey": "device-key", "workspaceIdentifier": "/Work/App.xcodeproj"
        ])
        let task = Task { await manager.toolRoutingDecision(for: request, requestTimeoutOverride: .seconds(2)) }
        let lookup = try await owner.nextSent(at: 0)
        await owner.yield(.message(try makeJSONRPCResponse(
            id: extractUpstreamID(from: lookup),
            result: ["structuredContent": ["message": "* workspaceIdentifier: opaque-id, workspacePath: /Work/App.xcodeproj"]]
        )))
        let decision = await task.value
        guard case .forwardAdmitted(let indices, let admission) = decision else {
            Issue.record("expected the creating Service connection")
            return
        }
        #expect(indices == [1])
        #expect(admission.upstreamProofs == [creatingLease.proof])
        #expect(admission.workspaceIdentifier == "opaque-id")
        #expect(await first.sentCount() == 0)
    }

    @Test func headlessUnboundPoolRejectsUnknownSessionInsteadOfGuessing() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        var config = makeConfig(requestTimeout: 5)
        config.includesXcodeService = true
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: group.next(),
            upstreams: [TestUpstreamClient(), TestUpstreamClient()],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }

        let decision = await manager.toolRoutingDecision(
            for: toolsCallObject(
                id: 8,
                name: "DeviceInteractionEndSession",
                arguments: ["interactionSessionKey": "external-key"]
            ),
            requestTimeoutOverride: nil
        )
        guard case .reject(let errors) = decision else {
            Issue.record("multi-upstream unbound runtime must not guess a session owner")
            return
        }
        #expect(errors.map(\.message) == ["unknown device interaction session"])
    }

    @Test(arguments: [false, true])
    func onlyConnectionDelegatesUnknownSessionValidation(gui: Bool) async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        var config = makeConfig(requestTimeout: 5)
        config.includesXcodeService = true
        let target = xcodeProcessTarget(processID: 705, xcodeVersion: "27.0")
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: group.next(),
            upstreams: [TestUpstreamClient()],
            xcodeProcessRoutes: gui ? [XcodeProcessRoute(target: target, upstreamIndices: [0])] : [],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        if gui {
            try seedProcessToolCatalogs(on: manager, entries: [
                (target, 0, [toolDescriptor(name: "DeviceInteractionSynthesize")])
            ])
        }

        let decision = await manager.toolRoutingDecision(
            for: toolsCallObject(
                id: 4,
                name: "DeviceInteractionSynthesize",
                arguments: ["interactSessionKey": "external-key"]
            ),
            requestTimeoutOverride: nil
        )
        #expect(decision.preferredUpstreamIndices == [0])
    }

    private struct Fixture {
        let group: MultiThreadedEventLoopGroup
        let manager: RuntimeCoordinator
        let operationLease: UpstreamOperationLease

        func shutdown() {
            manager.shutdownAndWait()
            try? group.syncShutdownGracefully()
        }
    }

    private func makeSingleRouteFixture(processID: pid_t) throws -> Fixture {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let target = xcodeProcessTarget(processID: processID, xcodeVersion: "27.0")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: group.next(),
            upstreams: [TestUpstreamClient()],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0])
            ],
            startImmediately: false
        )
        manager.markUpstreamInitialized(upstreamIndex: 0)
        try seedProcessToolCatalogs(on: manager, entries: [
            (target, 0, [toolDescriptor(name: "DeviceInteractionEndSession")])
        ])
        return Fixture(
            group: group,
            manager: manager,
            operationLease: manager.operationLeaseForTest(upstreamIndex: 0)
        )
    }

    private func requestData(name: String, arguments: [String: Any]) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: toolsCallObject(id: 1, name: name, arguments: arguments)
        )
    }

    private func successfulToolResponse(
        structuredContent: [String: Any]
    ) throws -> Data {
        try makeJSONRPCResponse(
            id: 1,
            result: [
                "content": [],
                "structuredContent": structuredContent,
                "isError": false,
            ]
        )
    }
}
