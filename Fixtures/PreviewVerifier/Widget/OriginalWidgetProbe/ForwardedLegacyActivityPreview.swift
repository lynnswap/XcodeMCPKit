import SwiftUI

private struct ForwardingPreviewContext: PreviewContext {
    let base: any PreviewContext
    subscript<Key: PreviewContextKey>(key: Key.Type) -> Key.Value { base[key] }
}

struct ForwardedLegacyActivityProvider: PreviewProvider {
    static var previews: some View {
        if let context = LegacyActivityNormalProvider._allPreviews.first?.context {
            Color.clear.previewContext(ForwardingPreviewContext(base: context))
                .previewDisplayName("FORWARDED LEGACY ACTIVITY")
        }
    }
}
