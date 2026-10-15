import WidgetKit
import SwiftUI

@main
struct RelevanceWidgetProbeBundle: WidgetBundle {
    var body: some Widget {
        if #available(watchOS 26.0, *) { RelevanceProbeWidget() }
    }
}
