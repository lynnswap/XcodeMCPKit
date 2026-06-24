import Foundation
import ProxyCore

package final class RuntimeDocumentationTargetDiscovery:
    PriorityOrderedXcodeTargetDiscovering,
    Sendable
{
    private let base: any XcodeTargetDiscovering
    private let runtimeBox: WeakRuntimeCoordinatorBox

    package init(
        base: any XcodeTargetDiscovering,
        runtimeBox: WeakRuntimeCoordinatorBox
    ) {
        self.base = base
        self.runtimeBox = runtimeBox
    }

    package func runningXcodeTargets() -> [XcodeProcessTarget] {
        let targets = base.runningXcodeTargets()
        guard let runtime = runtimeBox.value,
              let routeProcessIDs = runtime.xcodeProcessRouteProcessIDs(),
              let candidateProcessIDs = runtime.documentationCandidateProcessOrder()
        else {
            return targets
        }
        let targetsByProcessID = Dictionary(
            uniqueKeysWithValues: targets.map { ($0.processID, $0) }
        )
        let orderedRuntimeTargets = candidateProcessIDs.compactMap { targetsByProcessID[$0] }
        let remainingLiveTargets = targets.filter {
            routeProcessIDs.contains($0.processID) == false
        }
        return orderedRuntimeTargets + remainingLiveTargets
    }
}
