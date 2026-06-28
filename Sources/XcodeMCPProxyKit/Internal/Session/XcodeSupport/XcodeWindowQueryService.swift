import Foundation
import NIO

struct XcodeWindowQueryService {
    typealias ToolCaller =
        @Sendable (_ name: String, _ arguments: [String: Any], _ sessionID: String, _ eventLoop: EventLoop) async throws -> [String: Any]?

    init() {}

    func listWindows(
        sessionID: String,
        eventLoop: EventLoop,
        toolCaller: ToolCaller
    ) async throws -> [XcodeWindowInfo]? {
        guard let result = try await toolCaller("XcodeListWindows", [:], sessionID, eventLoop),
            let message = extractToolMessage(from: result)
        else {
            return nil
        }
        return parseXcodeListWindowsMessage(message)
    }

    func extractToolMessage(from result: [String: Any]) -> String? {
        if let structuredContent = result["structuredContent"] as? [String: Any],
            let message = structuredContent["message"] as? String,
            message.isEmpty == false
        {
            return message
        }

        guard let content = result["content"] as? [[String: Any]] else {
            return nil
        }
        var fallbackText: String?
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
            if fallbackText == nil {
                fallbackText = text
            }
        }
        return fallbackText
    }

    func parseWindowsResult(_ result: Any) -> [XcodeWindowInfo]? {
        guard let object = result as? [String: Any],
            let message = extractToolMessage(from: object)
        else {
            return nil
        }
        return parseXcodeListWindowsMessage(message)
    }

    func parseXcodeListWindowsMessage(_ message: String) -> [XcodeWindowInfo] {
        XcodeListWindowsMessageParser.parse(message)
            .map { entry in
                XcodeWindowInfo(
                    tabIdentifier: entry.tabIdentifier,
                    workspacePath: entry.workspacePath
                )
            }
    }
}
