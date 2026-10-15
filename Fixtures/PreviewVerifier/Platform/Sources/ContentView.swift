import SwiftUI
#if os(macOS)
import AppKit
#elseif !os(watchOS)
import UIKit
#endif

struct PlatformPreview: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("PLATFORM REGISTRY BODY").font(.title2)
            Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "UNKNOWN BUNDLE")
            Image(systemName: "heart.fill").foregroundStyle(.red)
            Text("BODY END")
        }.padding(16).background(Color.cyan.opacity(0.25))
    }
}

@main struct PlatformPreviewFixture: App {
    var body: some Scene { WindowGroup { PlatformPreview() } }
}

#Preview("SWIFTUI FIXED", traits: .fixedLayout(width: 400, height: 200)) { PlatformPreview() }
#Preview("SWIFTUI DEFAULT") { PlatformPreview() }
#Preview("SWIFTUI FIT", traits: .sizeThatFitsLayout) { PlatformPreview() }

#if os(macOS)
#Preview("APPKIT VIEW", traits: .fixedLayout(width: 440, height: 180)) {
    let view = NSTextField(labelWithString: "ACTUAL APPKIT VIEW")
    view.font = .systemFont(ofSize: 24)
    return view
}
#Preview("APPKIT CONTROLLER", traits: .fixedLayout(width: 440, height: 180)) {
    let controller = NSViewController()
    let view = NSTextField(labelWithString: "ACTUAL APPKIT CONTROLLER")
    view.font = .systemFont(ofSize: 24)
    controller.view = view
    return controller
}
#elseif !os(watchOS)
#Preview("UIKIT VIEW", traits: .fixedLayout(width: 440, height: 180)) {
    let label = UILabel()
    label.text = "ACTUAL UIKIT VIEW"
    label.font = .systemFont(ofSize: 24)
    label.textColor = .systemBlue
    return label
}
#endif
