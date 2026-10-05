import NIOConcurrencyHelpers
import XcodeMCPCore

struct CatalogLease: Sendable, Hashable {
    fileprivate let epoch: UInt64
    fileprivate let attempt: UInt64
    fileprivate let load: UInt64
    let topologyProof: UpstreamTopologyProof
}

struct CatalogTransition: Sendable {
    let cancelledRPCs: [ControlPlane.RPCHandle]
    let publishesToolsListChanged: Bool

    static let none = Self(cancelledRPCs: [], publishesToolsListChanged: false)
}

/// Keeps the native catalog tied to the connection and refresh that supplied it.
/// RPC cancellation is returned to the caller so it runs outside the state lock.
final class ToolsCatalogAuthority: Sendable {
    struct Snapshot: Sendable {
        let provider: ToolCatalogProvider?
        var canonicalToolsCatalogRaw: JSONValue? { provider?.rawResult }
        var canonicalSourceProof: UpstreamTopologyProof? { provider?.sourceProof }
    }

    enum Commit: Sendable {
        case accepted(Snapshot, CatalogTransition)
        case discarded(CatalogTransition)
    }

    private struct Load: Sendable {
        var rpc: ControlPlane.RPCHandle?
    }

    private struct Attempt: Sendable {
        let id: UInt64
        let proof: UpstreamTopologyProof
        var loads: [UInt64: Load] = [:]
        var isSatisfied = false
    }

    private struct State: Sendable {
        var epoch: UInt64 = 0
        var nextAttempt: UInt64 = 0
        var nextLoad: UInt64 = 0
        var attempt: Attempt?
        var provider: ToolCatalogProvider?
    }

    private let state = NIOLockedValueBox(State())

    func beginLoad(sourceProof: UpstreamTopologyProof) -> (CatalogLease, CatalogTransition) {
        state.withLockedValue { state in
            var cancelled: [ControlPlane.RPCHandle] = []
            if state.attempt?.proof != sourceProof || state.attempt?.isSatisfied != false {
                cancelled = Self.handles(in: state)
                state.nextAttempt &+= 1
                state.attempt = Attempt(id: state.nextAttempt, proof: sourceProof)
            }
            state.nextLoad &+= 1
            state.attempt?.loads[state.nextLoad] = Load()
            let lease = CatalogLease(
                epoch: state.epoch, attempt: state.nextAttempt,
                load: state.nextLoad, topologyProof: sourceProof)
            return (lease, CatalogTransition(
                cancelledRPCs: cancelled, publishesToolsListChanged: false))
        }
    }

    func attach(_ rpc: ControlPlane.RPCHandle, to lease: CatalogLease) -> CatalogTransition {
        state.withLockedValue { state in
            guard Self.isCurrent(lease, in: state),
                  state.attempt?.loads[lease.load] != nil else {
                return CatalogTransition(cancelledRPCs: [rpc], publishesToolsListChanged: false)
            }
            state.attempt?.loads[lease.load]?.rpc = rpc
            return .none
        }
    }

    func complete(_ provider: ToolCatalogProvider?, lease: CatalogLease) -> Commit {
        state.withLockedValue { state in
            guard Self.isCurrent(lease, in: state),
                  state.attempt?.loads[lease.load] != nil else {
                return .discarded(.none)
            }
            let previous = state.provider?.rawResult
            let cancelled: [ControlPlane.RPCHandle]
            if let provider {
                cancelled = Self.handles(in: state)
                state.provider = provider
                state.attempt?.loads.removeAll()
                state.attempt?.isSatisfied = true
            } else {
                cancelled = state.attempt?.loads.removeValue(forKey: lease.load)?.rpc.map { [$0] } ?? []
                if state.attempt?.loads.isEmpty == true {
                    state.attempt = nil
                }
            }
            return .accepted(Snapshot(provider: state.provider), CatalogTransition(
                cancelledRPCs: cancelled,
                publishesToolsListChanged: previous != state.provider?.rawResult))
        }
    }

    func satisfiedCatalogProvider(for lease: CatalogLease) -> ToolCatalogProvider? {
        state.withLockedValue { state in
            guard Self.isCurrent(lease, in: state), state.attempt?.isSatisfied == true else {
                return nil
            }
            return state.provider
        }
    }

    func invalidate(sourceProof: UpstreamTopologyProof? = nil) -> CatalogTransition {
        state.withLockedValue { state in
            if let sourceProof,
               state.provider?.sourceProof != sourceProof,
               state.attempt?.proof != sourceProof,
               !Self.handles(in: state).contains(where: { $0.isBound(to: sourceProof) }) {
                return .none
            }
            let cancelled = Self.handles(in: state)
            let changed = state.provider != nil
            state.epoch &+= 1
            state.provider = nil
            state.attempt = nil
            return CatalogTransition(cancelledRPCs: cancelled, publishesToolsListChanged: changed)
        }
    }

    func canonicalToolsCatalogRaw() -> JSONValue? {
        state.withLockedValue { $0.provider?.rawResult }
    }

    func canonicalSourceUpstream() -> Int? {
        state.withLockedValue { $0.provider?.sourceProof.slotID.rawValue }
    }

    func providerCatalog(for proof: UpstreamTopologyProof) -> ToolCatalogProvider? {
        state.withLockedValue { $0.provider?.sourceProof == proof ? $0.provider : nil }
    }

    func providerCatalog(forUpstreamIndex index: Int) -> ToolCatalogProvider? {
        state.withLockedValue { $0.provider?.sourceProof.slotID.rawValue == index ? $0.provider : nil }
    }

    private static func isCurrent(_ lease: CatalogLease, in state: State) -> Bool {
        lease.epoch == state.epoch && state.attempt?.id == lease.attempt
            && state.attempt?.proof == lease.topologyProof
    }

    private static func handles(in state: State) -> [ControlPlane.RPCHandle] {
        state.attempt?.loads.values.compactMap(\.rpc) ?? []
    }
}

enum ToolCatalogCodec {
    static func toolsByName(in result: JSONValue?) -> [String: JSONValue] {
        guard case .object(let object)? = result,
              case .array(let tools)? = object["tools"] else { return [:] }
        var toolsByName: [String: JSONValue] = [:]
        for tool in tools {
            guard case .object(let object) = tool,
                  case .string(let name)? = object["name"] else { continue }
            toolsByName[name] = tool
        }
        return toolsByName
    }
}
