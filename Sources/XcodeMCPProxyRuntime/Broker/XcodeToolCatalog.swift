import Foundation
import XcodeMCPCore

/// The client contract is independent of the native host chosen for a workspace.
enum XcodeToolCatalog {
    static func publicResult(from nativeResult: JSONValue, managementTools: [JSONValue]) throws -> JSONValue {
        guard case .object(var result) = nativeResult,
              case .array(let nativeTools)? = result["tools"] else {
            throw NativeHostBrokerError("Native catalog has no tools")
        }
        let managedNames = Set(managementTools.compactMap(toolName))
        var tools: [String: JSONValue] = [:]
        let workspaceSession = nativeTools.first { toolName($0) == "DeviceInteractionStartWorkspaceSession" }
        for native in nativeTools {
            guard let name = toolName(native), name != "XcodeListWindows",
                  name != "XcodeMCPKitSelectHost", name != "DeviceInteractionStartWorkspaceSession",
                  !managedNames.contains(name) else { continue }
            let source: JSONValue
            if name == "DeviceInteractionStartSession", let workspaceSession {
                source = mergedDeviceSession(standalone: native, workspace: workspaceSession)
            } else {
                source = native
            }
            tools[name] = normalized(source, name: name)
        }
        if tools["DeviceInteractionStartSession"] == nil, let workspaceSession {
            tools["DeviceInteractionStartSession"] = normalized(workspaceSession, name: "DeviceInteractionStartSession")
        }
        for managed in managementTools {
            if let name = toolName(managed) { tools[name] = managed }
        }
        result["tools"] = .array(tools.keys.sorted().compactMap { tools[$0] })
        return .object(result)
    }

    /// Scope and interaction handle values have already been resolved by the broker.
    static func nativeCall(name: String, arguments: [String: JSONValue],
                           nativeCatalog: JSONValue) throws -> (name: String, arguments: [String: JSONValue]) {
        guard !["DeviceInteractionStartWorkspaceSession", "XcodeListWindows", "XcodeMCPKitSelectHost"].contains(name) else {
            throw NativeHostBrokerError("Unknown public tool: \(name)")
        }
        guard case .object(let catalog) = nativeCatalog,
              case .array(let tools)? = catalog["tools"] else {
            throw NativeHostBrokerError("Native catalog has no tools")
        }
        let native: JSONValue?
        if name == "DeviceInteractionStartSession",
           let scopeKey = ["workspaceIdentifier", "tabIdentifier"].first(where: { arguments[$0] != nil }) {
            if let workspaceSession = tools.first(where: { toolName($0) == "DeviceInteractionStartWorkspaceSession" }) {
                native = workspaceSession
            } else if let legacy = tools.first(where: { toolName($0) == name }),
                      inputProperties(legacy)[scopeKey] != nil {
                native = legacy
            } else {
                throw NativeHostBrokerError("Workspace device interaction is unavailable on this Xcode host")
            }
        } else {
            native = tools.first(where: { toolName($0) == name })
        }
        guard let native,
              let nativeName = toolName(native) else {
            throw NativeHostBrokerError("\(name) is unavailable for this workspace's Xcode host")
        }
        var arguments = arguments
        if name == "RenderPreview", arguments["timeout"] == nil {
            arguments["timeout"] = .number(.int(previewTimeout))
        }
        if case .object(let descriptor) = native,
           case .object(let input)? = descriptor["inputSchema"],
           case .object(let properties)? = input["properties"] {
            if name == "DeviceInteractionSynthesize", properties["interactionSessionKey"] == nil,
               properties["interactSessionKey"] != nil,
               let key = arguments.removeValue(forKey: "interactionSessionKey") {
                arguments["interactSessionKey"] = key
            }
            let differingParameters: [String]
            switch name {
            case "DocumentationSearch": differingParameters = ["frameworks"]
            case "DeviceInteractionSynthesize": differingParameters = ["activationBundleId"]
            default: differingParameters = []
            }
            for parameter in differingParameters where arguments[parameter] != nil && properties[parameter] == nil {
                throw NativeHostBrokerError("\(name).\(parameter) is unavailable on this Xcode host")
            }
        }
        return (nativeName, arguments)
    }

    /// Native GUI previews return group indexes; the public contract also supports group titles.
    static func publicPayload(name: String, payload: JSONValue) -> JSONValue {
        guard name == "RenderPreview", case .object(var fields) = payload,
              case .object(var controls)? = fields["supportedCanvasControlOverrides"],
              case .array(let groups)? = controls["groupItems"] else { return payload }
        controls["groupItems"] = .array(groups.map { group in
            if case .number(.int(_)) = group { return .object(["index": group]) }
            return group
        })
        fields["supportedCanvasControlOverrides"] = .object(controls)
        return .object(fields)
    }

    private static func inputProperties(_ tool: JSONValue) -> [String: JSONValue] {
        guard case .object(let fields) = tool, case .object(let input)? = fields["inputSchema"],
              case .object(let properties)? = input["properties"] else { return [:] }
        return properties
    }

