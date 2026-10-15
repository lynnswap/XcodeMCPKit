import SwiftUI
import WidgetKit

private struct ProviderContextBody: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 8) {
                Text("PROVIDER CONTEXT")
                Text(String(describing: family))
                Text("SIZE \(Int(geometry.size.width))x\(Int(geometry.size.height))")
                Text(String(describing: scheme))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .containerBackground(.blue.opacity(0.3), for: .widget)
    }
}

struct SmallWidgetContextProvider: PreviewProvider {
    static var previews: some View {
        ProviderContextBody().previewContext(WidgetPreviewContext(family: .systemSmall))
    }
}

struct MediumWidgetContextProvider: PreviewProvider {
    static var previews: some View {
        ProviderContextBody().previewContext(WidgetPreviewContext(family: .systemMedium))
    }
}

struct DeviceContextProvider: PreviewProvider {
    static var previews: some View {
        Text("PROVIDER DEVICE").padding().previewDevice("iPhone 17")
    }
}
