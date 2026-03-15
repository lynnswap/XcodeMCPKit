import Foundation
import NIO

package struct XcodeWindowQueryService {
    package typealias ToolCaller =
        @Sendable (_ name: String, _ arguments: [String: Any], _ sessionID: String, _ eventLoop: EventLoop) async -> [String: Any]?

    package init() {}

    package func listWindows(
        sessionID: String,
        eventLoop: EventLoop,
        toolCaller: ToolCaller
    ) async -> [XcodeWindowInfo]? {
        guard let result = await toolCaller("XcodeListWindows", [:], sessionID, eventLoop),
            let message = extractToolMessage(from: result)
        else {
            return nil
        }
        return parseXcodeListWindowsMessage(message)
    }

    package func extractToolMessage(from result: [String: Any]) -> String? {
        if let structuredContent = result["structuredContent"] as? [String: Any],
            let message = structuredContent["message"] as? String,
            message.isEmpty == false
        {
            return message
        }

        guard let content = result["content"] as? [[String: Any]] else {
            return nil
        }
        for item in content {
            guard let text = item["text"] as? String, text.isEmpty == false else {
                continue
            }
            if let textData = text.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: textData, options: []) as? [String: Any],
                let message = object["message"] as? String
            {
                return message
            }
            return text
        }
        return nil
    }

    package func parseXcodeListWindowsMessage(_ message: String) -> [XcodeWindowInfo] {
        message
            .split(separator: "\n")
            .compactMap { line -> XcodeWindowInfo? in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.hasPrefix("* tabIdentifier: ") else { return nil }
                let parts = trimmed.components(separatedBy: ", workspacePath: ")
                guard parts.count == 2 else { return nil }
                let tabIdentifier = parts[0]
                    .replacingOccurrences(of: "* tabIdentifier: ", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let workspacePath = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                guard tabIdentifier.isEmpty == false, workspacePath.isEmpty == false else {
                    return nil
                }
                return XcodeWindowInfo(
                    tabIdentifier: tabIdentifier,
                    workspacePath: workspacePath
                )
            }
    }
}
