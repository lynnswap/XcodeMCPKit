import Foundation
import XcodeMCPCore

enum ToolRoutingDecision: Sendable {
    case forward(preferredUpstreamIndex: Int?)
    case forwardAny(preferredUpstreamIndices: [Int])
    case forwardAdmitted(
        preferredUpstreamIndices: [Int],
        admission: RouteForwardingAdmission
    )
    case localXcodeListWindows
    case reject(errors: [ToolRoutingError])

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
    let route: ProcessControlPlaneAuthority.RouteAdmissionLease?
    let upstreamProofs: [UpstreamTopologyProof]
    let window: WindowRouteAdmission?
    let workspaceIdentifier: String?
    let toolDefinition: ToolDefinitionSnapshot?

    init(upstreamProofs: [UpstreamTopologyProof], workspaceIdentifier: String? = nil,
         toolDefinition: ToolDefinitionSnapshot? = nil) {
        self.route = nil
        self.upstreamProofs = upstreamProofs
        self.window = nil
        self.workspaceIdentifier = workspaceIdentifier
        self.toolDefinition = toolDefinition
    }

    init(
        route: ProcessControlPlaneAuthority.RouteAdmissionLease,
        upstreamProofs: [UpstreamTopologyProof],
        window: WindowRouteAdmission? = nil,
        toolDefinition: ToolDefinitionSnapshot? = nil
    ) {
        self.route = route
        self.upstreamProofs = upstreamProofs
        self.window = window
        self.workspaceIdentifier = nil
        self.toolDefinition = toolDefinition
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
    let tabIdentifier: String?
    let clientTabIdentifier: String?
}

struct ToolRoutingError: Sendable {
    let id: JSONRPC.ID
    let message: String

    init(id: JSONRPC.ID, message: String) {
        self.id = id
        self.message = message
    }
}
