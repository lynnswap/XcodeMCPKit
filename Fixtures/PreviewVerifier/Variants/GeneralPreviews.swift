import SwiftUI
struct ContentView: View { var body: some View { Text(verbatim: "GENERAL FIXTURE APP") } }
import SwiftUI
import UIKit

@MainActor final class FixtureUIView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemGreen
        let label = UILabel(frame: CGRect(x: 12, y: 40, width: 296, height: 40))
        label.text = "UIVIEW ACTUAL PREVIEW"
        label.textColor = .white
        label.font = .boldSystemFont(ofSize: 18)
        label.textAlignment = .center
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError("No coder initializer used by this fixture") }
}
@MainActor final class FixtureUIViewController: UIViewController {
    override func loadView() {
        let root = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 120))
        root.backgroundColor = .systemOrange
        let label = UILabel(frame: CGRect(x: 12, y: 40, width: 296, height: 40))
        label.text = "UIVIEWCONTROLLER PREVIEW"
        label.textColor = .white
        label.font = .boldSystemFont(ofSize: 16)
        label.textAlignment = .center
        root.addSubview(label)
        view = root
    }
}
#Preview("Native UIView") {
    FixtureUIView(frame: CGRect(x: 0, y: 0, width: 320, height: 120))
}
#Preview("Native UIViewController") {
    FixtureUIViewController()
}
@available(iOS 26.0, *)
#Preview("Grouped SwiftUI", arguments: ["GROUP ONE", "GROUP TWO"]) { marker in
    Text(marker).font(.title.bold()).foregroundStyle(.white)
        .frame(width: 320, height: 120)
        .background(marker == "GROUP ONE" ? Color.blue : Color.purple)
}
struct LegacyPreviews: PreviewProvider {
    static var previews: some View {
        Group {
            Text("LEGACY ONE").font(.title.bold()).foregroundStyle(.white)
                .frame(width: 320, height: 120).background(.indigo)
                .previewDisplayName("Legacy First").previewLayout(.sizeThatFits)
            Text("LEGACY TWO").font(.title.bold()).foregroundStyle(.white)
                .frame(width: 320, height: 120).background(.red)
                .previewDisplayName("Legacy Second").previewLayout(.fixed(width: 320, height: 120))
                .preferredColorScheme(.dark)
        }
    }
}

@available(iOS 18.0, *)
struct ContextualPreviewModifier: PreviewModifier {
    let label: String
    struct Context: Sendable {
        let marker: String
        let creation: Int
    }
    static var contextBuildCount = 0
    static func makeSharedContext() async throws -> Context {
        contextBuildCount += 1
        await Task.yield()
        return Context(marker: "SHARED ACTUAL CONTEXT", creation: contextBuildCount)
    }
    func body(content: Content, context: Context) -> some View {
        VStack(spacing: 3) {
            Text("MODIFIER \(label)").font(.caption)
            Text(context.marker).font(.headline)
            content
            Text("CONTEXT CREATION \(context.creation)").font(.caption)
        }
        .foregroundStyle(.white)
        .frame(width: 320)
        .padding(12)
        .background(.teal)
        .environment(\.colorScheme, .dark)
    }
}
@available(iOS 18.0, *)
#Preview("Shared context and state", traits: .modifier(ContextualPreviewModifier(label: "FIRST")), .modifier(ContextualPreviewModifier(label: "SECOND"))) {
    @Previewable @State var state = 7
    Text("PREVIEW STATE \(state)").font(.headline)
}
