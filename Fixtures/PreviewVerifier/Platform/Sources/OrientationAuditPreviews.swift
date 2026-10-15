import SwiftUI

#if targetEnvironment(macCatalyst)
private struct OrientationAuditView: View {
    var body: some View {
        HStack(spacing: 0) {
            Text("LEFT").frame(width: 60, height: 100).background(Color.orange)
            Text("RIGHT").frame(width: 120, height: 100).background(Color.cyan)
        }
    }
}

#Preview("ORIENTATION BASELINE", traits: .fixedLayout(width: 180, height: 100)) {
    OrientationAuditView()
}

#Preview("ORIENTATION REGISTRY", traits: .landscapeLeft, .fixedLayout(width: 180, height: 100)) {
    OrientationAuditView()
}

struct OrientationAuditProvider: PreviewProvider {
    static var previews: some View {
        OrientationAuditView()
            .previewLayout(.fixed(width: 180, height: 100))
            .previewInterfaceOrientation(.landscapeLeft)
            .previewDisplayName("ORIENTATION PROVIDER")
    }
}
#endif
