import SwiftUI

struct IOS27_1WidgetPreview: PreviewProvider {
    static var previews: some View {
        SmallWidgetContextProvider.previews
            .previewDevice(PreviewDevice(rawValue: "iPhone Duo"))
            .previewDisplayName("WIDGET RUNTIME CONTRACT")
    }
}
