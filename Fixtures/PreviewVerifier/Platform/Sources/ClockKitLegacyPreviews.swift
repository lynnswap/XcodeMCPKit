import SwiftUI

#if os(watchOS)
import ClockKit

public struct ClockKitLegacyPreviews: PreviewProvider {
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
        .previewDisplayName("CLOCKKIT LEGACY")
    }
}
#endif