    private static func mergedDeviceSession(standalone: JSONValue, workspace: JSONValue) -> JSONValue {
        guard case .object(var fields) = workspace,
              case .object(var workspaceInput)? = fields["inputSchema"],
              case .object(let standaloneFields) = standalone,
              case .object(let standaloneInput)? = standaloneFields["inputSchema"] else { return workspace }
        workspaceInput["properties"] = .object(inputProperties(standalone).merging(inputProperties(workspace)) {
            _, workspaceProperty in workspaceProperty
        })
        let standaloneRequired: [JSONValue]
        let workspaceRequired: [JSONValue]
        if case .array(let values)? = standaloneInput["required"] { standaloneRequired = values }
        else { standaloneRequired = [] }
        if case .array(let values)? = workspaceInput["required"] { workspaceRequired = values }
        else { workspaceRequired = [] }
        // The selected native operation enforces requirements specific to its variant.
        workspaceInput["required"] = .array(workspaceRequired.filter { standaloneRequired.contains($0) })
        fields["inputSchema"] = .object(workspaceInput)
        return .object(fields)
    }

    private static func toolName(_ value: JSONValue) -> String? {
        guard case .object(let fields) = value, case .string(let name)? = fields["name"] else { return nil }
        return name
    }

    private static func normalized(_ value: JSONValue, name: String) -> JSONValue {
        guard case .object(var tool) = value else { return value }
        tool["name"] = .string(name)
        if let description = descriptions[name] { tool["description"] = .string(description) }
        if name == "RenderPreview", case .object(var output)? = tool["outputSchema"],
           case .object(var outputProperties)? = output["properties"],
           case .object(var controls)? = outputProperties["supportedCanvasControlOverrides"],
           case .object(var controlProperties)? = controls["properties"],
           case .object(var groups)? = controlProperties["groupItems"] {
            groups["items"] = schema([
                "index": .object(["type": .string("integer")]),
                "title": .object(["type": .string("string")]),
            ], required: ["index"])
            controlProperties["groupItems"] = .object(groups)
            controls["properties"] = .object(controlProperties)
            outputProperties["supportedCanvasControlOverrides"] = .object(controls)
            if case .object(var snapshot)? = outputProperties["previewSnapshotPath"] {
                snapshot["description"] = .string("Path to the rendered preview image.")
                outputProperties["previewSnapshotPath"] = .object(snapshot)
            }
            output["properties"] = .object(outputProperties)
            tool["outputSchema"] = .object(output)
        }
        guard case .object(var input)? = tool["inputSchema"],
              case .object(var properties)? = input["properties"] else { return .object(tool) }
        var required: [JSONValue]
        if case .array(let values)? = input["required"] { required = values } else { required = [] }
        let scoped = properties.removeValue(forKey: "tabIdentifier") != nil || properties["workspaceIdentifier"] != nil
        required.removeAll { $0 == .string("tabIdentifier") || $0 == .string("workspaceIdentifier") }
        if scoped {
            properties["workspaceIdentifier"] = workspaceProperty
            if !workspaceOptionalTools.contains(name) { required.append(.string("workspaceIdentifier")) }
        }
        if name == "DeviceInteractionStartSession" {
            tool["title"] = .string("Start Device Interaction Session")
            properties["workspaceIdentifier"] = workspaceProperty
            required.removeAll { $0 == .string("deviceIdentifier") }
        }
        if hostSelectableTools.contains(name) {
            properties["hostIdentifier"] = .object([
                "type": .string("string"), "description": .string("Optional host from XcodeMCPKitListHosts; defaults to the terminal's Xcode. A workspace determines its own host."),
            ])
        }
        if name == "DeviceInteractionSynthesize", let key = properties.removeValue(forKey: "interactSessionKey") {
            properties["interactionSessionKey"] = key
            required = required.map { $0 == .string("interactSessionKey") ? .string("interactionSessionKey") : $0 }
        }
        if properties["interactionSessionKey"] != nil {
            properties["interactionSessionKey"] = .object([
                "type": .string("string"), "description": .string("Interaction session key returned by DeviceInteractionStartSession."),
            ])
        }
        if name == "StringCatalogEdit", case .object(var translation)? = properties["translation"] {
            translation["description"] = .string("Translation for a string without variations. Use typographically correct punctuation for the locale.")
            properties["translation"] = .object(translation)
        }
        if name == "RenderPreview", case .object(var timeout)? = properties["timeout"] {
            timeout["default"] = .number(.int(previewTimeout))
            timeout["description"] = .string("Preview timeout in seconds, including build and destination preparation. Defaults to 300.")
            properties["timeout"] = .object(timeout)
        }
        input["properties"] = .object(properties)
        input["required"] = .array(required)
        tool["inputSchema"] = .object(input)
        return .object(tool)
    }

    private static let workspaceProperty: JSONValue = .object([
        "type": .string("string"), "description": .string("Workspace identifier from XcodeListWorkspaces or XcodeOpenWorkspace, or an absolute project/package path to open."),
    ])

