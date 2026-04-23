import Foundation
import NIO

package struct XcodeWindowQueryService {
    package typealias ToolCaller =
        @Sendable (_ name: String, _ arguments: [String: Any], _ sessionID: String, _ eventLoop: EventLoop) async throws -> [String: Any]?

    package init() {}

    package func listWindows(
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

    package func parseXcodeListWindowsMessage(_ message: String) -> [XcodeWindowInfo] {
        message
            .split(separator: "\n")
            .compactMap { line -> XcodeWindowInfo? in
                var rawLine = String(line)
                if rawLine.hasSuffix("\r") {
                    rawLine.removeLast()
                }
                rawLine.removeLeadingWhitespace()
                let prefix = "* tabIdentifier: "
                guard rawLine.hasPrefix(prefix) else { return nil }
                let delimiter = ", workspacePath: "
                let searchStart = rawLine.index(rawLine.startIndex, offsetBy: prefix.count)
                guard let delimiterRange = rawLine.range(
                    of: delimiter,
                    options: [],
                    range: searchStart..<rawLine.endIndex
                ) else {
                    return nil
                }
                let tabIdentifier = String(rawLine[searchStart..<delimiterRange.lowerBound])
                let workspacePath = String(rawLine[delimiterRange.upperBound...])
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

private extension String {
    mutating func removeLeadingWhitespace() {
        let trimmedStart = drop { $0 == " " || $0 == "\t" }
        if trimmedStart.startIndex != startIndex {
            self = String(trimmedStart)
        }
    }
}
