import SwiftUI

#if os(macOS) || os(iOS) || os(tvOS)
private struct DefaultsAuditContext: PreviewContext {
    subscript<Key: PreviewContextKey>(key: Key.Type) -> Key.Value { Key.defaultValue }
}

private struct ContextAuditView: View {
    var body: some View {
        Text("DEFAULT CONTEXT")
            .frame(width: 180, height: 100)
            .background(Color.orange)
    }
}

struct ContextAuditBaseline: PreviewProvider {
    static var previews: some View {
        ContextAuditView()
            .previewLayout(.fixed(width: 180, height: 100))
            .previewDisplayName("CONTEXT BASELINE")
    }
}

struct ContextAuditProvider: PreviewProvider {
    static var previews: some View {
        ContextAuditView()
            .previewLayout(.fixed(width: 180, height: 100))
            .previewContext(DefaultsAuditContext())
            .previewDisplayName("CONTEXT DEFAULTS")
    }
}
#endif
