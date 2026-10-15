import SwiftUI

public struct StandaloneFrameworkPreview: View {
    public init() {}
    public var body: some View {
        VStack(spacing: 12) {
            Text("STANDALONE FRAMEWORK")
            Image(systemName: "circle.fill").foregroundStyle(.blue)
        }
        .padding(20)
        .background(.cyan.opacity(0.2))
    }
}

#Preview("STANDALONE FRAMEWORK", traits: .fixedLayout(width: 360, height: 180)) {
    StandaloneFrameworkPreview()
}
