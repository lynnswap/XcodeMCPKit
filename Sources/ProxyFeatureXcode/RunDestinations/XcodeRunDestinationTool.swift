import Foundation
import ProxyCore

package enum XcodeRunDestinationTool {
    package static let listName = "XcodeListRunDestinations"
    package static let setName = "XcodeSetActiveRunDestination"

    package static func definitions() -> [JSONValue] {
        [
            listToolDefinition(),
            setToolDefinition(),
        ]
    }

    package static func isLocalTool(named name: String) -> Bool {
        name == listName || name == setName
    }

    private static func listToolDefinition() -> JSONValue {
        .object([
            "name": .string(listName),
            "description": .string(
                """
                Lists Xcode run destinations for a workspace tab, grouped by normalized platform and available OS versions. Use this before selecting a run destination via Xcode scripting.
                """
            ),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object([
                    "tabIdentifier": .object([
                        "type": .string("string"),
                        "description": .string("Workspace tab identifier from XcodeListWindows."),
                    ])
                ]),
                "required": .array([.string("tabIdentifier")]),
                "additionalProperties": .bool(false),
            ]),
        ])
    }

    private static func setToolDefinition() -> JSONValue {
        .object([
            "name": .string(setName),
            "description": .string(
                """
                Selects Xcode's active run destination for a workspace tab using Xcode scripting. Matches by normalized platform, exact OS version, and optional device family. This does not restore the previous destination.
                """
            ),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object([
                    "tabIdentifier": .object([
                        "type": .string("string"),
                        "description": .string("Workspace tab identifier from XcodeListWindows."),
                    ]),
                    "platform": .object([
                        "type": .string("string"),
                        "description": .string("Normalized platform id from XcodeListRunDestinations, such as ios-simulator or macos."),
                    ]),
                    "osVersion": .object([
                        "type": .string("string"),
                        "description": .string("Exact operating system version from XcodeListRunDestinations. Omit this only for destinations that do not report an OS version."),
                    ]),
                    "deviceFamily": .object([
                        "type": .string("string"),
                        "description": .string("Optional device family from XcodeListRunDestinations, such as iphone or ipad."),
                    ]),
                ]),
                "required": .array([
                    .string("tabIdentifier"),
                    .string("platform"),
                ]),
                "additionalProperties": .bool(false),
            ]),
        ])
    }
}

package struct XcodeListRunDestinationsRequest: Sendable, Equatable {
    package let tabIdentifier: String?
}

package struct XcodeSetActiveRunDestinationRequest: Sendable, Equatable {
    package let tabIdentifier: String?
    package let platform: String?
    package let osVersion: String?
    package let deviceFamily: String?
}

package enum XcodeRunDestinationToolRequest: Sendable, Equatable {
    case list(XcodeListRunDestinationsRequest)
    case set(XcodeSetActiveRunDestinationRequest)

    package static func parse(from requestJSON: Any) -> XcodeRunDestinationToolRequest? {
        guard let object = requestJSON as? [String: Any],
            let method = object["method"] as? String,
            method == "tools/call",
            let params = object["params"] as? [String: Any],
            let toolName = params["name"] as? String
        else {
            return nil
        }
        let arguments = params["arguments"] as? [String: Any] ?? [:]

        switch toolName {
        case XcodeRunDestinationTool.listName:
            return .list(
                XcodeListRunDestinationsRequest(
                    tabIdentifier: arguments["tabIdentifier"] as? String
                )
            )
        case XcodeRunDestinationTool.setName:
            return .set(
                XcodeSetActiveRunDestinationRequest(
                    tabIdentifier: arguments["tabIdentifier"] as? String,
                    platform: arguments["platform"] as? String,
                    osVersion: arguments["osVersion"] as? String,
                    deviceFamily: arguments["deviceFamily"] as? String
                )
            )
        default:
            return nil
        }
    }
}
