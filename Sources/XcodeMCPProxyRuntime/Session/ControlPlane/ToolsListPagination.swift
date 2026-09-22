import XcodeMCPKit

struct ToolsListPagination {
    private(set) var nextCursor: String?
    private var seenCursors: Set<String> = []
    private var tools: [JSONValue] = []
    private var firstPage: [String: JSONValue]?

    mutating func append(_ result: JSONValue) throws {
        guard case .object(let page) = result,
              case .array(let pageTools)? = page["tools"] else {
            throw ControlPlane.Error.invalidResponse("invalid tools/list result")
        }
        if firstPage == nil { firstPage = page }
        tools.append(contentsOf: pageTools)
        if let cursor = page["nextCursor"] {
            guard case .string(let next) = cursor else {
                throw ControlPlane.Error.invalidResponse("invalid tools/list nextCursor")
            }
            guard seenCursors.insert(next).inserted else {
                throw ControlPlane.Error.invalidResponse("tools/list cursor cycle")
            }
            nextCursor = next
        } else {
            nextCursor = nil
        }
    }

    var result: JSONValue {
        var catalog = firstPage ?? [:]
        catalog["tools"] = .array(tools)
        catalog.removeValue(forKey: "nextCursor")
        return .object(catalog)
    }
}
