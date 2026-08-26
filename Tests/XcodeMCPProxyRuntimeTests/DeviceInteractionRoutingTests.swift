import Foundation
import NIO
import Testing
@testable import XcodeMCPProxyRuntime

@Suite(.serialized, .asyncTestCleanup)
struct DeviceInteractionRoutingTests {
    @Test func continuationRoutesToTheExactUpstreamThatCreatedTheSession() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
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

        let decision = try #require(
            manager.immediateToolRoutingDecision(
                for: toolsCallObject(
                    id: 2,
                    name: "DeviceInteractionSynthesize",
                    arguments: ["interactSessionKey": "device-key"]
                )
            )
        )
        guard case .forwardAdmitted(let indices, let admission) = decision else {
            Issue.record("expected affinity-bound routing")
            return
        }
        #expect(indices == [1])
        #expect(admission.upstreamProofs == [creatingLease.proof])
        #expect(admission.route.routeID == manager.xcodeProcessRoutes[0].id)

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
        let installDecision = try #require(
            manager.immediateToolRoutingDecision(for: installRequest)
        )
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

    @Test func successfulEndRemovesTheRecordedAffinity() throws {
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

        let decision = try #require(
            fixture.manager.immediateToolRoutingDecision(
                for: toolsCallObject(
                    id: 3,
                    name: "DeviceInteractionEndSession",
                    arguments: ["interactionSessionKey": "device-key"]
                )
            )
        )
        guard case .reject(let errors) = decision else {
            Issue.record("ended session should no longer have affinity")
            return
        }
        #expect(errors.map(\.message) == ["unknown device interaction session"])
    }

    @Test func upstreamReplacementInvalidatesAffinity() throws {
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

    @Test func headlessUnboundPoolRoutesToExactCreatingUpstreamAndEvictsOnReplacement() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        var config = makeConfig(requestTimeout: 5)
        config.xcodeMode = .headless
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: group.next(),
            upstreams: [TestUpstreamClient(), TestUpstreamClient()],
            processRoutingEnabled: false,
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
        let routed = try #require(
            manager.immediateToolRoutingDecision(
                for: toolsCallObject(
                    id: 6,
                    name: "DeviceInteractionSynthesize",
                    arguments: ["interactSessionKey": "headless-device-key"]
                )
            )
        )
        guard case .forwardExact(let routedProof) = routed else {
            Issue.record("expected exact unbound affinity routing")
            return
        }
        #expect(routedProof == creatingLease.proof)

        let transition = manager.commitUpstreamTopologyMutation {
            manager.upstreamTopology.replace(
                creatingLease.proof,
                with: TestUpstreamClient()
            )
        }
        #expect(transition != nil)
        #expect(manager.deviceInteractionAffinityAuthority.count() == 0)

        let afterReplacement = try #require(
            manager.immediateToolRoutingDecision(
                for: toolsCallObject(
                    id: 7,
                    name: "DeviceInteractionSynthesize",
                    arguments: ["interactSessionKey": "headless-device-key"]
                )
            )
        )
        guard case .reject(let errors) = afterReplacement else {
            Issue.record("replaced unbound affinity should be rejected")
            return
        }
        #expect(errors.map(\.message) == ["unknown device interaction session"])
    }

    @Test func headlessUnboundPoolRejectsUnknownSessionInsteadOfGuessing() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        var config = makeConfig(requestTimeout: 5)
        config.xcodeMode = .headless
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: group.next(),
            upstreams: [TestUpstreamClient(), TestUpstreamClient()],
            processRoutingEnabled: false,
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }

        let decision = try #require(
            manager.immediateToolRoutingDecision(
                for: toolsCallObject(
                    id: 8,
                    name: "DeviceInteractionEndSession",
                    arguments: ["interactionSessionKey": "external-key"]
                )
            )
        )
        guard case .reject(let errors) = decision else {
            Issue.record("multi-upstream unbound runtime must not guess a session owner")
            return
        }
        #expect(errors.map(\.message) == ["unknown device interaction session"])
    }

    @Test func exactUnboundDecisionRejectsReplacementGenerationBeforeSending() async throws {
        let config = makeHTTPConfig()
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamResponder: { _, originalID in
                try makeToolSuccessResponse(id: originalID, text: #"{"ok":true}"#)
            }
        )
        sessionManager.setInitialized(true)
        sessionManager.setToolRoutingDecision(
            .forwardExact(
                upstreamProof: UpstreamTopologyProof(
                    slotID: UpstreamSlotID(rawValue: 1),
                    slotGeneration: 0
                )
            )
        )
        sessionManager.setUsablePreferredUpstreamIndices([1])
        let server = try TestHTTPHandlerServer.start(
            config: config,
            sessionManager: sessionManager
        )

        do {
            let (response, body) = try await postHTTPJSON(
                url: server.url,
                sessionID: "session-replaced-unbound-affinity",
                payload: toolsCallPayload(
                    id: 9,
                    name: "DeviceInteractionSynthesize",
                    arguments: ["interactSessionKey": "headless-device-key"]
                )
            )

            #expect(response.statusCode == 200)
            let error = try #require(body["error"] as? [String: Any])
            #expect((error["code"] as? NSNumber)?.intValue == -32001)
            #expect(error["message"] as? String == "upstream unavailable")
            #expect(sessionManager.sentMethods().isEmpty)
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func unboundRuntimeLeavesUnknownSessionHandlingToItsOnlyUpstream() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        var config = makeConfig(requestTimeout: 5)
        config.xcodeMode = .headless
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: group.next(),
            upstreams: [TestUpstreamClient()],
            processRoutingEnabled: false,
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }

        let decision = try #require(
            manager.immediateToolRoutingDecision(
                for: toolsCallObject(
                    id: 4,
                    name: "DeviceInteractionSynthesize",
                    arguments: ["interactSessionKey": "external-key"]
                )
            )
        )
        guard case .forward(let preferred) = decision else {
            Issue.record("unbound runtime should preserve upstream handling")
            return
        }
        #expect(preferred == nil)
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
