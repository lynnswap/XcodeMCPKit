# Xcode 27 Headless MCP Design

## Status

- Design owner: `codex/xcode-27-headless-mcp`
- Baseline: `b251cecfa059ce7b5f0a9c9a8b7f9480e390edb3`
- Verified Xcode: 27.0 build `27A5252f`
- Verified Xcode MCP server: `xcode-tools` version `25295.11`
- Implementation: complete; automated validation complete
- Live workspace validation: pending manual Xcode Service approval

This document is the design contract and progress ledger for Xcode 27 headless
MCP support. Update it before changing a public API or owner boundary.

## Consumer stories

### Default CLI

```sh
xcode-mcp-proxy-server --auto-approve
```

The server uses Xcode 27's headless MCP service when the selected Xcode ships
`mcp-server` and headless access is enabled. Otherwise it preserves GUI Xcode
routing. When headless access is available but disabled, startup emits one
actionable notice and continues with GUI routing.

### Explicit selection

```sh
xcode-mcp-proxy-server --xcode-mode gui
xcode-mcp-proxy-server --xcode-mode headless
```

Explicit GUI mode never consults or launches the headless service. Explicit
headless mode fails startup when the selected Xcode does not ship `mcp-server`
or headless access is disabled. It never silently falls back to GUI routing.

### Embedded server

```swift
let server = XcodeMCPProxyServer(
    configuration: .init(xcodeMode: .automatic)
)
let endpoint = try await server.start()
defer { Task { try? await server.shutdown() } }
```

`xcodeMode` is a connection-selection policy. The existing `Upstream` value
continues to own the bridge command, arguments, pool size, and optional MCP
session identifier.

## Public interface sketch

```swift
public struct XcodeMCPProxyServerConfiguration: Equatable, Sendable {
    public enum XcodeMode: String, Equatable, Sendable {
        case automatic
        case gui
        case headless
    }

    public var xcodeMode: XcodeMode

    public init(
        bindAddress: BindAddress = .localhost(),
        upstream: Upstream = .defaultMCPBridge(),
        maxBodyBytes: Int = 1_048_576,
        requestTimeout: Duration? = .seconds(300),
        configurationFileURL: URL? = nil,
        toolPolicy: ToolPolicy? = nil,
        initializeHandshake: InitializeHandshake? = nil,
        discovery: Discovery = .defaultLocation,
        approvalPolicy: ApprovalPolicy = .manual,
        featurePolicy: FeaturePolicy = .default,
        xcodeMode: XcodeMode = .automatic
    )
}
```

Adding `xcodeMode` with a default preserves existing source call sites. The new
enum is a closed consumer choice and is therefore intentionally exhaustive.

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

The preview CLI may return valid status JSON together with a nonzero status or
warning when its live service query times out. A valid JSON payload is the
status fact; stderr and exit status remain diagnostics.

## Mode resolution

Mode resolution happens once during server start, before the runtime and HTTP
gateway acquire resources.

| Requested mode | Stock `mcpbridge` | `mcp-server` state | Effective mode |
| --- | --- | --- | --- |
| automatic | yes | installed and enabled | headless |
| automatic | yes | installed and disabled | GUI + notice |
| automatic | yes | not installed | GUI |
| automatic | yes | status unavailable or malformed | GUI + warning |
| gui | yes | any | GUI; status is not queried |
| headless | yes | installed and enabled | headless |
| headless | yes | disabled, unavailable, or malformed | startup error |
| automatic | custom upstream | not applicable | existing custom unbound mode |
| gui/headless | custom upstream | not applicable | configuration error |

The disabled notice is one multiline log event:

```text
Xcode 27 headless MCP is available but disabled.

To enable it, run:

    sudo xcrun mcp-server enable

XcodeMCPKit will continue using GUI Xcode routing.
```

XcodeMCPKit never executes `enable`, `approve`, `allow-folder`, `deny`,
`clear-permissions`, or an unsafe permission command.

## Owner map

| Responsibility | Owner |
| --- | --- |
| Requested GUI/headless/automatic policy | `XcodeMCPProxyServerConfiguration` / `ProxyConfig` |
| `mcp-server` discovery, status execution, and narrow JSON decoding | new internal status client in `XcodeMCPProxyKit` |
| Effective mode selection and user-facing notice/error | server lifecycle acquisition |
| GUI Xcode process inventory | existing `XcodeProcessEventMonitor` |
| GUI process-bound bridge membership and catalogs | existing `ProcessControlPlaneAuthority` |
| Headless bridge process and catalog | existing unbound `MCPBridgeRuntime` path |
| Headless workspace membership and identifiers | upstream Xcode Service tools |
| GUI window/tab identity | existing `WindowOwnershipAuthority` |
| Device interaction token affinity | new runtime affinity authority |
| Downstream HTTP session and progress-token ownership | existing session and lease authorities |

No new package, product, or target is required. The new external-I/O adapter is
an internal `XcodeMCPProxyKit` responsibility; the runtime receives only the
resolved mode.

## Runtime and lifecycle contract

- GUI mode preserves process-bound discovery, `MCP_XCODE_PID`, per-Xcode pools,
  AX permission automation, and the proxy DocumentationSearch provider.
- Headless mode launches the configured stock bridge without
  `MCP_XCODE_PID`. It does not wait for a GUI Xcode process and does not run AX
  permission automation.
- Headless mode forwards the upstream DocumentationSearch and workspace tools;
  it does not create a second workspace or documentation source of truth.
- Proxy shutdown closes and awaits its bridge/runtime/HTTP resources. It does
  not call `mcp-server stop`.
- Status resolution is part of startup acquisition. Cancellation of startup
  cancels and awaits the status process through `ProcessRunner`.
- A disabled headless service is a normal automatic-mode candidate result. A
  malformed response or execution failure is diagnostic, not silently
  equivalent to disabled.

## Tool-surface compatibility

The Xcode tool catalog remains dynamic. Do not add one Swift method per Xcode
tool. Headless-specific tools and future catalog fields pass through unchanged.

The proxy-owned `XcodeRefreshCodeIssuesInFile` workflow must be checked against
the headless schema before it is enabled in headless mode. If the headless tool
uses `workspaceIdentifier` rather than the GUI tab contract, the effective
headless configuration forwards this tool upstream instead of guessing a GUI
owner.

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
error path only when a single unbound upstream exists; it is never guessed across
multiple process-routed or unbound upstreams.

The affinity authority owns token membership. Request routing consumes an
immutable snapshot/proof and revalidates it before send. It does not mirror
device state or own the device-session lifecycle itself.

## Progress and verifier contract

- Existing progress-token rewriting and per-operation delivery remain the
  single source of truth.
- The live verifier records progress notifications for build/test operations
  and preserves their raw fields in its report.
- The verifier gains a headless path that calls `XcodeOpenWorkspace`, uses the
  returned `workspaceIdentifier`, and always calls `XcodeCloseWorkspace` for a
  workspace it opened.
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
  unbound with no GUI readiness launch.
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
