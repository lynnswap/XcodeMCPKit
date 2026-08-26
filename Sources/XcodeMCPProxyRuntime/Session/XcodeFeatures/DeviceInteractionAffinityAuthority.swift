import Foundation
import NIOConcurrencyHelpers
import XcodeMCPKit

enum DeviceInteractionToolCall: Equatable, Sendable {
    case startsSession
    case continuesSession(key: String, endsSession: Bool)

    static func decode(_ requestJSON: Any) -> Self? {
        guard let object = requestJSON as? [String: Any],
              JSONRPC.Message.Inspector.method(from: object) == "tools/call",
              let params = object["params"] as? [String: Any],
              let toolName = params["name"] as? String else {
            return nil
        }

        switch toolName {
        case "DeviceInteractionStartSession", "DeviceInteractionStartWorkspaceSession":
            return .startsSession
        case "DeviceInteractionSynthesize":
            return continuation(
                arguments: params["arguments"],
                keyName: "interactSessionKey",
                endsSession: false
            )
        case "DeviceInteractionInstallAndRun":
            return continuation(
                arguments: params["arguments"],
                keyName: "interactionSessionKey",
                endsSession: false
            )
        case "DeviceInteractionEndSession":
            return continuation(
                arguments: params["arguments"],
                keyName: "interactionSessionKey",
                endsSession: true
            )
        default:
            return nil
        }
    }

    static func decode(requestData: Data) -> Self? {
        guard let object = try? JSONRPC.Wire.object(fromData: requestData) else {
            return nil
        }
        return decode(object)
    }

    static func successfulSessionKey(from responseData: Data) -> String? {
        guard let result = successfulResult(from: responseData),
              let structuredContent = result["structuredContent"] as? [String: Any],
              let key = structuredContent["interactionSessionKey"] as? String,
              key.isEmpty == false else {
            return nil
        }
        return key
    }

    static func isSuccessfulResponse(_ responseData: Data) -> Bool {
        successfulResult(from: responseData) != nil
    }

    private static func continuation(
        arguments: Any?,
        keyName: String,
        endsSession: Bool
    ) -> Self? {
        guard let arguments = arguments as? [String: Any],
              let key = arguments[keyName] as? String,
              key.isEmpty == false else {
            return nil
        }
        return .continuesSession(key: key, endsSession: endsSession)
    }

    private static func successfulResult(from responseData: Data) -> [String: Any]? {
        guard let object = try? JSONRPC.Wire.object(fromData: responseData),
              object["error"] == nil,
              let result = object["result"] as? [String: Any],
              result["isError"] as? Bool != true else {
            return nil
        }
        return result
    }
}

final class DeviceInteractionAffinityAuthority: Sendable {
    struct Affinity: Equatable, Sendable {
        let upstreamProof: UpstreamTopologyProof
        let routeID: ProcessRouteID?

        init(
            upstreamProof: UpstreamTopologyProof,
            routeID: ProcessRouteID? = nil
        ) {
            self.upstreamProof = upstreamProof
            self.routeID = routeID
        }
    }

    private let affinities = NIOLockedValueBox<[String: Affinity]>([:])

    func affinity(for key: String) -> Affinity? {
        affinities.withLockedValue { $0[key] }
    }

    func record(_ affinity: Affinity, for key: String) {
        guard key.isEmpty == false else { return }
        affinities.withLockedValue { $0[key] = affinity }
    }

    func remove(key: String) {
        _ = affinities.withLockedValue { $0.removeValue(forKey: key) }
    }

    func remove(routeIDs: Set<ProcessRouteID>) {
        guard routeIDs.isEmpty == false else { return }
        affinities.withLockedValue { affinities in
            affinities = affinities.filter { _, affinity in
                guard let routeID = affinity.routeID else { return true }
                return routeIDs.contains(routeID) == false
            }
        }
    }

    func remove(upstreamProofs: Set<UpstreamTopologyProof>) {
        guard upstreamProofs.isEmpty == false else { return }
        affinities.withLockedValue { affinities in
            affinities = affinities.filter { _, affinity in
                upstreamProofs.contains(affinity.upstreamProof) == false
            }
        }
    }

    func clear() {
        affinities.withLockedValue { $0.removeAll() }
    }

    func count() -> Int {
        affinities.withLockedValue(\.count)
    }
}
