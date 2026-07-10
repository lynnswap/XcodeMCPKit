import Foundation
import XcodeMCPKit

enum ToolRoutingDecision: Sendable {
    case forward(preferredUpstreamIndex: Int?)
    case forwardAny(preferredUpstreamIndices: [Int])
    case forwardAdmitted(
        preferredUpstreamIndices: [Int],
        admission: RouteForwardingAdmission
    )
    case localXcodeListWindows
    case reject(errors: [ToolRoutingError], forceBatchArray: Bool)

    var preferredUpstreamIndices: [Int]? {
        switch self {
        case .forward(let index):
            return index.map { [$0] }
        case .forwardAny(let indices), .forwardAdmitted(let indices, _):
            return indices
        case .localXcodeListWindows, .reject:
            return nil
        }
    }
}

struct RouteForwardingAdmission: Sendable {
    let route: ProcessControlPlaneAuthority.RouteAdmissionLease
    let upstreamProofs: [UpstreamTopologyProof]
    let window: WindowRouteAdmission?

    init(
        route: ProcessControlPlaneAuthority.RouteAdmissionLease,
        upstreamProofs: [UpstreamTopologyProof],
        window: WindowRouteAdmission? = nil
    ) {
        self.route = route
        self.upstreamProofs = upstreamProofs
        self.window = window
    }

    func proof(for upstreamIndex: Int) -> UpstreamTopologyProof? {
        upstreamProofs.first { $0.slotID.rawValue == upstreamIndex }
    }
}

struct WindowRouteAdmission: Sendable {
    let proof: WindowRouteProof
    let route: ProcessControlPlaneAuthority.RouteAdmissionLease
    let rewritePlan: OwnerBoundRequestRewritePlan
}

struct OwnerBoundRequestRewritePlan: Sendable {
    let processID: pid_t
    let rawTabIdentifierByProxyIdentifier: [String: String]
    let singleRawTabIdentifierByWorkspacePath: [String: String]
    let toolsRequiringTabIdentifier: Set<String>
}

struct ToolRoutingError: Sendable {
    let id: JSONRPC.ID
    let message: String

    init(id: JSONRPC.ID, message: String) {
        self.id = id
        self.message = message
    }
}
