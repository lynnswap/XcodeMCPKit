import Foundation
import XcodeMCPCore

enum ToolCatalogStartupLogFormatter {
    static func summary(from result: JSONValue) -> String {
        (["Tools"] + detailsLines(for: toolNames(in: result), indent: "  ")).joined(separator: "\n")
    }

    private static func detailsLines(for names: [String], indent: String) -> [String] {
        let documentationSearchStatus =
            names.contains("DocumentationSearch")
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
