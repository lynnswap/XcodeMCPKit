# Historical Xcode 27 Service design

This document records the former Xcode Service backend and its investigation.
Its commands and configuration examples are obsolete. Current behavior is
described in [Architecture](architecture.md) and
[Native routing migration](automatic-routing-migration.md).

## Former Service-based contract

The proxy keeps GUI routes and the enabled native Xcode Service pool available
at the same time. Workspace selection happens for each request. The server has
no GUI/headless mode, configured PID, Apple session ID, or custom upstream.
See [automatic routing migration](automatic-routing-migration.md) for removed
configuration and [the embedded API](../Sources/XcodeMCPProxyKit/README.md).

```sh
xcode-mcp-proxy-server --auto-approve --upstream-processes 2
```

```swift
let server = XcodeMCPProxyServer(configuration: .init(upstreamProcessCount: 2))
let endpoint = try await server.start()
// Use endpoint.url.
try await server.shutdown()
```

The observations below were collected with Xcode 27.0 build `27A5252f` and
`xcode-tools` version `25295.11`. They record native behavior at that version;
they are not requirements for other Xcode versions.

## Verified upstream contract

The following facts were observed with `MCP_XCODE_PID` absent and the selected
Xcode 27 developer directory in `DEVELOPER_DIR`:

1. `xcrun mcp-server status --format json` exits successfully while disabled
   and returns `permission.enabled`, `permission.unsafeAlwaysAllowAllAgents`,
   `running`, and `openWorkspaces`.
2. `openWorkspaces` is not a stable scalar shape: when populated it is an array
   of objects containing `path`, `displayName`, and `activeSchemeName`.
   Availability resolution therefore decodes only `permission.enabled` and
   preserves or ignores unknown fields.
3. An unbound `mcpbridge` initializes successfully against headless
   `XcodeService` and returns a 54-tool catalog.
4. The headless catalog owns workspace lifecycle through
   `XcodeOpenWorkspace`, `XcodeListWorkspaces`, and `XcodeCloseWorkspace`.
   XcodeMCPKit must not duplicate that state or require a workspace path at
   proxy startup.
5. First use of `XcodeOpenWorkspace` is the approval boundary for both agent
   identity and the containing folder. Before approval, catalog discovery is
   available while workspace tools return an actionable tool error.
6. `mcp-server open <path>` is service administration, not the agent approval
   boundary. It must not be used as a substitute for `XcodeOpenWorkspace`.
7. Xcode Service is process-shared. XcodeMCPKit owns its child `mcpbridge`
   processes, but does not own or stop Xcode Service.
8. With headless access enabled and Xcode Service stopped, launching an unbound
   `mcpbridge` starts Xcode Service and completes `initialize`. XcodeMCPKit does
   not need to call `mcp-server start`.
9. With `unsafeAlwaysAllowAllAgents` enabled, headless `DocumentationSearch`
   can still present a connection approval dialog in GUI Xcode. The proxy's
   automatic approval policy therefore applies independently of routing mode;
   the existing dialog matcher limits approval to the proxy's own connections.

The preview CLI may return valid status JSON together with a nonzero status or
warning when its live service query times out. A valid JSON payload is the
status fact; stderr and exit status remain diagnostics.

## Service availability

The server checks Service availability once during startup. An installed,
enabled Service adds its native bridge pool alongside discovered GUI processes.
A missing or disabled Service leaves GUI routing available. A malformed status
response or execution failure emits a warning and also leaves GUI routing
available. Cancellation propagates through startup cleanup.

Disabled access emits one notice with the `sudo xcrun mcp-server enable`
command and states that GUI routing remains available.

XcodeMCPKit never executes `enable`, `approve`, `allow-folder`, `deny`,
`clear-permissions`, or an unsafe permission command.

## Owner map

| Responsibility | Owner |
| --- | --- |
| `mcp-server` discovery, status execution, and narrow JSON decoding | internal status client in `XcodeMCPProxyKit` |
| Service availability and startup diagnostics | server lifecycle acquisition |
| GUI Xcode process inventory | existing `XcodeProcessEventMonitor` |
| GUI process-bound bridge membership and catalogs | existing `ProcessControlPlaneAuthority` |
| Headless bridge process and catalog | existing unbound `MCPBridgeRuntime` path |
| Headless workspace membership and identifiers | upstream Xcode Service tools |
| GUI window/tab identity | existing `WindowOwnershipAuthority` |
| Device interaction token affinity | runtime affinity authority |
| Downstream HTTP session and progress-token ownership | existing session and lease authorities |

No new package, product, or target is required. The new external-I/O adapter is
an internal `XcodeMCPProxyKit` responsibility; the runtime receives only the
observed Service availability.

## Runtime and lifecycle contract

- GUI process discovery is always active. Each GUI child receives its discovered
  owner's `MCP_XCODE_PID` and developer directory.
- Every bridge launch removes inherited `MCP_XCODE_PID`, `MCP_XCODE_SESSION_ID`,
  and the legacy `XCODE_PID`. Service bridges use the native default connection.
