#if os(watchOS)
import AppIntents
import SwiftUI
import WidgetKit

enum ExpectedRelevanceHostError: Error { case expectedProviderFailure }

@available(watchOS 26.0, *)
struct ThrowingRelevanceHostProvider: RelevanceEntriesProvider {
    func relevance() async -> WidgetRelevance<RelevanceProbeIntent> {
        await RelevanceProbeProvider().relevance()
    }

    func entry(configuration: RelevanceProbeIntent, context: Context) async throws -> RelevanceProbeEntry {
        throw ExpectedRelevanceHostError.expectedProviderFailure
    }

    func placeholder(context: Context) -> RelevanceProbeEntry {
        RelevanceProbeEntry(marker: "ERROR PLACEHOLDER", isPreview: context.isPreview)
    }
}

@available(watchOS 26.0, *)
struct ThrowingRelevanceHostWidget: Widget {
    var body: some WidgetConfiguration {
        RelevanceConfiguration(kind: "ThrowingRelevanceHostWidget", provider: ThrowingRelevanceHostProvider()) { entry in
            RelevanceProbeView(entry: entry)
        }
        .configurationDisplayName("Throwing Relevance Host")
    }
}

@available(watchOS 26.0, *)
#Preview("NATIVE THROWING RELEVANCE PROVIDER", widget: { ThrowingRelevanceHostWidget() }, relevanceProvider: {
    ThrowingRelevanceHostProvider()
})
#endif
