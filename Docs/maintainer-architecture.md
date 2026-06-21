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
  - Streamable HTTP request handling, transport validation, local MCP responses, forwarding.
- `ProxyStdioTransport`
  - STDIO compatibility adapter that forwards through the Streamable HTTP proxy.
- `XcodeMCPProxy`
  - Composition root only.

## Ownership Boundaries

- `ProxySession`
  - Owns client sessions, cached initialize state, canonical tools catalog, control-plane waiters, upstream routing, and lease cleanup.
- `ProxyHTTPGateway`
  - Owns HTTP transport validation, server-issued session ids, protocol-version enforcement, and request/response transport concerns.
  - Rejects JSON-RPC batch arrays at the HTTP boundary.
  - Tool-specific response shaping lives in dedicated surface helpers, not inline in forwarding hot paths.
- `ProxyXcodeFeatures`
  - Owns refresh workflow and other Xcode-specific feature logic.

## Dependency Direction

- `ProxyCore` must not depend on gateway/session/Xcode modules.
- `ProxyMCP` depends on `ProxyCore` for shared protocol primitives and extends the `MCP` namespace for JSON-RPC / MCP helpers.
  Avoid introducing gateway/session/Xcode knowledge here.
- `ProxySession` depends on `ProxyCore` and `ProxyMCP`.
- `ProxyXcodeSupport` depends on `ProxyCore`.
- `ProxyXcodeFeatures` depends on `ProxyCore`, `ProxyMCP`, and `ProxyXcodeSupport`.
- `ProxyHTTPGateway` is the highest-level internal target and may depend on the lower-level targets above.
- `ProxyCLI` depends on `XcodeMCPProxy` only.

Run `swift test -Xswiftc -strict-concurrency=minimal` after moving files or changing imports;
the default suite includes `ProxyArchitectureTests`.

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
  - `swift test -Xswiftc -strict-concurrency=minimal`
- Process / pipe suite:
  - `XCODE_MCP_RUN_PROCESS_TESTS=1 swift test --no-parallel --filter ProxyProcessTests -Xswiftc -strict-concurrency=minimal`
- Full local maintainer check:
  - `scripts/check.sh`

These are used by the default CI workflow and release verification, and intentionally avoid requiring real `mcpbridge`.

## Release Flow

- Entry point:
  - `scripts/publish-local-release.sh v1.2.3`
- Behavior:
  - Builds the arm64 archive, `SHA256SUMS.txt`, and `install.sh` locally.
  - Pushes the release tag from `main`.
  - Creates a draft GitHub Release.
  - Dispatches `.github/workflows/release.yml` for the tag ref.
  - The workflow publishes the draft only after `scripts/check.sh` and release asset verification pass.
- Distribution:
  - GitHub Releases publish `install.sh`, `xcode-mcp-proxy-darwin-arm64.tar.gz`, and `SHA256SUMS.txt`.
  - x86_64 and universal archives are not produced.

## Stress Suite

- In-process entry point:
  - `XCODE_MCP_RUN_STRESS_TESTS=1 swift test --no-parallel --filter ProxyStressTests -Xswiftc -strict-concurrency=minimal`
- Purpose:
  - Validate high-volume HTTP/session multiplexing without a live `mcpbridge`.
- Isolation rules:
  - Opt-in only; excluded from default `swift test`, `scripts/check.sh`, and CI.
  - Uses an in-process HTTP server and fake upstream.
  - Current coverage opens 4 MCP sessions and sends 1,000 parallel `DocumentationSearch` calls per session.

### Running Server Benchmark

- Entry point:
  - `python3 scripts/benchmark-live-server.py --agents 4 --requests-per-agent 100`
- Purpose:
  - Benchmark an already-running `xcode-mcp-proxy-server` with real `DocumentationSearch` calls.
- Isolation rules:
  - Manual-only; excluded from default `swift test`, `scripts/check.sh`, and CI.
  - Resolves the endpoint from `--endpoint`, `XCODE_MCP_PROXY_ENDPOINT`, discovery file, then `http://localhost:8765/mcp`.
  - Rejects non-loopback endpoints by default; `--allow-non-loopback` is required to benchmark a remote endpoint.
  - Defaults to 4 agents, each represented by one persistent HTTP connection and one MCP session.
  - Each agent sends 100 `DocumentationSearch` requests in a closed loop, then reports throughput and per-request latency percentiles.
  - Deletes benchmark MCP sessions before exit.

## Live `mcpbridge` Suite

- Entry point:
  - `XCODE_MCP_RUN_LIVE_MCPBRIDGE_TESTS=1 swift test --no-parallel --filter ProxyLiveMCPBridgeTests -Xswiftc -strict-concurrency=minimal`
- Purpose:
  - Validate the real `mcpbridge` path, `tools/list`, `XcodeListWindows`, `XcodeRefreshCodeIssuesInFile`, and proxy auto-approve behavior in a local-only environment.
- Isolation rules:
  - Uses the currently running Xcode session and requires exactly one Xcode process.
  - Uses `127.0.0.1:0`.
  - Uses a temp discovery file so the default discovery path is untouched.
  - Avoids `--force-restart`.
  - Reads the active workspace from `XcodeListWindows` and refreshes an existing Swift file without opening a new project.

## Cleanup Expectations

- Live runs must terminate the dedicated in-process proxy server.
- Live runs must write discovery output only under their temp root.
- Do not rely on the user’s default `~/Library/Caches/XcodeMCPProxy/endpoint.json` during tests.

## Review Checklist

- `stdout` is never used for logging or debug formatting.
- Shared state accessed across callbacks/tasks is either actor-isolated or explicitly synchronized.
- Request parsing is not duplicated on the hot path.
- Bind/start/stop failure paths clean up listeners, timers, and child tasks.
- Canonical initialize/tools cache cannot survive upstream exit/quarantine/eager retry windows.
- New feature code does not add tool-specific branching to forwarding when a dedicated helper/workflow can own it instead.
