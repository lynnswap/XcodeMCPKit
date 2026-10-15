import UIKit
import SwiftUI
import WidgetKit
import ActivityKit
import DeveloperToolsSupport

enum ActivityBuilderTrace {
    static func record(_ event: String) { print(event) }
}

public struct ActivityProbeAttributes: ActivityAttributes, Sendable {
    public struct ContentState: Codable, Hashable, Sendable {
        public var marker: String
        public var progress: Double
    }
    public var name: String
}

struct OriginalWidgetProbe: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ActivityProbeAttributes.self) { context in
            let _ = ActivityBuilderTrace.record("content: \(context.attributes.name) / \(context.state.marker) / stale=\(context.isStale)")
            VStack(spacing: 8) {
                Text("CONTENT \(context.state.marker)").font(.headline)
                Text(context.attributes.name)
                Text(context.isStale ? "STALE" : "FRESH")
                ProgressView(value: context.state.progress)
                Text("ACTIVITY END").font(.caption)
            }
            .padding(16)
            .foregroundStyle(.white)
            .background(context.state.marker == "FIRST" ? Color.blue.gradient : Color.purple.gradient)
            .activityBackgroundTint(.indigo)
        } dynamicIsland: { context in
            let _ = ActivityBuilderTrace.record("dynamicIsland: \(context.attributes.name) / \(context.state.marker) / stale=\(context.isStale)")
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text("LEADING \(context.state.marker)").foregroundStyle(.yellow)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("TRAILING \(context.state.marker)").foregroundStyle(.cyan)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack {
                        Text("EXPANDED \(context.state.marker)")
                        Text(context.attributes.name)
                        Text("ACTIVITY END")
                    }.foregroundStyle(.white)
                }
            } compactLeading: {
                Text("L \(context.state.marker)").foregroundStyle(.yellow)
            } compactTrailing: {
                Text("R \(context.state.marker)").foregroundStyle(.cyan)
            } minimal: {
                Text("MIN \(context.state.marker)").foregroundStyle(.orange)
            }
        }
        .supplementalActivityFamilies([.small, .medium])
    }
}

#Preview("ACTIVITY CONTENT", as: .content, using: ActivityProbeAttributes(name: "ATTRIBUTES MARKER")) {
    OriginalWidgetProbe()
} contentStates: {
    ActivityProbeAttributes.ContentState(marker: "FIRST", progress: 0.25)
    ActivityProbeAttributes.ContentState(marker: "SECOND", progress: 0.75)
}

#Preview("ACTIVITY COMPACT", as: .dynamicIsland(.compact), using: ActivityProbeAttributes(name: "ATTRIBUTES MARKER")) {
    OriginalWidgetProbe()
} contentStates: {
    ActivityProbeAttributes.ContentState(marker: "FIRST", progress: 0.25)
    ActivityProbeAttributes.ContentState(marker: "SECOND", progress: 0.75)
}

#Preview("ACTIVITY EXPANDED", as: .dynamicIsland(.expanded), using: ActivityProbeAttributes(name: "ATTRIBUTES MARKER")) {
    OriginalWidgetProbe()
} contentStates: {
    ActivityProbeAttributes.ContentState(marker: "FIRST", progress: 0.25)
    ActivityProbeAttributes.ContentState(marker: "SECOND", progress: 0.75)
}

#Preview("ACTIVITY MINIMAL", as: .dynamicIsland(.minimal), using: ActivityProbeAttributes(name: "ATTRIBUTES MARKER")) {
    OriginalWidgetProbe()
} contentStates: {
    ActivityProbeAttributes.ContentState(marker: "FIRST", progress: 0.25)
    ActivityProbeAttributes.ContentState(marker: "SECOND", progress: 0.75)
}


import AppIntents
import Foundation
import Intents
import SwiftUI
import WidgetKit

public struct LegacyIntentEntry: TimelineEntry, Sendable {
    public let date: Date
    public let title: String
    public let configuration: String
    public let contextFamily: String
    public let isPreview: Bool
}

public struct LegacyIntentProvider: IntentTimelineProvider {
    public typealias Intent = INPlayMediaIntent

