import Testing
@testable import XcodeMCPNativeRuntime
import XcodeMCPWire

@MainActor
struct NativeWorkspaceSelectionsTests {
    /// A workspace whose selection changes only through the switch actions run against it.
    @MainActor
    private final class Workspace {
        var scheme = "App"
        var destination = "My Mac"
        var testPlan = "Unit"
        /// A destination that Xcode does not select, as when it is unavailable.
        var unavailableDestination: String?
        var calls: [String] = []

        func run(_ tool: String, _ arguments: [String: JSONValue]) -> [String: JSONValue] {
            calls.append(tool)
            func argument(_ key: String) -> String {
                if case .string(let value)? = arguments[key] { value } else { "" }
            }
            switch tool {
            case "XcodeListRunDestinations":
                return ["activeSchemeName": .string(scheme), "activeDestinationDisplayTitle": .string(destination)]
            case "XcodeListTestPlans":
                return ["activeTestPlanName": .string(testPlan)]
            case "XcodeSwitchScheme":
                // Like Xcode, switching the scheme also selects that scheme's test plan.
                scheme = argument("schemeName")
                testPlan = scheme + "Tests"
                return ["activeSchemeName": .string(scheme), "activeDestinationDisplayTitle": .string(destination),
                        "activeTestPlanName": .string(testPlan)]
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
        let run: NativeWorkspaceSelections.Run = { tool, arguments in workspace.run(tool, arguments) }

        try await selections.apply(NativeWorkspaceSelection(), in: "w1", run: run)
        let first = NativeWorkspaceSelection(scheme: "App", destination: "My Mac", testPlan: "Unit")
        #expect(selections.cachedSelection(in: "w1") == first)
        #expect(workspace.calls == ["XcodeListRunDestinations", "XcodeListTestPlans"])

        // Another session switches the scheme.
        try await selections.apply(NativeWorkspaceSelection(scheme: "Tool"), in: "w1", run: run)
        #expect(selections.cachedSelection(in: "w1")
            == NativeWorkspaceSelection(scheme: "Tool", destination: "My Mac", testPlan: "ToolTests"))

        // The first session's next operation restores its scheme and test plan.
        workspace.calls = []
        try await selections.apply(first, in: "w1", run: run)
        #expect(workspace.calls == ["XcodeSwitchScheme", "XcodeSwitchTestPlan"])
        #expect(selections.cachedSelection(in: "w1") == first)

        workspace.calls = []
        try await selections.apply(first, in: "w1", run: run)
        #expect(workspace.calls.isEmpty)
    }

    @Test func aSelectionThatXcodeDoesNotMakeActiveFailsTheOperation() async throws {
        let workspace = Workspace()
        workspace.unavailableDestination = "iPhone 17"
        let selections = NativeWorkspaceSelections()
        await #expect(throws: NativeToolExecutionError.self) {
            try await selections.apply(NativeWorkspaceSelection(destination: "iPhone 17"), in: "w1") { tool, arguments in
                workspace.run(tool, arguments)
            }
        }
    }

    @Test func aClosedWorkspaceIsReadAgainWhenReopened() async throws {
        let workspace = Workspace()
        let selections = NativeWorkspaceSelections()
        let run: NativeWorkspaceSelections.Run = { tool, arguments in workspace.run(tool, arguments) }
        try await selections.apply(NativeWorkspaceSelection(), in: "w1", run: run)
        selections.retain([])
        #expect(selections.cachedSelection(in: "w1") == nil)
        workspace.calls = []
        try await selections.apply(NativeWorkspaceSelection(), in: "w1", run: run)
        #expect(workspace.calls == ["XcodeListRunDestinations", "XcodeListTestPlans"])
    }
}
