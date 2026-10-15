import Foundation
import SwiftUI
import WidgetKit

#Preview("SWIFTUI IN WIDGET EXTENSION", traits: .fixedLayout(width: 480, height: 120)) {
    VStack(spacing: 8) {
        Text("ORDINARY SWIFTUI VIEW").font(.headline)
        Text(Bundle.main.bundleIdentifier ?? "NO BUNDLE ID").font(.caption)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.cyan)
}

struct NoMarginsProbeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NoMarginsProbeWidget", provider: CanonicalStaticProvider()) {
            LegacyIntentEntryView(entry: $0)
        }
        .configurationDisplayName("No Margins Probe")
        .supportedFamilies([.systemSmall])
        .contentMarginsDisabled()
    }
}

#Preview("WIDGET WITHOUT CONTENT MARGINS", as: .systemSmall) {
    NoMarginsProbeWidget()
} timeline: {
    LegacyIntentEntry(date: Date(timeIntervalSince1970: 1_000), title: "NO MARGINS FIRST",
                      configuration: "NONE", contextFamily: "explicit", isPreview: true)
    LegacyIntentEntry(date: Date(timeIntervalSince1970: 2_000), title: "NO MARGINS SECOND",
                      configuration: "NONE", contextFamily: "explicit", isPreview: true)
}

struct AccessoryHostProbeView: View {
    let entry: LegacyIntentEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.title).font(.headline)
            Text(String(describing: family)).font(.caption)
        }
        .containerBackground(.purple.gradient, for: .widget)
    }
}

struct AccessoryHostProbeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "AccessoryHostProbeWidget", provider: CanonicalStaticProvider()) {
            AccessoryHostProbeView(entry: $0)
        }
        .configurationDisplayName("Accessory Host Probe")
        .supportedFamilies([.accessoryRectangular])
    }
}

#Preview("ACCESSORY RECTANGULAR HOST", as: .accessoryRectangular) {
    AccessoryHostProbeWidget()
} timeline: {
    LegacyIntentEntry(date: Date(timeIntervalSince1970: 1_000), title: "ACCESSORY FIRST",
                      configuration: "NONE", contextFamily: "explicit", isPreview: true)
    LegacyIntentEntry(date: Date(timeIntervalSince1970: 2_000), title: "ACCESSORY SECOND",
                      configuration: "NONE", contextFamily: "explicit", isPreview: true)
}

struct FixedBackgroundProbeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "FixedBackgroundProbeWidget", provider: CanonicalStaticProvider()) {
            LegacyIntentEntryView(entry: $0)
        }
        .configurationDisplayName("Fixed Background Probe")
        .supportedFamilies([.systemSmall])
        .containerBackgroundRemovable(false)
    }
}

#Preview("WIDGET NONREMOVABLE BACKGROUND", as: .systemSmall) {
    FixedBackgroundProbeWidget()
} timeline: {
    LegacyIntentEntry(date: Date(timeIntervalSince1970: 1_000), title: "FIXED BACKGROUND",
                      configuration: "NONE", contextFamily: "explicit", isPreview: true)
}
