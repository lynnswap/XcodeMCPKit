import NIOHTTP1

package enum HTTPRoute {
    case health
    case debugSnapshot
    case sse
    case deleteSession
    case post
    case notFound

    package static func resolve(method: HTTPMethod, path: String) -> Self {
        switch (method, path) {
        case (.GET, "/health"):
            .health
        case (.GET, "/debug/upstreams"):
            .debugSnapshot
        case (.GET, "/mcp"), (.GET, "/"), (.GET, "/mcp/events"), (.GET, "/events"):
            .sse
        case (.DELETE, "/mcp"), (.DELETE, "/"):
            .deleteSession
        case (.POST, "/mcp"), (.POST, "/"):
            .post
        default:
            .notFound
        }
    }
}
