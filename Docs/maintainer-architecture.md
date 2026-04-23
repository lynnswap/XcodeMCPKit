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

## Ownership Boundaries

- `ProxySession`
  - Owns client sessions, cached initialize state, canonical tools catalog, control-plane waiters, upstream routing, and lease cleanup.
- `ProxyHTTPGateway`
  - Owns request/response transport concerns only.
  - Tool-specific response shaping lives in dedicated surface helpers, not inline in forwarding hot paths.
- `ProxyXcodeFeatures`
  - Owns refresh workflow and other Xcode-specific feature logic.

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

## Protocol Boundaries

- `stdout`
  - Protocol payloads only. Do not send logs or debug text here.
- `stderr`
  - Human-readable logging only.
- HTTP request bodies
  - Parse once per request and pass the parsed payload through forwarding/local handling; do not re-parse in hot-path helpers unless the payload is synthesized internally.
- Canonical cache invalidation
  - Synchronous cache clear is allowed before async control-plane cleanup when stale fast paths would otherwise leak invalid state.

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

## Review Checklist

- `stdout` is never used for logging or debug formatting.
- Shared state accessed across callbacks/tasks is either actor-isolated or explicitly synchronized.
- Request parsing is not duplicated on the hot path.
- Bind/start/stop failure paths clean up listeners, timers, and child tasks.
- Canonical initialize/tools cache cannot survive upstream exit/quarantine/eager retry windows.
- New feature code does not add tool-specific branching to forwarding when a dedicated helper/workflow can own it instead.
