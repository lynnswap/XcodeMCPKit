import Foundation
import XcodeMCPWire

/// The scheme, run destination, and test plan that one MCP session uses in a headless workspace.
package struct NativeWorkspaceSelection: Equatable, Sendable {
    /// The `_meta` key of a selection in requests and results between the proxy and the host.
    package static let metadataKey = "com.lynnswap.xcode-mcpkit/selection"

    /// The scheme's name, with its container when several schemes share the name.
    package var scheme: String?
    package var destination: String?
    /// The test plan's name, or its path when several plans of the scheme share the name.
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
/// Only this process's actions change the selection of its headless models. The active selection
/// of a workspace is read from Xcode when needed and kept until an action that can change the
/// workspace, such as a switch or a new target with an automatically created scheme.
@MainActor
final class NativeWorkspaceSelections {
    /// Runs a native action and returns its structured output.
    typealias Run = (_ tool: String, _ arguments: [String: JSONValue]) async throws -> [String: JSONValue]

    /// Tools that inspect or change the selection.
    static let selectionTools: Set<String> = [
        "XcodeListSchemes", "XcodeListRunDestinations", "XcodeListTestPlans",
        "XcodeSwitchScheme", "XcodeSwitchRunDestination", "XcodeSwitchTestPlan",
    ]
    private static let switchTools: Set<String> = ["XcodeSwitchScheme", "XcodeSwitchRunDestination", "XcodeSwitchTestPlan"]

    private var active: [String: NativeWorkspaceSelection] = [:]

    /// The active selection of `workspace` as last read, or `nil` before it has been read.
    func cachedSelection(in workspace: String) -> NativeWorkspaceSelection? {
        active[workspace]
    }

    /// The active selection of `workspace`, read from Xcode when it is not known.
    func selection(in workspace: String, run: Run) async throws -> NativeWorkspaceSelection {
        if let selection = active[workspace] { return selection }
        let arguments: [String: JSONValue] = ["workspaceIdentifier": .string(workspace)]
        let scheme = Self.activeEntry(in: try await run("XcodeListSchemes", arguments), list: "schemes",
                                      identifier: "disambiguatedName", active: "activeSchemeName")
        let destinations = try await run("XcodeListRunDestinations", arguments)
        var testPlan: String?
        // Test plans belong to the active scheme; a workspace without one has none.
        if scheme != nil {
            testPlan = Self.activeEntry(in: try await run("XcodeListTestPlans", arguments), list: "testPlans",
                                        identifier: "path", active: "activeTestPlanName")
        }
        let selection = NativeWorkspaceSelection(
            scheme: scheme, destination: NativeWorkspaceSelection.string(destinations["activeDestinationDisplayTitle"]),
            testPlan: testPlan)
        active[workspace] = selection
        return selection
    }

    /// Prepares `workspace` for `tool` with the session's `requested` selection. Returns whether the
    /// tool's result reports the session's selection.
    ///
    /// An operation fails when the session's selection cannot be restored, so it never runs with
    /// another session's selection. Tools that inspect or switch the selection still run, so the
    /// session can correct settings that Xcode no longer offers.
    func prepare(for tool: String, requested: NativeWorkspaceSelection, in workspace: String,
                 run: Run) async throws -> Bool {
        guard tool != "XcodeCloseWorkspace" else { return false }
        do {
            try await apply(requested, in: workspace, run: run)
            return true
        } catch let error where Self.selectionTools.contains(tool) && !(error is CancellationError) {
            return false
        }
    }

    /// Updates what is known after `tool`, which `changesWorkspace` unless it only reads, completes
    /// with `output`, or `nil` when it failed. Returns the selection its result reports.
    func finish(_ tool: String, changesWorkspace: Bool, output: [String: JSONValue]?, reportsSelection: Bool,
                in workspace: String, run: Run) async -> NativeWorkspaceSelection? {
        let applied = reportsSelection ? active[workspace] : nil
        // An action that changes the workspace can change the selection even when it fails.
        if tool == "XcodeCloseWorkspace" || changesWorkspace || Self.switchTools.contains(tool) {
            active[workspace] = nil
        }
        if Self.switchTools.contains(tool) {
            guard let output else { return nil }
            if let selection = try? await selection(in: workspace, run: run) { return selection }
            // The switch's own output keeps the session from restoring what it had before the switch.
            return Self.selection(after: tool, output: output, from: applied ?? NativeWorkspaceSelection())
        }
        return tool == "XcodeCloseWorkspace" ? nil : applied
    }

    /// Updates what is known after `tool` ended without a result, such as when it was cancelled.
    func abandon(_ tool: String, changesWorkspace: Bool, in workspace: String) {
        if tool == "XcodeCloseWorkspace" || changesWorkspace || Self.switchTools.contains(tool) {
            active[workspace] = nil
        }
    }

    /// Forgets the selections of workspaces other than `workspaces`, whose models are closed.
    func retain(_ workspaces: Set<String>) {
        active = active.filter { workspaces.contains($0.key) }
    }

    /// Makes the parts of `requested` that it names active in `workspace`, and fails when Xcode
    /// selects something else.
    func apply(_ requested: NativeWorkspaceSelection, in workspace: String, run: Run) async throws {
        let steps: [(part: WritableKeyPath<NativeWorkspaceSelection, String?>, tool: String, argument: String, kind: String)] = [
            (\.scheme, "XcodeSwitchScheme", "schemeName", "scheme"),
            (\.destination, "XcodeSwitchRunDestination", "displayTitle", "run destination"),
            (\.testPlan, "XcodeSwitchTestPlan", "testPlanName", "test plan"),
        ]
        do {
            var current = try await selection(in: workspace, run: run)
            for step in steps {
                guard let value = requested[keyPath: step.part], value != current[keyPath: step.part] else { continue }
                _ = try await run(step.tool, ["workspaceIdentifier": .string(workspace), step.argument: .string(value)])
                // Xcode can adjust the other parts, so the whole selection is read again.
                active[workspace] = nil
                current = try await selection(in: workspace, run: run)
                guard current[keyPath: step.part] == value else {
                    throw NativeToolExecutionError(message: "This session's \(step.kind) '\(value)' could not be "
                        + "selected; Xcode selected \(current[keyPath: step.part].map { "'\($0)'" } ?? "none"). "
                        + "Switch the \(step.kind) again before retrying.")
                }
            }
        } catch {
            // A switch that failed partway leaves the selection unknown.
            active[workspace] = nil
            throw error
        }
    }

    /// The selection after a switch, from the switch's output and the selection it started from.
    private static func selection(after tool: String, output: [String: JSONValue],
                                  from base: NativeWorkspaceSelection) -> NativeWorkspaceSelection {
        var selection = base
        switch tool {
        case "XcodeSwitchScheme":
            selection.scheme = NativeWorkspaceSelection.string(output["activeSchemeName"])
            selection.destination = NativeWorkspaceSelection.string(output["activeDestinationDisplayTitle"])
            selection.testPlan = NativeWorkspaceSelection.string(output["activeTestPlanName"])
        case "XcodeSwitchRunDestination":
            selection.destination = NativeWorkspaceSelection.string(output["activeDestinationDisplayTitle"])
        default:
            selection.testPlan = NativeWorkspaceSelection.string(output["activeTestPlanPath"])
                ?? NativeWorkspaceSelection.string(output["activeTestPlanName"])
        }
        return selection
    }

    /// The active entry of a list action's output, by the field that tells it apart from entries
    /// that share its name.
    private static func activeEntry(in output: [String: JSONValue], list: String, identifier: String,
                                    active: String) -> String? {
        if case .array(let entries)? = output[list] {
            for case .object(let entry) in entries where entry["isActive"] == .bool(true) {
                return NativeWorkspaceSelection.string(entry[identifier]) ?? NativeWorkspaceSelection.string(entry["name"])
            }
        }
        return NativeWorkspaceSelection.string(output[active])
    }
}