- Enabled Service forwards native DocumentationSearch and workspace tools.
  Without Service, the existing GUI documentation provider remains available.
- Automatic permission handling operates independently of workspace ownership.
- Proxy shutdown closes and awaits its bridge/runtime/HTTP resources. It does
  not call `mcp-server stop`.
- Status resolution is part of startup acquisition. Cancellation of startup
  cancels and awaits the status process through `ProcessRunner`.
- A disabled Service is a normal availability result. A
  malformed response or execution failure is diagnostic, not silently
  equivalent to disabled.

## Tool-surface compatibility

The Xcode tool catalog remains dynamic. Do not add one Swift method per Xcode
tool. Headless-specific tools and future catalog fields pass through unchanged.

The proxy-owned `XcodeRefreshCodeIssuesInFile` workflow resolves the workspace
owner first. GUI requests can use the configured proxy diagnostics workflow;
Service requests use the native workspace contract.

## Device interaction affinity

`DeviceInteractionStartSession` and
`DeviceInteractionStartWorkspaceSession` return `interactionSessionKey`.
Follow-up tools use two spellings:

- `DeviceInteractionSynthesize`: `interactSessionKey`
- `DeviceInteractionInstallAndRun` and `DeviceInteractionEndSession`:
  `interactionSessionKey`

For every upstream topology, the runtime records the returned key together with
the exact upstream topology proof that created it. Routed GUI pools additionally
record the stable process-route identity needed for window admission and
identifier rewriting. Follow-up requests are admitted only to the recorded
upstream proof. Route replacement, retirement, session end, and runtime shutdown
evict the corresponding affinity. An unknown key follows the upstream's ordinary
error path only when exactly one bridge connection exists, whether GUI or Service. It is
never guessed across multiple connections.

The affinity authority owns token membership. Request routing consumes an
immutable snapshot/proof and revalidates it before send. It does not mirror
device state or own the device-session lifecycle itself.

## Progress and verifier contract

- Existing progress-token rewriting and per-operation delivery remain the
  single source of truth.
- The live verifier records progress notifications for build/test operations
  and preserves their raw fields in its report.
- The verifier supports mixed catalogs. GUI calls keep the resolved tab selector.
  Service runs create a dedicated workspace and call Open before inventory,
  preserving first-use approval and existing shared workspaces.
- Live verification remains opt-in and never enables or broadly approves
  headless access.

## Signing decision

The current release artifact is ad-hoc signed. Xcode Service identified the
probe's actual host executable as the agent identity, not `mcpbridge`. After a
release-shaped XcodeMCPKit binary connects headlessly, inspect the recorded
identity and approval duration. Developer ID signing and notarization are a
follow-up only if durable trust rejects the artifact or fails to survive an
upgrade. No signing credential or workflow change is part of this design until
that behavior is observed.

## Failure semantics

| Boundary | Behavior |
| --- | --- |
| `mcp-server` absent in automatic mode | use GUI routing |
| headless disabled in automatic mode | emit notice once; use GUI routing |
| status command fails or JSON is malformed in automatic mode | emit warning; use GUI routing |
| explicit headless unavailable or disabled | fail startup with actionable configuration error |
| agent/folder approval pending | preserve upstream tool error; do not auto-approve or retry-loop |
| headless service exits after connection | existing upstream health/recovery semantics apply |
| proxy shuts down | stop owned bridges; leave shared Xcode Service running |

## Validation

- Status-client unit tests: unavailable, disabled, enabled, populated dynamic
  `openWorkspaces`, valid JSON with nonzero exit, malformed JSON, timeout, and
  cancellation.
- CLI/config tests for all modes and custom-upstream conflicts.
- Runtime tests proving GUI mode remains process-bound and headless mode is
  unbound with no GUI readiness launch, while honoring the approval policy for
  Xcode connection dialogs.
- Startup-summary and exact multiline notice tests.
- Public product contract compile test for `xcodeMode`.
- Device-affinity owner and routing tests, including both key spellings,
  process-routed and unbound pools, replacement, retirement, end, and unknown
  keys.
- Existing fast, process, adapter, and full maintainer checks.
- Opt-in live headless initialize, catalog, workspace open/list/close, progress,
  and shutdown verification against Xcode 27.

## Progress ledger

- [x] Create task branch and record baseline.
- [x] Verify status JSON while disabled and enabled.
- [x] Verify headless initialize and 54-tool catalog.
- [x] Verify workspace tools are the approval/bootstrap boundary.
- [x] Verify unbound `mcpbridge` starts Xcode Service on demand.
- [x] Implement mode/status resolution and notice.
- [x] Implement resolved runtime ownership and public/CLI surface.
- [x] Implement device interaction affinity.
- [x] Extend verifier and documentation.
- [x] Run automated validation and clean `codex-review`.
- [ ] Complete post-approval live workspace open/list/close and progress
  verification.