    public func placeholder(in context: Context) -> LegacyIntentEntry {
        entry("LEGACY PLACEHOLDER", configuration: "NONE", context: context)
    }

    public func getSnapshot(for configuration: INPlayMediaIntent, in context: Context,
                            completion: @escaping @Sendable (LegacyIntentEntry) -> Void) {
        completion(entry("LEGACY SNAPSHOT", configuration: configurationLabel(configuration), context: context))
    }

    public func getTimeline(for configuration: INPlayMediaIntent, in context: Context,
                            completion: @escaping @Sendable (Timeline<LegacyIntentEntry>) -> Void) {
        completion(Timeline(entries: [
            entry("LEGACY PROVIDER FIRST", configuration: configurationLabel(configuration), context: context),
            entry("LEGACY PROVIDER SECOND", configuration: configurationLabel(configuration), context: context,
                  date: Date(timeIntervalSince1970: 2_000))
        ], policy: .never))
    }

    private func configurationLabel(_ configuration: INPlayMediaIntent) -> String {
        configuration.mediaItems?.first?.identifier ?? "DEFAULT"
    }

    private func entry(_ title: String, configuration: String, context: Context,
                       date: Date = Date(timeIntervalSince1970: 1_000)) -> LegacyIntentEntry {
        LegacyIntentEntry(date: date, title: title,
                          configuration: configuration, contextFamily: String(describing: context.family),
                          isPreview: context.isPreview)
    }
}

public struct LegacyIntentEntryView: View {
    public let entry: LegacyIntentEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @Environment(\.redactionReasons) private var redactionReasons

    public var body: some View {
        VStack(spacing: 6) {
            Text(entry.title).font(.headline)
            Text("INTENT " + entry.configuration)
            Text("CONTEXT " + entry.contextFamily + "/" + String(entry.isPreview))
            Text("ENV " + String(describing: family))
            Text("LOW " + String(isLuminanceReduced)).privacySensitive()
            Text("REDACTION " + String(redactionReasons.rawValue))
        }.font(.caption).containerBackground(.orange.gradient, for: .widget)
    }
}

public struct LegacyIntentWidget: Widget {
    public init() {}
    public var body: some WidgetConfiguration {
        IntentConfiguration(kind: "LegacyIntentPreviewProbe", intent: INPlayMediaIntent.self,
                            provider: LegacyIntentProvider()) { LegacyIntentEntryView(entry: $0) }
            .configurationDisplayName("Legacy Intent Probe Widget")
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}

public func configuredLegacyIntent() -> INPlayMediaIntent {
    INPlayMediaIntent(mediaItems: [INMediaItem(identifier: "CONFIGURED", title: "Configured Media",
                                            type: .song, artwork: nil)],
                      mediaContainer: nil, playShuffled: nil, playbackRepeatMode: .none,
                      resumePlayback: nil, playbackQueueLocation: .now,
                      playbackSpeed: nil, mediaSearch: nil)
}

#Preview("LEGACY INTENT ENTRIES", as: .systemSmall) { LegacyIntentWidget() } timeline: {
    LegacyIntentEntry(date: Date(timeIntervalSince1970: 1_000), title: "LEGACY ENTRY FIRST",
                      configuration: "EXPLICIT-A", contextFamily: "explicit", isPreview: true)
    LegacyIntentEntry(date: Date(timeIntervalSince1970: 2_000), title: "LEGACY ENTRY SECOND",
                      configuration: "EXPLICIT-B", contextFamily: "explicit", isPreview: true)
}

#Preview("LEGACY INTENT DEFAULT", as: .systemSmall, using: INPlayMediaIntent()) {
    LegacyIntentWidget()
} timelineProvider: { LegacyIntentProvider() }

#Preview("LEGACY INTENT CONFIGURED", as: .systemSmall, using: configuredLegacyIntent()) {
    LegacyIntentWidget()
} timelineProvider: { LegacyIntentProvider() }

public struct CanonicalStaticProvider: TimelineProvider {
    public func placeholder(in context: Context) -> LegacyIntentEntry {
        LegacyIntentEntry(date: .now, title: "STATIC PLACEHOLDER", configuration: "NONE",
                          contextFamily: String(describing: context.family), isPreview: context.isPreview)
    }
    public func getSnapshot(in context: Context, completion: @escaping @Sendable (LegacyIntentEntry) -> Void) {
        completion(placeholder(in: context))
    }
    public func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<LegacyIntentEntry>) -> Void) {
        completion(Timeline(entries: [placeholder(in: context)], policy: .never))
    }
}

