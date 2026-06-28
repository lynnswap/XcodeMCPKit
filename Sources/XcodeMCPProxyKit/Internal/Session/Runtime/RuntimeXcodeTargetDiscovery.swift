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
        guard let runtime = runtimeBox.value else {
            return targets
        }
        let unavailableProcessIDs = runtime.unavailableXcodeProcessIDs()
        return targets.filter {
            unavailableProcessIDs.contains($0.processID) == false
        }
    }
}
