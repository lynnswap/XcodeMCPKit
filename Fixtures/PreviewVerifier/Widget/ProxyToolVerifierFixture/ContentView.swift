import SwiftUI
import UIKit

struct ContentView: View {
    var body: some View { Text("MAIN APP") }
}

private struct DisplayParityView: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dynamicTypeSize) private var size
    @Environment(\.accessibilityShowBorders) private var borders
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 8) {
                Text("DISPLAY PARITY")
                Text("SCHEME \(String(describing: scheme)) CONTRAST \(String(describing: contrast))")
                Text("TYPE \(String(describing: size)) BORDERS \(borders)")
                Text("SIZE \(Int(geometry.size.width))x\(Int(geometry.size.height))")
                Text("SAFE \(Int(geometry.safeAreaInsets.top)),\(Int(geometry.safeAreaInsets.leading)),\(Int(geometry.safeAreaInsets.bottom)),\(Int(geometry.safeAreaInsets.trailing))")
                NativeTraitLabel().frame(height: 44)
                Button("CONTROL BORDER BUTTON") {}
                Text("BODY END")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct NativeTraitLabel: UIViewRepresentable {
    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.numberOfLines = 0
        label.textAlignment = .center
        label.adjustsFontForContentSizeCategory = true
        label.registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self,
            UITraitPreferredContentSizeCategory.self]) { (label: UILabel, _: UITraitCollection) in
            refresh(label)
        }
        refresh(label)
        return label
    }
    func updateUIView(_ label: UILabel, context: Context) { refresh(label) }
    private func refresh(_ label: UILabel) {
        let traits = label.traitCollection
        label.text = "UIKIT \(traits.userInterfaceStyle.rawValue)/\(traits.accessibilityContrast.rawValue)/\(traits.preferredContentSizeCategory.rawValue)"
        label.textColor = .label
        label.font = .preferredFont(forTextStyle: .body, compatibleWith: traits)
    }
}

private struct CompactDisplay: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(spacing: 8) {
            Text("FIXED/FIT DISPLAY")
            Text("SCHEME \(String(describing: scheme))")
            Text("SECOND LINE")
        }
        .padding(12)
    }
}

#Preview("DISPLAY DEVICE") { DisplayParityView() }
#Preview("DISPLAY SOURCE LANDSCAPE", traits: .landscapeLeft) { DisplayParityView() }
#Preview("DISPLAY FIXED", traits: .fixedLayout(width: 320, height: 180)) { CompactDisplay() }
#Preview("DISPLAY FIT", traits: .sizeThatFitsLayout) { CompactDisplay() }
#Preview("DISPLAY SOURCE UPSIDE DOWN", traits: .portraitUpsideDown) { DisplayParityView() }

#Preview("UIKIT CONTROL BORDERS", traits: .fixedLayout(width: 320, height: 120)) {
    let button = UIButton(type: .system)
    button.setTitle("SYSTEM BUTTON", for: .normal)
    button.titleLabel?.font = .systemFont(ofSize: 24)
    return button
}

#Preview("DISPLAY TIMELINE") {
    TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { _ in
        DisplayParityView()
    }
}
