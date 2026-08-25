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

    @Test func unboundRuntimeLeavesUnknownSessionHandlingToItsOnlyUpstream() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
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
