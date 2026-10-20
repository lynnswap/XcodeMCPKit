import Testing
@testable import XcodeMCPNativeRuntime
import XcodeMCPWire

@MainActor
struct NativeWorkspaceSelectionsTests {
    /// A workspace whose selection changes only through the switch actions run against it.
    @MainActor
    private final class Workspace {
        var scheme: String? = "App"
        /// Schemes and the containers that share each scheme's name.
        var schemes: [String: [String]] = ["App": ["App"], "Tool": ["App"]]
        var destination = "My Mac"
        var testPlan = "Unit"
        /// Paths of plans that share the active plan's name.
        var duplicatePlanPaths: [String] = []
        /// A destination that Xcode does not select, as when it is unavailable.
        var unavailableDestination: String?
        var listsFail = false
        var calls: [String] = []

        var run: NativeWorkspaceSelections.Run {
            { tool, arguments in try self.perform(tool, arguments) }
        }

        private func perform(_ tool: String, _ arguments: [String: JSONValue]) throws -> [String: JSONValue] {
            calls.append(tool)
            if listsFail, tool.hasPrefix("XcodeList") { throw NativeToolExecutionError(message: "\(tool) failed") }
            func argument(_ key: String) -> String {
                if case .string(let value)? = arguments[key] { value } else { "" }
            }
            switch tool {
            case "XcodeListSchemes":
                let entries: [JSONValue] = schemes.sorted { $0.key < $1.key }.flatMap { name, containers in
                    containers.map { container in
                        let disambiguated = containers.count > 1 ? "\(name) (\(container))" : name
                        return .object(["name": .string(name), "disambiguatedName": .string(disambiguated),
                                        "isActive": .bool(disambiguated == scheme)])
                    }
                }
                return ["activeSchemeName": scheme.map(JSONValue.string) ?? .null, "schemes": .array(entries)]
            case "XcodeListRunDestinations":
                return ["activeSchemeName": scheme.map(JSONValue.string) ?? .null,
                        "activeDestinationDisplayTitle": .string(destination)]
            case "XcodeListTestPlans":
                guard scheme != nil else { throw NativeToolExecutionError(message: "No scheme is active") }
                let plans: [JSONValue] = duplicatePlanPaths.isEmpty
                    ? [.object(["name": .string(testPlan), "isActive": .bool(true)])]
                    : duplicatePlanPaths.enumerated().map { offset, path in
                        .object(["name": .string(testPlan), "path": .string(path), "isActive": .bool(offset == 0)])
                    }
                return ["activeTestPlanName": .string(testPlan), "testPlans": .array(plans)]
            case "XcodeSwitchScheme":
                // Like Xcode, switching the scheme also selects that scheme's test plan.
                scheme = argument("schemeName")
                testPlan = argument("schemeName") + "Tests"
                return ["activeSchemeName": .string(argument("schemeName"))]
            case "XcodeSwitchRunDestination":
                if argument("displayTitle") != unavailableDestination { destination = argument("displayTitle") }
                return ["activeDestinationDisplayTitle": .string(destination)]
            case "XcodeSwitchTestPlan":
                testPlan = argument("testPlanName")
                return ["activeTestPlanName": .string(testPlan)]
            default:
                Issue.record("Unexpected action \(tool)")
                return [:]
            }
        }
    }

    @Test func aSessionsSelectionIsAppliedOnlyWhereItDiffersFromTheWorkspace() async throws {
        let workspace = Workspace()
        let selections = NativeWorkspaceSelections()

        try await selections.apply(nil, in: "w1", run: workspace.run)
        let first = NativeWorkspaceSelection(scheme: "App", destination: "My Mac", testPlan: "Unit")
        #expect(selections.cachedSelection(in: "w1") == first)
        #expect(workspace.calls == ["XcodeListSchemes", "XcodeListRunDestinations", "XcodeListTestPlans"])

        // Another session switches the scheme.
        try await selections.apply(NativeWorkspaceSelection(scheme: "Tool", destination: "My Mac", testPlan: "ToolTests"),
                                   in: "w1", run: workspace.run)
        #expect(selections.cachedSelection(in: "w1")
            == NativeWorkspaceSelection(scheme: "Tool", destination: "My Mac", testPlan: "ToolTests"))

        // The first session's next operation restores its scheme and then its test plan.
        workspace.calls = []
        try await selections.apply(first, in: "w1", run: workspace.run)
        #expect(workspace.calls.filter { $0.hasPrefix("XcodeSwitch") } == ["XcodeSwitchScheme", "XcodeSwitchTestPlan"])
        #expect(selections.cachedSelection(in: "w1") == first)

