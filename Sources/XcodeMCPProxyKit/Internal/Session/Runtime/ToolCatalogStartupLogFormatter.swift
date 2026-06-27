import Foundation
import XcodeMCPCore
import XcodeMCPProcessRuntime
import XcodeMCPProxyRuntime

package enum ToolCatalogStartupLogFormatter {
    package struct Process: Sendable, Equatable {
        package let appPath: String
        package let processID: pid_t

        package init(appPath: String, processID: pid_t) {
            self.appPath = appPath
            self.processID = processID
        }
    }

    package static func summary(
        from result: JSONValue,
        process: Process? = nil,
        exposurePolicy: String? = nil
    ) -> String {
        let names = toolNames(in: result)
        let details = detailsLines(for: names, indent: process == nil ? "  " : "    ")
        let policyLines = exposurePolicy.map { ["  Exposure: \($0)"] } ?? []

        guard let process else {
            return (["Tools"] + policyLines + details).joined(separator: "\n")
        }

        return (
            [
                "Tools",
            ] + policyLines + [
                "  - \(process.appPath) (PID: \(process.processID))",
            ] + details
        ).joined(separator: "\n")
    }

    private static func detailsLines(for names: [String], indent: String) -> [String] {
        let documentationSearchStatus =
            names.contains(DocumentationProvider.ToolCatalog.toolName)
            ? "available"
            : "unavailable"
        let availableNames = names.isEmpty ? ["none"] : names

        var lines = [
            "\(indent)DocumentationSearch: \(documentationSearchStatus)",
            "\(indent)Count: \(names.count)",
            "\(indent)Available:",
        ]
        lines.append(contentsOf: availableNames.map { "\(indent)  - \($0)" })
        return lines
    }

    private static func toolNames(in result: JSONValue) -> [String] {
        guard case .object(let object) = result,
              case .array(let tools)? = object["tools"] else {
            return []
        }

        let names = tools.compactMap { tool -> String? in
            guard case .object(let toolObject) = tool,
                  case .string(let name)? = toolObject["name"] else {
                return nil
            }
            return name
        }

        return Array(Set(names)).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }
}
