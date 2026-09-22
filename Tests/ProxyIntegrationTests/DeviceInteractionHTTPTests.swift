import Foundation
import Testing
import XcodeMCPProxyTestSupport
@testable import XcodeMCPProxyRuntime

@Suite(.serialized, .asyncTestCleanup)
struct DeviceInteractionHTTPTests {
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
            .forwardAdmitted(
                preferredUpstreamIndices: [1],
                admission: RouteForwardingAdmission(
                    upstreamProofs: [
                        UpstreamTopologyProof(
                            slotID: UpstreamSlotID(rawValue: 1),
                            slotGeneration: 0
                        )
                    ]
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

}
