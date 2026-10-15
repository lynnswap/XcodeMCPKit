import SwiftUI

#if os(watchOS)
import ClockKit

public struct ClockKitFixedLayoutPreviews: PreviewProvider {
    public static var previews: some View {
        CLKComplicationTemplateGraphicCircularView(
            VStack(spacing: 2) {
                Image(systemName: "heart.fill")
                    .foregroundStyle(.orange)
                Text("CLK")
                    .font(.caption2)
            }
        )
        .previewContext(faceColor: .multicolor)
        .previewLayout(.fixed(width: 120, height: 80))
        .previewDisplayName("CLOCKKIT FIXED")
    }
}

public struct ClockKitFittingLayoutPreviews: PreviewProvider {
    public static var previews: some View {
        CLKComplicationTemplateGraphicCircularView(
            VStack(spacing: 2) {
                Image(systemName: "heart.fill")
                    .foregroundStyle(.orange)
                Text("CLK")
                    .font(.caption2)
            }
        )
        .previewContext(faceColor: .multicolor)
        .previewLayout(.sizeThatFits)
        .previewDisplayName("CLOCKKIT FITTING")
    }
}
#endif