public struct CanonicalStaticWidget: Widget {
    public init() {}
    public var body: some WidgetConfiguration {
        StaticConfiguration(kind: "CanonicalStaticProbe", provider: CanonicalStaticProvider()) {
            LegacyIntentEntryView(entry: $0)
        }.configurationDisplayName("Canonical Static Probe").supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

#Preview("CANONICAL STATIC ENTRIES", as: .systemSmall) { CanonicalStaticWidget() } timeline: {
    LegacyIntentEntry(date: Date(timeIntervalSince1970: 1_000), title: "STATIC FIRST", configuration: "NONE",
                      contextFamily: "explicit", isPreview: true)
    LegacyIntentEntry(date: Date(timeIntervalSince1970: 2_000), title: "STATIC SECOND", configuration: "NONE",
                      contextFamily: "explicit", isPreview: true)
}

public struct CanonicalConfigurationIntent: WidgetConfigurationIntent {
    public static let title: LocalizedStringResource = "Canonical AppIntent"
    @Parameter(title: "Label", default: "DEFAULT") public var label: String
    public init() {}
    public init(label: String) { self.label = label }
}

public struct CanonicalAppIntentProvider: AppIntentTimelineProvider {
    public func placeholder(in context: Context) -> LegacyIntentEntry {
        LegacyIntentEntry(date: .now, title: "APPINTENT PLACEHOLDER", configuration: "NONE",
                          contextFamily: String(describing: context.family), isPreview: context.isPreview)
    }
    public func snapshot(for configuration: CanonicalConfigurationIntent, in context: Context) async -> LegacyIntentEntry {
        entry("APPINTENT SNAPSHOT", configuration: configuration, context: context)
    }
    public func timeline(for configuration: CanonicalConfigurationIntent, in context: Context) async -> Timeline<LegacyIntentEntry> {
        Timeline(entries: [entry("APPINTENT FIRST", configuration: configuration, context: context),
                           entry("APPINTENT SECOND", configuration: configuration, context: context,
                                 date: Date(timeIntervalSince1970: 2_000))], policy: .never)
    }
    private func entry(_ title: String, configuration: CanonicalConfigurationIntent, context: Context,
                       date: Date = Date(timeIntervalSince1970: 1_000)) -> LegacyIntentEntry {
        LegacyIntentEntry(date: date, title: title, configuration: configuration.label,
                          contextFamily: String(describing: context.family), isPreview: context.isPreview)
    }
}

public struct CanonicalAppIntentWidget: Widget {
    public init() {}
    public var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "CanonicalAppIntentProbe", intent: CanonicalConfigurationIntent.self,
                               provider: CanonicalAppIntentProvider()) { LegacyIntentEntryView(entry: $0) }
            .configurationDisplayName("Canonical AppIntent Probe").supportedFamilies([.systemSmall, .systemMedium])
    }
}

#Preview("CANONICAL APPINTENT CONFIGURED", as: .systemSmall, using: CanonicalConfigurationIntent(label: "CONFIGURED")) {
    CanonicalAppIntentWidget()
} timelineProvider: { CanonicalAppIntentProvider() }


public struct LegacyActivityNormalProvider: PreviewProvider {
    public static var previews: some View {
        ActivityProbeAttributes(name: "LEGACY ATTRIBUTES").previewContext(
            ActivityProbeAttributes.ContentState(marker: "LEGACY", progress: 0.75),
            isStale: false, viewKind: .content)
            .previewDisplayName("LEGACY ACTIVITY NORMAL")
    }
}

public struct LegacyActivityStaleProvider: PreviewProvider {
    public static var previews: some View {
        ActivityProbeAttributes(name: "LEGACY ATTRIBUTES").previewContext(
            ActivityProbeAttributes.ContentState(marker: "LEGACY", progress: 0.75),
            isStale: true, viewKind: .content)
            .previewDisplayName("LEGACY ACTIVITY STALE")
    }
}
