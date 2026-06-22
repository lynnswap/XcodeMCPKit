import Foundation
import ProxyMCP

package enum ToolCatalogStartupLogFormatter {
    package static func summary(from result: JSONValue) -> String {
        let names = toolNames(in: result)
        let documentationSearchStatus =
            names.contains(DocumentationProvider.ToolCatalog.toolName)
            ? "available"
            : "unavailable"

        var lines = [
            "Tools",
            "  DocumentationSearch: \(documentationSearchStatus)",
            "  Count: \(names.count)",
            "  Available:",
        ]

        if names.isEmpty {
            lines.append("    - none")
        } else {
            for name in names {
                lines.append("    - \(name)")
            }
        }

        return lines.joined(separator: "\n")
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
