import SwiftUI

#if os(watchOS)
import ClockKit

public struct ClockKitCornerRedPreviews: PreviewProvider {
    public static var previews: some View {
        CLKComplicationTemplateGraphicCornerTextView(textProvider: CLKSimpleTextProvider(text: "CORNER"),
            label: Image(systemName: "heart.fill"))
        .previewContext(faceColor: .red)
        .previewDisplayName("CLOCKKIT CORNER RED")
    }
}

public struct ClockKitMissingProviderPreviews: PreviewProvider {
    public static var previews: some View {
        CLKComplicationTemplateGraphicCircularStackText()
            .previewContext(faceColor: .multicolor)
            .previewDisplayName("CLOCKKIT MISSING PROVIDERS")
    }
}
#endif
