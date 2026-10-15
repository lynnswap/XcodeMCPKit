#if os(watchOS)
import SwiftUI
import WidgetKit
import AppIntents

@available(watchOS 26.0, *)
struct RelevanceProbeIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "Relevance probe" }
    @Parameter(title: "Marker", default: "DEFAULT") var marker: String
    init() {}
    init(marker: String) { self.marker = marker }
}

@available(watchOS 26.0, *)
struct RelevanceProbeEntry: RelevanceEntry {
    let marker: String
    let isPreview: Bool
}

@available(watchOS 26.0, *)
struct RelevanceProbeProvider: RelevanceEntriesProvider {
    func relevance() async -> WidgetRelevance<RelevanceProbeIntent> {
        WidgetRelevance([
            .init(configuration: RelevanceProbeIntent(marker: "PROVIDER FIRST"), group: .named("first")),
            .init(configuration: RelevanceProbeIntent(marker: "PROVIDER SECOND"), group: .named("second"))
        ])
    }
    func entry(configuration: RelevanceProbeIntent, context: Context) async throws -> RelevanceProbeEntry {
        RelevanceProbeEntry(marker: configuration.marker, isPreview: context.isPreview)
    }
    func placeholder(context: Context) -> RelevanceProbeEntry {
        RelevanceProbeEntry(marker: "PLACEHOLDER", isPreview: context.isPreview)
    }
}

@available(watchOS 26.0, *)
struct RelevanceProbeView: View {
    let entry: RelevanceProbeEntry
    var body: some View {
        VStack(alignment: .leading) {
            Text(entry.marker).font(.headline)
            Text("PREVIEW \(entry.isPreview.description)").font(.caption2)
        }
        .containerBackground(.indigo.gradient, for: .widget)
    }
}

@available(watchOS 26.0, *)
struct RelevanceProbeWidget: Widget {
    var body: some WidgetConfiguration {
        RelevanceConfiguration(kind: "RelevanceProbe", provider: RelevanceProbeProvider()) { entry in
            RelevanceProbeView(entry: entry)
        }
        .configurationDisplayName("Relevance Probe")
    }
}

@available(watchOS 26.0, *)
#Preview("RELEVANCE ENTRIES", widget: { RelevanceProbeWidget() }) {
    RelevanceProbeEntry(marker: "EXPLICIT FIRST", isPreview: true)
    RelevanceProbeEntry(marker: "EXPLICIT SECOND", isPreview: true)
}

@available(watchOS 26.0, *)
#Preview("RELEVANCE PROVIDER", widget: { RelevanceProbeWidget() }, relevanceProvider: {
    RelevanceProbeProvider()
})

@available(watchOS 26.0, *)
#Preview("RELEVANCE CONFIGURED", widget: { RelevanceProbeWidget() }, relevanceProvider: {
    RelevanceProbeProvider()
}, relevance: {
    WidgetRelevance([
        .init(configuration: RelevanceProbeIntent(marker: "OVERRIDE FIRST"), group: .named("first")),
        .init(configuration: RelevanceProbeIntent(marker: "OVERRIDE SECOND"), group: .named("second"))
    ])
})
#endif