        workspace.calls = []
        try await selections.apply(first, in: "w1", run: workspace.run)
        #expect(workspace.calls.isEmpty)
    }

    @Test func anOperationFailsWhenTheSessionsSelectionCannotBeRestored() async throws {
        let workspace = Workspace()
        workspace.unavailableDestination = "iPhone 17"
        let selections = NativeWorkspaceSelections()
        let requested = NativeWorkspaceSelection(scheme: "App", destination: "iPhone 17", testPlan: "Unit")
        await #expect(throws: NativeToolExecutionError.self) {
            _ = try await selections.prepare(for: "BuildProject", requested: requested, in: "w1", run: workspace.run)
        }
        // Inspecting and switching still run, so the session can choose another destination.
        #expect(try await selections.prepare(for: "XcodeSwitchRunDestination", requested: requested, in: "w1",
                                             run: workspace.run) == false)
        #expect(try await selections.prepare(for: "XcodeListRunDestinations", requested: requested, in: "w1",
                                             run: workspace.run) == false)
    }

    @Test func aSwitchIsReadBackWhenItCompletesAndForgottenWhenItDoesNot() async throws {
        let workspace = Workspace()
        let selections = NativeWorkspaceSelections()
        _ = try await selections.selection(in: "w1", run: workspace.run)

        workspace.destination = "iPhone 17"
        let reported = await selections.finish("XcodeSwitchRunDestination", changesWorkspace: true, output: [:],
                                               reportsSelection: true, in: "w1", run: workspace.run)
        #expect(reported?.destination == "iPhone 17")

        // A switch that cannot be read back leaves the session to switch again before other operations.
        workspace.listsFail = true
        let unknown = await selections.finish("XcodeSwitchScheme", changesWorkspace: true, output: [:],
                                              reportsSelection: true, in: "w1", run: workspace.run)
        #expect(unknown == .unknown)
        workspace.listsFail = false
        await #expect(throws: NativeToolExecutionError.self) {
            _ = try await selections.prepare(for: "BuildProject", requested: .unknown, in: "w1", run: workspace.run)
        }
        #expect(try await selections.prepare(for: "XcodeSwitchScheme", requested: .unknown, in: "w1",
                                             run: workspace.run) == false)

        // A failed switch leaves the session with the selection it started from, and because the
        // switch may have changed the workspace anyway, the selection is read again next time.
        let before = try await selections.selection(in: "w1", run: workspace.run)
        workspace.scheme = "Tool"
        #expect(await selections.finish("XcodeSwitchScheme", changesWorkspace: true, output: nil,
                                        reportsSelection: true, in: "w1", run: workspace.run) == before)
        #expect(selections.cachedSelection(in: "w1") == nil)
        _ = try await selections.selection(in: "w1", run: workspace.run)
        selections.abandon("XcodeSwitchTestPlan", changesWorkspace: true, in: "w1")
        #expect(selections.cachedSelection(in: "w1") == nil)
    }

    @Test func anActionThatChangesTheWorkspaceReadsTheSelectionAgainBeforeTheNextOperation() async throws {
        let workspace = Workspace()
        let selections = NativeWorkspaceSelections()
        let session = NativeWorkspaceSelection(scheme: "App", destination: "My Mac", testPlan: "Unit")
        #expect(try await selections.prepare(for: "XcodeNewTarget", requested: session, in: "w1", run: workspace.run))
        // The new target's scheme becomes active, as with automatically created schemes.
        workspace.scheme = "Tool"
        let reported = await selections.finish("XcodeNewTarget", changesWorkspace: true, output: [:],
                                               reportsSelection: true, in: "w1", run: workspace.run)
        #expect(reported == session)

        workspace.calls = []
        _ = try await selections.prepare(for: "BuildProject", requested: session, in: "w1", run: workspace.run)
        #expect(workspace.calls.contains("XcodeSwitchScheme"))
        #expect(workspace.scheme == "App")

        // A query keeps what is known.
        _ = await selections.finish("XcodeRead", changesWorkspace: false, output: [:], reportsSelection: true,
                                    in: "w1", run: workspace.run)
        #expect(selections.cachedSelection(in: "w1") != nil)
    }

    @Test func aWorkspaceWithoutAnActiveSchemeCanBeUsed() async throws {
        let workspace = Workspace()
        workspace.scheme = nil
        let selections = NativeWorkspaceSelections()
        #expect(try await selections.prepare(for: "XcodeListSchemes", requested: nil, in: "w1", run: workspace.run))
        #expect(selections.cachedSelection(in: "w1") == NativeWorkspaceSelection(destination: "My Mac"))
    }

    @Test func aSessionWithoutASchemeDoesNotRunWithAnotherSessionsScheme() async throws {
        let workspace = Workspace()
        workspace.scheme = nil
        let selections = NativeWorkspaceSelections()
        let recorded = try await selections.selection(in: "w1", run: workspace.run)
        // Another session selects a scheme.
        try await selections.apply(NativeWorkspaceSelection(scheme: "Tool", destination: "My Mac", testPlan: "ToolTests"),
                                   in: "w1", run: workspace.run)
        await #expect(throws: NativeToolExecutionError.self) {
            _ = try await selections.prepare(for: "BuildProject", requested: recorded, in: "w1", run: workspace.run)
        }
    }

    @Test func schemesAndPlansThatShareANameAreToldApart() async throws {
        let workspace = Workspace()
        workspace.schemes = ["App": ["Mac", "iOS"]]
        workspace.scheme = "App (iOS)"
        workspace.duplicatePlanPaths = ["/A/Unit.xctestplan", "/B/Unit.xctestplan"]
        let selections = NativeWorkspaceSelections()
        let selection = try await selections.selection(in: "w1", run: workspace.run)
        #expect(selection.scheme == "App (iOS)")
        #expect(selection.testPlan == "/A/Unit.xctestplan")

        // Another session's scheme of the same name in the other project is restored too.
        try await selections.apply(
            NativeWorkspaceSelection(scheme: "App (Mac)", destination: "My Mac", testPlan: "/A/Unit.xctestplan"),
            in: "w1", run: workspace.run)
        #expect(workspace.scheme == "App (Mac)")
    }

    @Test func aClosedWorkspaceIsReadAgainWhenReopened() async throws {
        let workspace = Workspace()
        let selections = NativeWorkspaceSelections()
        try await selections.apply(nil, in: "w1", run: workspace.run)
        selections.retain([])
        #expect(selections.cachedSelection(in: "w1") == nil)
    }
}
