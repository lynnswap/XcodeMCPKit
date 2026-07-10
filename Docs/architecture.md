# XcodeMCPProxy Architecture

## Summary
- `xcode-mcp-proxy-server` runs as the proxy server (Streamable HTTP; spawns `xcrun mcpbridge`).
- HTTP-capable MCP clients connect directly to the proxy server (default: `http://localhost:8765/mcp`).
- `xcode-mcp-proxy` remains as a supported STDIO compatibility adapter, forwarding to the proxy server as a modern Streamable HTTP client.
- The proxy targets MCP protocol version `2025-06-18`, matching current Xcode `mcpbridge` negotiation.
- Each HTTP request carries exactly one JSON-RPC object. JSON-RPC batch arrays are rejected at the HTTP boundary without downstream side effects.

## Diagrams

### Proxy Server (Streamable HTTP)
```mermaid
flowchart LR
  subgraph Clients["MCP clients (multiple)"]
    direction TB
    clientA(["Client A"])
    clientB(["Client B"])
    clientN(["Client N"])
  end
  proxy["xcode-mcp-proxy-server<br/>Streamable HTTP"]
  subgraph Upstreams["Upstream (mcpbridge pool)"]
    direction TB
    upstream1(["xcrun mcpbridge #1<br/>stdio JSON-RPC"])
    upstream2(["xcrun mcpbridge #2<br/>stdio JSON-RPC"])
    upstreamN(["xcrun mcpbridge #N<br/>stdio JSON-RPC"])
  end
  xcode["Xcode MCP server"]

  clientA -->|POST/GET/DELETE /mcp| proxy
  clientB -->|POST/GET/DELETE /mcp| proxy
  clientN -->|POST/GET/DELETE /mcp| proxy
  proxy -->|stdio JSON-RPC| upstream1
  proxy -->|stdio JSON-RPC| upstream2
  proxy -->|stdio JSON-RPC| upstreamN
  upstream1 <--> |MCP bridge| xcode
  upstream2 <--> |MCP bridge| xcode
  upstreamN <--> |MCP bridge| xcode
```

### STDIO Adapter (Optional)
```mermaid
flowchart LR
  subgraph A["Client Process A"]
    clientA(["Codex / Claude Code A"])
    adapterA["xcode-mcp-proxy A<br/>STDIO adapter"]
    clientA -->|NDJSON over STDIO| adapterA
  end

  subgraph B["Client Process B"]
    clientB(["Codex / Claude Code B"])
    adapterB["xcode-mcp-proxy B<br/>STDIO adapter"]
    clientB -->|NDJSON over STDIO| adapterB
  end

  proxy["xcode-mcp-proxy-server<br/>Streamable HTTP"]
  subgraph Upstreams["Upstream (mcpbridge pool)"]
    direction TB
    upstream1(["xcrun mcpbridge #1<br/>stdio JSON-RPC"])
    upstream2(["xcrun mcpbridge #2<br/>stdio JSON-RPC"])
    upstreamN(["xcrun mcpbridge #N<br/>stdio JSON-RPC"])
  end
  xcode["Xcode MCP server"]

  adapterA -->|POST/GET/DELETE /mcp| proxy
  adapterB -->|POST/GET/DELETE /mcp| proxy
  proxy -->|stdio JSON-RPC| upstream1
  proxy -->|stdio JSON-RPC| upstream2
  proxy -->|stdio JSON-RPC| upstreamN
  upstream1 <--> |MCP bridge| xcode
  upstream2 <--> |MCP bridge| xcode
  upstreamN <--> |MCP bridge| xcode
```

## Ports and Addressing
- `xcode-mcp-proxy-server` binds to `localhost:8765` by default (override via `--listen` / `--host` / `--port`, or env `LISTEN` / `HOST` / `PORT`).
- The proxy server writes the resolved endpoint to `~/Library/Caches/XcodeMCPProxy/endpoint.json`.
- `xcode-mcp-proxy` (STDIO adapter) resolves the upstream in this order:
  - explicit URL/config, such as CLI `--url`
  - `XCODE_MCP_PROXY_ENDPOINT`
  - discovery file (`~/Library/Caches/XcodeMCPProxy/endpoint.json`)
  - fallback default (`http://localhost:8765/mcp`)

## Streamable HTTP Contract
- Every request is checked by one Origin policy before route resolution, session creation, debug reset, or upstream I/O. This includes `/health`, `/debug/*`, MCP routes, and unknown routes.
- A missing `Origin` header is allowed for non-browser clients. When `Origin` is present it must be one valid HTTP(S) origin whose host and port match the actual listener policy; empty, multiple, `null`, malformed, and cross-origin values return `403`.
- `POST /mcp` requires `Content-Type: application/json` and `Accept` containing both `application/json` and `text/event-stream`.
- The server generates `MCP-Session-Id` on `initialize`; caller-provided session ids are ignored for initialize.
- After initialize, `POST`, `GET`, and `DELETE` require `MCP-Session-Id`. An explicit `MCP-Protocol-Version` must be valid, supported, and match the negotiated version.
- When `MCP-Protocol-Version` is omitted, the server uses the session's negotiated version. If no negotiated version exists, it evaluates the protocol-defined fallback `2025-03-26` and returns `400` when that version is unsupported.
- Missing session ids return `400`; unknown or terminated session ids return `404`.
- `DELETE /mcp` terminates the session; later requests with that session id return `404`.
- Empty, singleton, and mixed JSON-RPC arrays return `400`; the internal executor and response router operate on typed single messages. An array response from an upstream is a protocol violation.
- When a session's SSE notification buffer overflows, the session owner increments its dropped-notification counter and emits a rate-limited warning. Unhandled server notifications remain debug-level events.

## Discovery Contract

- The discovery record is a URL hint, not proof that a server is reachable. PID liveness is not used as a second source of truth.
- Reachability is established only by connecting to the endpoint and completing the standard initialize handshake.
- When discovery is enabled, writing the record is part of server startup. A write failure unwinds listener/runtime resources and makes startup fail.
