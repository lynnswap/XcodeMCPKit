import AppIntents
import Foundation
import SwiftUI
import WidgetKit

struct EmptyHostTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> LegacyIntentEntry {
        entry("EMPTY PLACEHOLDER", context: context)
    }

    func snapshot(for configuration: CanonicalConfigurationIntent, in context: Context) async -> LegacyIntentEntry {
        entry("EMPTY SNAPSHOT", context: context)
    }

    func timeline(for configuration: CanonicalConfigurationIntent, in context: Context) async -> Timeline<LegacyIntentEntry> {
        Timeline(entries: [], policy: .never)
    }

    private func entry(_ title: String, context: Context) -> LegacyIntentEntry {
        LegacyIntentEntry(date: Date(timeIntervalSince1970: 1_000), title: title,
            configuration: "EMPTY", contextFamily: String(describing: context.family), isPreview: context.isPreview)
    }
}

struct EmptyHostTimelineWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "EmptyHostTimelineWidget", intent: CanonicalConfigurationIntent.self,
                               provider: EmptyHostTimelineProvider()) { entry in
            LegacyIntentEntryView(entry: entry)
        }
        .configurationDisplayName("Empty Host Timeline")
    }
}

#Preview("NATIVE EMPTY APPINTENT TIMELINE", as: .systemSmall,
         using: CanonicalConfigurationIntent(label: "EMPTY")) {
    EmptyHostTimelineWidget()
} timelineProvider: {
    EmptyHostTimelineProvider()
}

struct WaitingHostTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> LegacyIntentEntry {
        entry("WAIT PLACEHOLDER", context: context)
    }

    func snapshot(for configuration: CanonicalConfigurationIntent, in context: Context) async -> LegacyIntentEntry {
        entry(await waitForCancellation(stage: "snapshot"), context: context)
    }

    func timeline(for configuration: CanonicalConfigurationIntent, in context: Context) async -> Timeline<LegacyIntentEntry> {
        Timeline(entries: [entry(await waitForCancellation(stage: "timeline"), context: context)], policy: .never)
    }

    private func waitForCancellation(stage: String) async -> String {
        do {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: [
                "stage": stage,
                "pid": ProcessInfo.processInfo.processIdentifier,
                "bundleIdentifier": Bundle.main.bundleIdentifier ?? "NO BUNDLE ID",
                "time": Date().timeIntervalSince1970,
            ], options: [.sortedKeys])
            try data.write(to: documents.appendingPathComponent("NativeWidgetProviderWaiting.json"), options: .atomic)
        } catch {
            return "MARKER WRITE FAILED"
        }
        do { try await Task.sleep(for: .seconds(180)) }
        catch { return "WAIT CANCELLED" }
        return "WAIT FINISHED"
    }

    private func entry(_ title: String, context: Context) -> LegacyIntentEntry {
        LegacyIntentEntry(date: Date(timeIntervalSince1970: 1_000), title: title,
            configuration: "WAIT", contextFamily: String(describing: context.family), isPreview: context.isPreview)
    }
}

struct WaitingHostTimelineWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "WaitingHostTimelineWidget", intent: CanonicalConfigurationIntent.self,
                               provider: WaitingHostTimelineProvider()) { entry in
            LegacyIntentEntryView(entry: entry)
        }
        .configurationDisplayName("Waiting Host Timeline")
    }
}

#Preview("NATIVE HOST CANCELLATION", as: .systemSmall,
         using: CanonicalConfigurationIntent(label: "WAIT")) {
    WaitingHostTimelineWidget()
} timelineProvider: {
    WaitingHostTimelineProvider()
}
