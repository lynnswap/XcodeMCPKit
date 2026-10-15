import Foundation
import SwiftUI

private final class FrameworkResourceToken: NSObject {}

struct FrameworkResourcePreview: View {
    private let bundle = Bundle(for: FrameworkResourceToken.self)

    private var resourceText: String {
        guard let url = bundle.url(forResource: "FrameworkMarker", withExtension: "txt") else {
            return "MISSING FRAMEWORK RESOURCE"
        }
        do {
            return try String(contentsOf: url, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return "FRAMEWORK RESOURCE READ FAILED: \(error.localizedDescription)"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("FRAMEWORK RESOURCE").font(.headline)
            Text(bundle.bundleIdentifier ?? "MISSING BUNDLE IDENTIFIER")
            Text(resourceText)
        }
        .font(.system(size: 14, design: .monospaced))
        .padding(20)
        .background(.cyan.opacity(0.2))
    }
}

#Preview("FRAMEWORK RESOURCE", traits: .fixedLayout(width: 620, height: 180)) {
    FrameworkResourcePreview()
}
