import Foundation
import XcodeMCPWire

/// The scheme, run destination, and test plan that one MCP session uses in a headless workspace.
package struct NativeWorkspaceSelection: Equatable, Sendable {
    /// The `_meta` key of a selection in requests and results between the proxy and the host.
    package static let metadataKey = "com.lynnswap.xcode-mcpkit/selection"

    package var scheme: String?
    package var destination: String?
    package var testPlan: String?

    package init(scheme: String? = nil, destination: String? = nil, testPlan: String? = nil) {
        self.scheme = scheme
        self.destination = destination
        self.testPlan = testPlan
    }

    /// Reads the selection that the proxy sends in a request's `_meta`.
    package init?(json: JSONValue?) {
        guard case .object(let fields)? = json else { return nil }
        self.init(scheme: Self.string(fields["scheme"]), destination: Self.string(fields["destination"]),
                  testPlan: Self.string(fields["testPlan"]))
    }

    package var json: JSONValue {
        var fields: [String: JSONValue] = [:]
        if let scheme { fields["scheme"] = .string(scheme) }
        if let destination { fields["destination"] = .string(destination) }
        if let testPlan { fields["testPlan"] = .string(testPlan) }
        return .object(fields)
    }

    static func string(_ value: JSONValue?) -> String? {
        if case .string(let string)? = value { string } else { nil }
    }
}

/// Applies each session's selection to a headless workspace before the session's operations.
///
/// Only this process's switch actions change the selection of its headless models, so the active
/// selection of a workspace is read from Xcode once and then kept from their outputs.
@MainActor
final class NativeWorkspaceSelections {
    /// Runs a native action and returns its structured output.
    typealias Run = (_ tool: String, _ arguments: [String: JSONValue]) async throws -> [String: JSONValue]

    private var active: [String: NativeWorkspaceSelection] = [:]

    /// The selection last made active in `workspace`, or `nil` before it has been read.
    func cachedSelection(in workspace: String) -> NativeWorkspaceSelection? {
        active[workspace]
    }

    /// The active selection of `workspace`, read from Xcode when this process has not seen it yet.
    func selection(in workspace: String, run: Run) async throws -> NativeWorkspaceSelection {
        if let selection = active[workspace] { return selection }
        let destinations = try await run("XcodeListRunDestinations", ["workspaceIdentifier": .string(workspace)])
        let plans = try await run("XcodeListTestPlans", ["workspaceIdentifier": .string(workspace)])
        let selection = NativeWorkspaceSelection(
            scheme: NativeWorkspaceSelection.string(destinations["activeSchemeName"]),
            destination: NativeWorkspaceSelection.string(destinations["activeDestinationDisplayTitle"]),
            testPlan: NativeWorkspaceSelection.string(plans["activeTestPlanName"]))
        active[workspace] = selection
        return selection
    }

    /// Makes the parts of `requested` that it names active in `workspace`. It fails when Xcode
    /// selects something else, so an operation never runs with another session's selection.
    func apply(_ requested: NativeWorkspaceSelection, in workspace: String, run: Run) async throws {
        var current = try await selection(in: workspace, run: run)
        if let scheme = requested.scheme, scheme != current.scheme {
            current = try await switchSelection("XcodeSwitchScheme", argument: "schemeName", to: scheme,
                                                in: workspace, run: run)
            try Self.verify(current.scheme, requested: scheme, kind: "scheme")
        }
        if let destination = requested.destination, destination != current.destination {
            current = try await switchSelection("XcodeSwitchRunDestination", argument: "displayTitle", to: destination,
                                                in: workspace, run: run)
            try Self.verify(current.destination, requested: destination, kind: "run destination")
        }
        if let testPlan = requested.testPlan, testPlan != current.testPlan {
            current = try await switchSelection("XcodeSwitchTestPlan", argument: "testPlanName", to: testPlan,
                                                in: workspace, run: run)
            try Self.verify(current.testPlan, requested: testPlan, kind: "test plan")
        }
    }

    /// Updates the active selection of `workspace` from a switch action's output.
    func record(_ tool: String, output: [String: JSONValue], in workspace: String) {
        guard var selection = active[workspace] else { return }
        switch tool {
        case "XcodeSwitchScheme":
            // Xcode can also change the destination and test plan to fit the new scheme.
            selection.scheme = NativeWorkspaceSelection.string(output["activeSchemeName"])
            selection.destination = NativeWorkspaceSelection.string(output["activeDestinationDisplayTitle"])
            selection.testPlan = NativeWorkspaceSelection.string(output["activeTestPlanName"])
        case "XcodeSwitchRunDestination":
            selection.destination = NativeWorkspaceSelection.string(output["activeDestinationDisplayTitle"])
        case "XcodeSwitchTestPlan":
            // A path identifies the plan when several plans share its name.
            selection.testPlan = NativeWorkspaceSelection.string(output["activeTestPlanPath"])
                ?? NativeWorkspaceSelection.string(output["activeTestPlanName"])
        default:
            return
        }
        active[workspace] = selection
    }

    /// Forgets the selections of workspaces other than `workspaces`, whose models are closed.
    func retain(_ workspaces: Set<String>) {
        active = active.filter { workspaces.contains($0.key) }
    }

    func forget(_ workspace: String) {
        active[workspace] = nil
    }

    private func switchSelection(_ tool: String, argument: String, to value: String, in workspace: String,
                                 run: Run) async throws -> NativeWorkspaceSelection {
        let output = try await run(tool, ["workspaceIdentifier": .string(workspace), argument: .string(value)])
        record(tool, output: output, in: workspace)
        return active[workspace] ?? NativeWorkspaceSelection()
    }

    private static func verify(_ selected: String?, requested: String, kind: String) throws {
        guard selected != requested else { return }
        throw NativeToolExecutionError(message: "This session's \(kind) '\(requested)' could not be selected; Xcode "
            + "selected \(selected.map { "'\($0)'" } ?? "none"). Switch the \(kind) again before retrying.")
    }
}