    private static let previewTimeout: Int64 = 300

    private static let workspaceOptionalTools: Set<String> = [
        "DeviceInteractionStartSession", "DeviceInteractionInstallAndRun", "GetConsoleOutput",
        "ReadCrashChanges", "GetFieldPerformanceIssueLogs",
        "SyncCrashReports", "GetTopFieldPerformanceIssues",
    ]

    private static let hostSelectableTools: Set<String> = [
        "DeviceInteractionStartSession", "XcodeListTemplates", "XcodeNewProject",
    ]

    private static let descriptions: [String: String] = [
        "AddEntitlement": "Add an entitlement to a target's entitlements file.",
        "AddInfoPlist": "Add or update an Info.plist entry for a target.",
        "BuildProject": "Build the workspace's selected scheme. Set buildForTesting to prepare tests.",
        "DeviceInteractionEndSession": "End the interaction session and release its device resources.",
        "DeviceInteractionInstallAndRun": "Build, install, and launch the app using a workspace interaction session.",
        "DeviceInteractionStartSession": "Start device interaction. Supply workspaceIdentifier to build and run its app, or deviceIdentifier for standalone interaction. End the session when finished.",
        "DeviceInteractionSynthesize": "Send device input and capture UI state using interactionSessionKey.",
        "DocumentationSearch": "Search Apple developer documentation.",
        "GetBuildLog": "Read the latest build log, optionally filtering by severity, file glob, or pattern.",
        "GetConsoleOutput": "Read app console output, optionally filtering by launch session, severity, or pattern.",
        "GetFieldPerformanceIssueLogs": "Retrieve logs for a field performance issue signature.",
        "GetFileCompilerFlags": "Read compiler flags for a file in a target.",
        "GetTargetBuildSettings": "Read a target's build settings.",
        "GetTestList": "List tests for the workspace's selected scheme and test plan.",
        "GetTopFieldPerformanceIssues": "List the app's most frequent field performance issues.",
        "InvokeDebuggerCommand": "Run an LLDB command in the workspace's debugger session.",
        "LocalizationPlanner": "Plan translation work for the requested locale.",
        "RenderPreview": "Render a SwiftUI preview from a source file with optional variant and localization overrides.",
        "RunAllTests": "Run all tests in the selected scheme and test plan.",
        "RunCodeSnippet": "Run a Swift snippet in the context of a source file.",
        "RunProject": "Build and run the selected scheme, optionally attaching the debugger.",
        "RunSomeTests": "Run the specified tests in the workspace.",
        "StopProject": "Stop the workspace's running app.",
        "StringCatalogContext": "Read a string's source values and usage context before translating it.",
        "StringCatalogEdit": "Write a locale's translation or variation into a String Catalog.",
        "StringCatalogRead": "List String Catalog keys and translation counts for a locale, with optional state and pagination filters.",
        "UpdateFileCompilerFlags": "Update compiler flags for a file in a target.",
        "UpdateTargetBuildSetting": "Update a target's build setting.",
        "XcodeGlob": "Find files in the Xcode project using a glob pattern.",
        "XcodeGrep": "Search project files using a regular expression and optional file and context filters.",
        "XcodeGetCurrentFile": "Read the workspace's current file and selection. Content has numbered lines, up to 600 by default.",
        "XcodeLS": "List files in the Xcode project, optionally recursively.",
        "XcodeListRunDestinations": "List run destinations for the selected scheme.",
        "XcodeListSchemes": "List schemes available in the workspace.",
        "XcodeListNavigatorIssues": "List workspace diagnostics, including package and configuration issues.",
        "XcodeListTargets": "List project targets, optionally filtering by product type.",
        "XcodeListTemplates": "List Xcode project and target templates.",
        "XcodeListTestPlans": "List test plans for the selected scheme.",
        "XcodeMV": "Move or copy a file within the Xcode project organization.",
        "XcodeMakeDir": "Create a directory in the Xcode project.",
        "XcodeNewProject": "Create a project from an Xcode template.",
        "XcodeNewTarget": "Add a target to a project using an Xcode template.",
        "XcodeRM": "Remove a project reference, optionally deleting files from disk.",
        "XcodeRead": "Read a project file with numbered lines. Defaults to up to 600 lines; use offset and limit for larger files.",
        "XcodeRefreshCodeIssuesInFile": "Refresh compiler diagnostics for a project source file.",
        "XcodeSwitchRunDestination": "Select a run destination by its display title.",
        "XcodeSwitchScheme": "Select a workspace scheme.",
        "XcodeSwitchTestPlan": "Select a test plan for the active scheme.",
        "XcodeUpdate": "Replace text in a project file; replaceAll controls whether all matches change.",
        "XcodeWrite": "Write a project file and add it to the Xcode project organization.",
    ]

    private static func schema(_ properties: [String: JSONValue], required: [String]) -> JSONValue {
        .object(["type": .string("object"), "properties": .object(properties),
                 "required": .array(required.map(JSONValue.string))])
    }
}
