# Maintainer Architecture

## Module Layout

- `ProxyCore`
  - CLI/config parsing, discovery file handling, logging, small shared helpers.
- `ProxyMCP`
  - JSON-RPC / MCP value types, stdio framing, timeout dispatch, request inspection.
- `ProxySession`
  - Session lifecycle, initialize handshake, upstream process pool, leases, routing.
- `ProxyXcodeSupport`
  - Xcode window inspection and permission-dialog auto approval.
- `ProxyXcodeFeatures`
  - `XcodeRefreshCodeIssuesInFile` planning, target resolution, queueing, tool-list rewriting.
- `ProxyHTTPGateway`
  - HTTP/SSE request handling, local MCP responses, forwarding, batch orchestration.
- `ProxyStdioTransport`
  - STDIO adapter that forwards through the HTTP/SSE proxy.
- `XcodeMCPProxy`
  - Composition root only.

## Dependency Direction

- `ProxyCore` must not depend on gateway/session/Xcode modules.
  - Current exception: config handshake shaping reuses `ProxyMCP` JSON value types.
- `ProxyMCP` may depend only on `ProxyCore`-level primitives conceptually; avoid introducing gateway/session/Xcode knowledge.
- `ProxySession` depends on `ProxyCore` and `ProxyMCP`.
- `ProxyXcodeSupport` depends on `ProxyCore`.
- `ProxyXcodeFeatures` depends on `ProxyCore`, `ProxyMCP`, and `ProxyXcodeSupport`.
- `ProxyHTTPGateway` is the highest-level internal target and may depend on the lower-level targets above.
- `ProxyCLI` depends on `XcodeMCPProxy` only.

Run `scripts/check-architecture.sh` after moving files or changing imports.

## Local Verification

- Fast regression suite:
  - `scripts/test-fast.sh`
- Process / pipe suite:
  - `scripts/test-process.sh`
- Full local maintainer check:
  - `scripts/check.sh`

These mirror the existing release workflow split and intentionally avoid requiring real `mcpbridge`.

## Live `mcpbridge` Suite

- Entry point:
  - `scripts/test-live-mcpbridge.sh`
- Purpose:
  - Validate the real `mcpbridge` path, `tools/list`, `XcodeListWindows`, `XcodeRefreshCodeIssuesInFile`, and proxy auto-approve behavior in a local-only environment.
- Isolation rules:
  - Uses the currently running Xcode session and requires exactly one Xcode process.
  - Uses `127.0.0.1:0`.
  - Uses `XCODE_MCP_PROXY_DISCOVERY_FILE` so the default discovery path is untouched.
  - Avoids `--force-restart`.
  - Reads the active workspace from `XcodeListWindows` and refreshes an existing Swift file without opening a new project.

## Cleanup Expectations

- Live runs must terminate the dedicated proxy server and Xcode process they start.
- Live runs must write discovery output only under their temp root.
- Do not rely on the user’s default `~/Library/Caches/XcodeMCPProxy/endpoint.json` during tests.
