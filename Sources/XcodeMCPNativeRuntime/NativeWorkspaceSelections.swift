import Foundation
import XcodeMCPWire

/// The scheme, run destination, and test plan that one MCP session uses in a headless workspace.
package struct NativeWorkspaceSelection: Equatable, Sendable {
    /// The `_meta` key of a selection in requests and results between the proxy and the host.
    package static let metadataKey = "com.lynnswap.xcode-mcpkit/selection"

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
/// Only this process's actions change the selection of its headless models, so the active
/// selection of a workspace is read from Xcode once, and again after each switch.
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
        let destinations = try await run("XcodeListRunDestinations", arguments)
        let scheme = NativeWorkspaceSelection.string(destinations["activeSchemeName"])
        var testPlan: String?
        // Test plans belong to the active scheme; a workspace without one has none.
        if scheme != nil {
            let plans = try await run("XcodeListTestPlans", arguments)
            testPlan = Self.activeTestPlan(in: plans)
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

    /// Updates what is known after `tool` completes and returns the selection its result reports.
    func finish(_ tool: String, completed: Bool, reportsSelection: Bool, in workspace: String,
                run: Run) async -> NativeWorkspaceSelection? {
        if tool == "XcodeCloseWorkspace" || Self.switchTools.contains(tool) {
            // A switch can change the selection even when it fails.
            active[workspace] = nil
            guard Self.switchTools.contains(tool), completed else { return nil }
            return try? await selection(in: workspace, run: run)
        }
        return reportsSelection ? active[workspace] : nil
    }

    /// Updates what is known after `tool` ended without a result, such as when it was cancelled.
    func abandon(_ tool: String, in workspace: String) {
        if tool == "XcodeCloseWorkspace" || Self.switchTools.contains(tool) { active[workspace] = nil }
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

    private static func activeTestPlan(in output: [String: JSONValue]) -> String? {
        if case .array(let plans)? = output["testPlans"] {
            for case .object(let plan) in plans where plan["isActive"] == .bool(true) {
                return NativeWorkspaceSelection.string(plan["path"]) ?? NativeWorkspaceSelection.string(plan["name"])
            }
        }
        return NativeWorkspaceSelection.string(output["activeTestPlanName"])
    }
}
