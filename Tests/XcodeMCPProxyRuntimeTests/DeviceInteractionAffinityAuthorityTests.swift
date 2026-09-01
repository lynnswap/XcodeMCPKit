import Foundation
import Testing
@testable import XcodeMCPProxyRuntime

@Suite struct DeviceInteractionAffinityAuthorityTests {
    @Test func decodesSessionStartTools() {
        #expect(
            DeviceInteractionToolCall.decode(
                toolCall(name: "DeviceInteractionStartSession", arguments: [:])
            ) == .startsSession
        )
        #expect(
            DeviceInteractionToolCall.decode(
                toolCall(name: "DeviceInteractionStartWorkspaceSession", arguments: [:])
            ) == .startsSession
        )
    }

    @Test func decodesBothContinuationKeySpellings() {
        #expect(
            DeviceInteractionToolCall.decode(
                toolCall(
                    name: "DeviceInteractionSynthesize",
                    arguments: ["interactSessionKey": "device-key"]
                )
            ) == .continuesSession(key: "device-key", endsSession: false)
        )
        #expect(
            DeviceInteractionToolCall.decode(
                toolCall(
                    name: "DeviceInteractionInstallAndRun",
                    arguments: ["interactionSessionKey": "device-key"]
                )
            ) == .continuesSession(key: "device-key", endsSession: false)
        )
        #expect(
            DeviceInteractionToolCall.decode(
                toolCall(
                    name: "DeviceInteractionEndSession",
                    arguments: ["interactionSessionKey": "device-key"]
                )
            ) == .continuesSession(key: "device-key", endsSession: true)
        )
    }

    @Test func ignoresUnknownOrInvalidToolCalls() {
        #expect(
            DeviceInteractionToolCall.decode(
                toolCall(name: "BuildProject", arguments: [:])
            ) == nil
        )
        #expect(
            DeviceInteractionToolCall.decode(
                toolCall(
                    name: "DeviceInteractionSynthesize",
                    arguments: ["interactSessionKey": ""]
                )
            ) == nil
        )
    }

    @Test func decodesSessionKeyOnlyFromSuccessfulStructuredContent() throws {
        let response = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": 1,
            "result": [
                "content": [["type": "text", "text": "display-only"]],
                "structuredContent": ["interactionSessionKey": "device-key"],
                "isError": false,
            ],
        ])
        #expect(DeviceInteractionToolCall.successfulSessionKey(from: response) == "device-key")

        let toolError = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": 1,
            "result": [
                "structuredContent": ["interactionSessionKey": "device-key"],
                "isError": true,
            ],
        ])
        #expect(DeviceInteractionToolCall.successfulSessionKey(from: toolError) == nil)

        let textOnly = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": 1,
            "result": [
                "content": [["type": "text", "text": "interactionSessionKey=device-key"]],
                "isError": false,
            ],
        ])
        #expect(DeviceInteractionToolCall.successfulSessionKey(from: textOnly) == nil)
    }

    @Test func ownsAffinityMembershipAndInvalidation() throws {
        let authority = DeviceInteractionAffinityAuthority()
        let route0 = ProcessRouteID(processID: 10, instanceGeneration: 1)
        let proof0 = UpstreamTopologyProof(
            slotID: UpstreamSlotID(rawValue: 0),
            slotGeneration: 1
        )
        let proof1 = UpstreamTopologyProof(
            slotID: UpstreamSlotID(rawValue: 1),
            slotGeneration: 1
        )
        let affinity0 = DeviceInteractionAffinityAuthority.Affinity(
            upstreamProof: proof0,
            routeID: route0
        )
        let affinity1 = DeviceInteractionAffinityAuthority.Affinity(
            upstreamProof: proof1
        )

        authority.record(affinity0, for: "key-0")
        authority.record(affinity1, for: "key-1")
        #expect(authority.count() == 2)
        #expect(authority.affinity(for: "key-0") == affinity0)

        authority.remove(routeIDs: [route0])
        #expect(authority.affinity(for: "key-0") == nil)
        #expect(authority.affinity(for: "key-1") == affinity1)

        authority.remove(upstreamProofs: [proof1])
        #expect(authority.count() == 0)

        authority.record(affinity0, for: "key-0")
        authority.remove(key: "key-0")
        #expect(authority.count() == 0)

        authority.record(affinity0, for: "key-0")
        authority.clear()
        #expect(authority.count() == 0)
    }

    private func toolCall(name: String, arguments: [String: Any]) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": [
                "name": name,
                "arguments": arguments,
            ],
        ]
    }
}
