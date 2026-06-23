import Foundation
import Logging
import ProxyCore
import ProxyMCP

extension RuntimeCoordinator {
    package func liveXcodeListWindowsAcrossProcessRoutes(
        deadlineUptimeNs: UInt64?
    ) async throws -> JSONValue {
        var results: [JSONValue] = []
        var lastError: (any Error)?

        for route in xcodeProcessRoutes {
            guard let upstreamIndex = route.primaryUpstreamIndex else {
                continue
            }
            do {
                let result = try await awaitControlPlaneOperation {
                    try await self.controlPlaneCoordinator.listWindows(
                        route: .pinnedUpstream(upstreamIndex),
                        deadlineUptimeNs: deadlineUptimeNs
                    )
                }
                recordXcodeWindowOwners(from: result, upstreamIndex: upstreamIndex)
                results.append(result)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                logger.debug(
                    "XcodeListWindows process route failed",
                    metadata: [
                        "pid": .string("\(route.target.processID)"),
                        "upstream": .string("\(upstreamIndex)"),
                        "error": .string(String(describing: error)),
                    ]
                )
            }
        }

        if let merged = Self.mergedXcodeListWindowsResult(results) {
            return merged
        }
        if let lastError {
            throw lastError
        }
        throw UpstreamSlotScheduler.AcquisitionError.unavailable
    }

    package func primaryUpstreamIndex(forXcodeProcessID processID: pid_t) -> Int? {
        xcodeProcessRoutes.first { $0.target.processID == processID }?.primaryUpstreamIndex
    }

    package func preferredUpstreamIndex(for requestJSON: Any) -> Int? {
        guard xcodeProcessRoutes.isEmpty == false else {
            return nil
        }
        let indices = preferredUpstreamIndices(in: requestJSON)
        guard indices.count == 1 else {
            return nil
        }
        return indices.first
    }

    package func recordXcodeWindowOwners(
        from result: JSONValue,
        upstreamIndex: Int
    ) {
        let entries = Self.windowEntries(in: result)
        guard entries.isEmpty == false else {
            return
        }
        tabOwnerUpstreamIndices.withLockedValue { owners in
            for entry in entries {
                owners[entry.tabIdentifier] = upstreamIndex
            }
        }
        workspaceOwnerUpstreamIndices.withLockedValue { owners in
            for entry in entries {
                owners[entry.workspacePath] = upstreamIndex
            }
        }
    }

    package static func mergedXcodeListWindowsResult(
        _ results: [JSONValue]
    ) -> JSONValue? {
        let messages = results.compactMap(Self.xcodeListWindowsMessage(in:))
            .filter { $0.isEmpty == false }
        guard messages.isEmpty == false else {
            return results.first
        }
        let message = messages.joined(separator: "\n")
        let encodedMessage: String
        if let data = try? JSONSerialization.data(
            withJSONObject: ["message": message],
            options: [.sortedKeys]
        ) {
            encodedMessage = String(decoding: data, as: UTF8.self)
        } else {
            encodedMessage = message
        }
        return .object([
            "content": .array([
                .object([
                    "type": .string("text"),
                    "text": .string(encodedMessage),
                ]),
            ]),
            "structuredContent": .object([
                "message": .string(message),
            ]),
        ])
    }

    private func preferredUpstreamIndices(in value: Any) -> Set<Int> {
        if let object = value as? [String: Any] {
            return Set(preferredUpstreamIndex(in: object).map { [$0] } ?? [])
        }
        guard let array = value as? [Any] else {
            return []
        }
        return array.reduce(into: Set<Int>()) { result, item in
            for upstreamIndex in preferredUpstreamIndices(in: item) {
                result.insert(upstreamIndex)
            }
        }
    }

    private func preferredUpstreamIndex(in object: [String: Any]) -> Int? {
        guard JSONRPC.Message.Inspector.method(from: object) == "tools/call",
              let params = object["params"] as? [String: Any],
              let arguments = params["arguments"] as? [String: Any] else {
            return nil
        }
        if let tabIdentifier = arguments["tabIdentifier"] as? String,
           tabIdentifier.isEmpty == false,
           let upstreamIndex = tabOwnerUpstreamIndices.withLockedValue({ $0[tabIdentifier] })
        {
            return upstreamIndex
        }
        if let workspacePath = arguments["workspacePath"] as? String,
           workspacePath.isEmpty == false,
           let upstreamIndex = workspaceOwnerUpstreamIndices.withLockedValue({ $0[workspacePath] })
        {
            return upstreamIndex
        }
        return nil
    }

    private static func windowEntries(in result: JSONValue) -> [XcodeListWindowsEntry] {
        guard let message = xcodeListWindowsMessage(in: result) else {
            return []
        }
        return XcodeListWindowsMessageParser.parse(message)
    }

    private static func xcodeListWindowsMessage(in result: JSONValue) -> String? {
        guard case .object(let object) = result else {
            return nil
        }
        if case .object(let structuredContent)? = object["structuredContent"],
           case .string(let message)? = structuredContent["message"],
           message.isEmpty == false
        {
            return message
        }
        guard case .array(let content)? = object["content"] else {
            return nil
        }
        var fallbackText: String?
        for item in content {
            guard case .object(let contentObject) = item,
                  case .string(let text)? = contentObject["text"],
                  text.isEmpty == false else {
                continue
            }
            if let textData = text.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: textData, options: []) as? [String: Any],
               let message = json["message"] as? String,
               message.isEmpty == false
            {
                return message
            }
            if fallbackText == nil {
                fallbackText = text
            }
        }
        return fallbackText
    }

}
