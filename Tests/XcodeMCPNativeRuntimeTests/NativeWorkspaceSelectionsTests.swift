import Testing
@testable import XcodeMCPNativeRuntime
import XcodeMCPWire

@MainActor
struct NativeWorkspaceSelectionsTests {
    /// A workspace whose selection changes only through the switch actions run against it.
    @MainActor
    private final class Workspace {
        var scheme: String? = "App"
        var destination = "My Mac"
        var testPlan = "Unit"
        /// Paths of plans that share the active plan's name.
        var duplicatePlanPaths: [String] = []
        /// A destination that Xcode does not select, as when it is unavailable.
        var unavailableDestination: String?
        var calls: [String] = []

        var run: NativeWorkspaceSelections.Run {
            { tool, arguments in try self.perform(tool, arguments) }
        }

        private func perform(_ tool: String, _ arguments: [String: JSONValue]) throws -> [String: JSONValue] {
            calls.append(tool)
            func argument(_ key: String) -> String {
                if case .string(let value)? = arguments[key] { value } else { "" }
            }
            switch tool {
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

        try await selections.apply(NativeWorkspaceSelection(), in: "w1", run: workspace.run)
        let first = NativeWorkspaceSelection(scheme: "App", destination: "My Mac", testPlan: "Unit")
        #expect(selections.cachedSelection(in: "w1") == first)
        #expect(workspace.calls == ["XcodeListRunDestinations", "XcodeListTestPlans"])

        // Another session switches the scheme.
        try await selections.apply(NativeWorkspaceSelection(scheme: "Tool"), in: "w1", run: workspace.run)
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
        let requested = NativeWorkspaceSelection(destination: "iPhone 17")
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
        let reported = await selections.finish("XcodeSwitchRunDestination", completed: true, reportsSelection: true,
                                               in: "w1", run: workspace.run)
        #expect(reported?.destination == "iPhone 17")

        // A failed or cancelled switch may have changed the selection, so it is read again next time.
        workspace.scheme = "Tool"
        #expect(await selections.finish("XcodeSwitchScheme", completed: false, reportsSelection: true,
                                        in: "w1", run: workspace.run) == nil)
        #expect(selections.cachedSelection(in: "w1") == nil)
        _ = try await selections.selection(in: "w1", run: workspace.run)
        selections.abandon("XcodeSwitchTestPlan", in: "w1")
        #expect(selections.cachedSelection(in: "w1") == nil)
    }

    @Test func aWorkspaceWithoutAnActiveSchemeCanBeUsed() async throws {
        let workspace = Workspace()
        workspace.scheme = nil
        let selections = NativeWorkspaceSelections()
        #expect(try await selections.prepare(for: "XcodeListSchemes", requested: NativeWorkspaceSelection(),
                                             in: "w1", run: workspace.run))
        #expect(selections.cachedSelection(in: "w1") == NativeWorkspaceSelection(destination: "My Mac"))
    }

    @Test func plansThatShareANameAreIdentifiedByPath() async throws {
        let workspace = Workspace()
        workspace.duplicatePlanPaths = ["/A/Unit.xctestplan", "/B/Unit.xctestplan"]
        let selections = NativeWorkspaceSelections()
        #expect(try await selections.selection(in: "w1", run: workspace.run).testPlan == "/A/Unit.xctestplan")
    }

    @Test func aClosedWorkspaceIsReadAgainWhenReopened() async throws {
        let workspace = Workspace()
        let selections = NativeWorkspaceSelections()
        try await selections.apply(NativeWorkspaceSelection(), in: "w1", run: workspace.run)
        selections.retain([])
        #expect(selections.cachedSelection(in: "w1") == nil)
    }
}
