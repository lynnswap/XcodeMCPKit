#if os(iOS) && targetEnvironment(simulator)
import SwiftUI
import UIKit

private let dynamicTypeSizes: [String: DynamicTypeSize] = [
    "X Small": .xSmall, "Small": .small, "Medium": .medium, "Large": .large,
    "X Large": .xLarge, "XX Large": .xxLarge, "XXX Large": .xxxLarge,
    "AX 1": .accessibility1, "AX 2": .accessibility2, "AX 3": .accessibility3,
    "AX 4": .accessibility4, "AX 5": .accessibility5,
]

@MainActor
func applyDisplayVariants(to environment: inout EnvironmentValues, variants: [String: String]) throws {
    for (key, value) in variants {
        switch (key, value) {
        case ("Color Scheme", "Light Appearance"): environment.colorScheme = .light
        case ("Color Scheme", "Dark Appearance"): environment.colorScheme = .dark
        case ("Contrast", "Standard Contrast"): environment._colorSchemeContrast = .standard
        case ("Contrast", "Increased Contrast"): environment._colorSchemeContrast = .increased
        case ("Control Borders", "Hidden"): environment._accessibilityShowButtonShapes = false
        case ("Control Borders", "Shown"): environment._accessibilityShowButtonShapes = true
        case ("Dynamic Type", _):
            guard let size = dynamicTypeSizes[value] else { throw NativePreviewPipelineRequired() }
            environment.dynamicTypeSize = size
        case ("Orientation", "Portrait"), ("Orientation", "Landscape Left"), ("Orientation", "Landscape Right"): break
        default: throw NativePreviewPipelineRequired()
        }
    }
}

@MainActor
func requestPreviewOrientation(_ target: UIInterfaceOrientation, in scene: UIWindowScene) async throws {
    let mask: UIInterfaceOrientationMask
    switch target {
    case .portrait: mask = .portrait
    case .portraitUpsideDown: mask = .portraitUpsideDown
    case .landscapeLeft: mask = .landscapeLeft
    case .landscapeRight: mask = .landscapeRight
    default: throw NativePreviewPipelineRequired()
    }
    var failure: (any Error)?
    scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { failure = $0 }
    while scene.effectiveGeometry.interfaceOrientation != target {
        if let failure { throw failure }
        try await Task.sleep(for: .milliseconds(16))
    }
    if let failure { throw failure }
}

@MainActor
final class PreviewOrientationController: UIViewController {
    private let content: UIViewController

    init(content: UIViewController) {
        self.content = content
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .all }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(content)
        content.view.frame = view.bounds
        content.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(content.view)
        content.didMove(toParent: self)
    }
}
#endif
