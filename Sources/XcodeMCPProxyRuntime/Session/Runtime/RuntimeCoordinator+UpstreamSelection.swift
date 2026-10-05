import XcodeMCPCore

extension RuntimeCoordinator {
    func secondaryUpstreamIndices(excluding upstreamIndex: Int) -> [Int] {
        let candidates = upstreamSlotIDs.map(\.rawValue).sorted()
        return candidates.filter { $0 != upstreamIndex }
    }

    func activeInitializedHealthyishCount() -> Int {
        return upstreamSlotIDs.map(\.rawValue).reduce(into: 0) { count, upstreamIndex in
            guard let upstream = upstreamHealthManager.state(
                for: UpstreamSlotID(rawValue: upstreamIndex)
            ) else { return }
            guard upstream.initPhase.isInitialized else { return }
            switch upstream.healthState {
            case .healthy, .degraded:
                count += 1
            case .quarantined:
                break
            }
        }
    }

    func anyActiveInitializedUpstream() -> Bool {
        return upstreamSlotIDs.map(\.rawValue).contains { upstreamIndex in
            upstreamHealthManager.state(
                for: UpstreamSlotID(rawValue: upstreamIndex)
            )?.initPhase.isInitialized == true
        }
    }

    func anyActiveRecoveryInFlight() -> Bool {
        return upstreamSlotIDs.map(\.rawValue).contains { upstreamIndex in
            guard let upstream = upstreamHealthManager.state(
                for: UpstreamSlotID(rawValue: upstreamIndex)
            ) else { return false }
            return upstream.initInFlight || upstream.healthProbeInFlight
        }
    }

}
