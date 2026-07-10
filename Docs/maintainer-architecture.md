# Maintainer Architecture

## Module Layout

- `XcodeMCPKit`
  - Public client SDK facade and MCP value types.
  - Package-scoped `MCPClientSessionAuthority` owns transport recipes,
    connection identity, HTTP session recovery, connection state, and close
    completion for both the direct SDK and the proxy STDIO adapter.
  - `InitializedMCPClientSession` owns request IDs, response correlation, and
    request-scoped progress lanes; it does not own transport/session lifecycle.
- `XcodeMCPProxyKit`
  - Public server/adapter embedding facades plus internal HTTP gateway, proxy
    control plane, Xcode routing, upstream topology, discovery, permission
    automation, and feature workflows.
  - CLI composition, installer implementation, build metadata, and launch
    diagnostics are package/executable concerns rather than public library API.

## Ownership Boundaries

- `ProcessControlPlaneAuthority`
  - Owns route membership/exposure, activation attempts and their resources,
    per-process tool catalogs, and the canonical tool projection in one lock.
    Transitions return cancellation/I/O effects for execution outside the lock.
- `WindowOwnershipAuthority` and `WindowRoutingResolver`
  - The authority owns window/tab identity and `windowEpoch`; the stateless
    resolver combines its snapshot with an immutable route snapshot. Neither
    mutates catalog lifecycle.
- `UpstreamTopologyAuthority`
  - Owns actual upstream slots, stable IDs, membership/order, and topology
    epoch. Routers, health state, schedulers, and debug views key local state by
    those IDs instead of mirroring the slot array.
- `CanonicalHandshakeState` and `ControlPlaneCoordinator`
  - Handshake state is independent from catalog/window epochs. The coordinator
    owns shared load tasks and waiters, but writes semantic state only through
    authority leases and transitions.
- `XcodeMCPProxyKit` HTTP gateway internals
  - `HTTPRequestSecurityPolicy` validates Origin for every route before any
    side effect. The gateway also owns server-issued session IDs, negotiated
    protocol-version enforcement, and typed single-message transport concerns.
  - Rejects JSON-RPC batch arrays at the HTTP boundary without invoking the
    session or upstream.
  - Tool-specific response shaping lives in dedicated surface helpers, not inline in forwarding hot paths.

## Dependency Direction

- `XcodeMCPKit` owns SDK protocol/runtime primitives and must not depend on
  proxy-only modules. Avoid introducing gateway/session/Xcode proxy knowledge
  here.
- `XcodeMCPProxyKit` depends on `XcodeMCPKit` and owns proxy session/config
  state, public proxy facades, CLI composition, installer helpers, and HTTP
  gateway internals. Low-level proxy implementation files live under
  `Sources/XcodeMCPProxyKit/Internal`, including session implementation files
  under `Sources/XcodeMCPProxyKit/Internal/Session`.
- `XcodeMCPProxyCLI`, `XcodeMCPProxyServer`, and `XcodeMCPProxyInstall` depend on
  `XcodeMCPProxyKit`; `XcodeMCPProxyToolVerifier` depends on `XcodeMCPKit`;
  `ProxyBuildInfoTool` is a standalone build-tool dependency of
  `ProxyBuildInfoPlugin`.

Run `swift test -Xswiftc -strict-concurrency=minimal` after moving files or changing imports;
the default suite includes public product compile contract tests and proxy
contract tests that exercise package and product boundaries.

## Protocol Boundaries

- `stdout`
  - Protocol payloads only. Do not send logs or debug text here.
- `stderr`
  - Human-readable logging only.
- HTTP request bodies
  - Parse once per request and pass the parsed payload through forwarding/local handling; do not re-parse in hot-path helpers unless the payload is synthesized internally.
- Resource lifecycle
  - Public `close()`, `stop()`, and `shutdown()` methods are the graceful
    completion contracts. They stop admission, cancel and await owned tasks,
    close transport/channel resources, then publish terminal state.
  - `deinit` is a synchronous cancellation backstop only. It must not create an
    unowned cleanup task or promise graceful protocol shutdown.
- Discovery
  - A discovery record is a URL hint. Only a connection plus standard
    initialize handshake establishes reachability; PID liveness is not truth.

## Local Verification

- Fast regression suite:
  - `swift test -Xswiftc -strict-concurrency=minimal`
- Process / pipe suite:
  - `XCODE_MCP_RUN_PROCESS_TESTS=1 swift test --no-parallel --filter XcodeMCPProcessRuntimeTests -Xswiftc -strict-concurrency=minimal`
  - `XCODE_MCP_RUN_PROCESS_TESTS=1 swift test --no-parallel --filter ProxyStdioAdapterTests -Xswiftc -strict-concurrency=minimal`
- Full local maintainer check:
  - `scripts/check.sh`

These are used by the default CI workflow and release workflow, and intentionally avoid requiring real `mcpbridge`.

## Release Flow

- Entry point:
  - `gh workflow run release.yml --ref main -f version=v1.2.3`
- Behavior:
  - Runs only from the default branch.
  - Runs `scripts/check.sh`.
  - Builds the arm64 archive, `SHA256SUMS.txt`, and `install.sh` on GitHub Actions.
  - `SHA256SUMS.txt` covers both the archive and `install.sh`.
  - Verifies checksums, archive contents, and regenerated installer contents.
  - Creates the release tag for the default-branch commit.
  - Creates a draft GitHub Release with generated notes.
  - Rerunning the workflow repairs an existing draft for the same tag when it points to the same default-branch commit.
  - Maintainers edit the draft release notes and publish manually.
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
