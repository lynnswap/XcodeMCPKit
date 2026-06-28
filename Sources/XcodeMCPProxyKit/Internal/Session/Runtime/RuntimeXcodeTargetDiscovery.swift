import Foundation

final class RuntimeDocumentationTargetDiscovery:
    XcodeTargetDiscovering,
    Sendable
{
    private let base: any XcodeTargetDiscovering
    private let runtimeBox: WeakRuntimeCoordinatorBox

    init(
        base: any XcodeTargetDiscovering,
        runtimeBox: WeakRuntimeCoordinatorBox
    ) {
        self.base = base
        self.runtimeBox = runtimeBox
    }

    func runningXcodeTargets() -> [XcodeProcessTarget] {
        let targets = base.runningXcodeTargets()
        guard let runtime = runtimeBox.value,
              let candidateProcessIDs = runtime.documentationCandidateProcessOrder()
        else {
            return targets
        }
        let unavailableProcessIDs = runtime.unavailableXcodeProcessIDs()
        let targetsByProcessID = Dictionary(
            uniqueKeysWithValues: targets.map { ($0.processID, $0) }
        )
        let orderedRuntimeTargets = candidateProcessIDs.compactMap { targetsByProcessID[$0] }
        let orderedRuntimeProcessIDs = Set(candidateProcessIDs)
        let remainingLiveTargets = targets.filter {
            orderedRuntimeProcessIDs.contains($0.processID) == false
                && unavailableProcessIDs.contains($0.processID) == false
        }
        return orderedRuntimeTargets + remainingLiveTargets
    }
}
