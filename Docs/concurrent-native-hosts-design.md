# Concurrent native Xcode hosts

Proposal for [issue #292](https://github.com/lynnswap/XcodeMCPKit/issues/292).
Baseline: `7fd4d71086b585345550895c8b05d8e128a13f45`.

## Goal and scope

Keep one HTTP MCP endpoint while allowing a client to list Xcode hosts and change its selected host during a conversation. Each host has its own native process, Xcode installation, saved workspace models, tool catalog, and operation settings. Several hosts may use the same installation.

A new client starts on the server's terminal-default Xcode. Resolve the explicit embedding configuration first, then the server's inherited `DEVELOPER_DIR`, then `xcode-select -p`. Capture the resulting developer directory when registering the default host so restarting that host cannot silently change its installation.

Keep existing HTTP, STDIO-adapter, and Swift-client entry points. GUI buffers and GUI scheme/destination selection remain outside the headless contract.

## What Apple's implementation establishes

Inspected Xcode 27.0 build 27A266a, using the installed binaries:

- `Contents/Developer/usr/bin/mcpbridge --help` documents `MCP_XCODE_PID` for choosing a process and `MCP_XCODE_SESSION_ID` for identifying a tool session.
- `mcpbridge.ToolServiceConnector.requestConnection(to:)` takes a PID. Its connection-request and assertion tables are keyed by PID.
- `mcpbridge.ToolSession` has a primary `ToolConnection`, an optional UI connection, a workspace map, and an in-flight-call map.
- `IDEIntelligenceMessaging.ToolRouting.WorkspaceEntry` carries `origin`, `nativeId`, and `path`. Origins include `ui` and `daemon`; workspace discovery is merged and tool arguments are translated for the chosen entry.
- `ToolRouting.bridgeWorkspaceArgument` resolves to `workspaceIdentifier`. The inspected argument translator removes bridge/UI selector fields before writing the native selector for the target origin.
- Xcode Service keeps active agent connections in a UUID-keyed table and uses the native `IDEWorkspaceRegistry`.

These observations support separating connection identity, workspace identity, and individual requests. They do not establish that one official bridge automatically routes across an arbitrary set of GUI processes. The bridge/service combination was inspected statically; concurrent official-Service routing was not tested.

Apple's [external-agent guide](https://developer.apple.com/documentation/xcode/giving-external-agents-access-to-xcode) documents the supported bridge entry point, but does not specify these internal routing details. Keep the headless execution decision from [#276](https://github.com/lynnswap/XcodeMCPKit/issues/276); this feature adds no BoardServices/RunningBoard connection code or new Xcode SPI.

## MCP contract

Add two proxy-owned tools:

### `XcodeMCPKitListHosts`

Return existing hosts and available host candidates for installed Xcode applications. Listing reads installation metadata and does not start all candidates. Use the public [NSWorkspace application inventory](https://developer.apple.com/documentation/appkit/nsworkspace/urlsforapplications(withbundleidentifier:)) and include the explicitly configured/default installation even if it is absent from that inventory.

Each entry reports:

- `hostIdentifier`: logical identity, distinct from the Xcode version and native PID
- `appPath`, `developerDirectory`, and available version metadata
- default/selected status for the caller
- native PID when running, and whether the host is ready for tools

An available candidate is a registered host configuration without a started process. Its identity stays stable for the server lifetime.

### `XcodeMCPKitSelectHost`

Input:

```json
{
  "hostIdentifier": "host-from-the-list",
  "createsNewHost": false
}
```

Select or lazily start the identified host for the caller's MCP session. With `createsNewHost: true`, create and select another independent host using that entry's Xcode installation. This covers separate instances of the same installation without a third creation tool.

Initialize the target and obtain its catalog before committing the selection. If startup fails, report that failure and preserve the previous selection. Return the selected host's identity and origin information.

Selection affects subsequently admitted requests. Requests admitted before the change retain their original host, including queued calls, cancellation, progress, and completion. Emit `notifications/tools/list_changed` only for the selecting session. Its next `tools/list` returns the selected native catalog plus these two management tools.

The management tools remain available when a selected host becomes unavailable, so the caller can inspect or select another host.

### Swift client use

Use the existing generic client API; no new public Swift overloads are needed:

```swift
let client = try await XcodeMCP()
let hosts = try await client.callTool("XcodeMCPKitListHosts")

let selection = try await client.callTool(
    "XcodeMCPKitSelectHost",
    arguments: [
        "hostIdentifier": "host-from-the-list",
        "createsNewHost": true,
    ]
)
await client.close()
```

The direct `.localBridge(.nativeHost())` transport continues to represent its single owned native host. Host-management tools are supplied by the shared proxy.

## Owners and dependencies

Use a host broker in `XcodeMCPProxyRuntime` that implements the existing `ProxyRuntimeServing` boundary. Compose one existing single-host `ProxyRuntime` per registered host. The HTTP gateway continues to depend on the runtime contract.

| Resource | Owner |
| --- | --- |
| Logical host identity, immutable installation configuration, child runtime creation and shutdown | Host broker registry |
| External MCP session, selected host, and attached backend channels | Broker session |
| Native initialization result, catalog, recovery and request execution | Existing runtime for that host |
| HTTP delivery and SSE connections | Existing HTTP control/delivery layer |
| Saved workspace models, native IDs, scheme/destination/test-plan state | Native registry in that host process |

The broker owns the external initialize response and advertises its tool service with list-change notifications. Native initialization is separate and scoped to each host, so choosing another installation does not require comparing its handshake against a server-wide canonical native result. Management tools can be listed before a host's native catalog is ready; a native-catalog failure is reported alongside that partial tool list.

The external MCP session remains connected when its selection changes. Attach a backend channel to each host used by that session and keep old channels until outstanding calls complete or the client session ends. These channels are backend connections, not additional client HTTP sessions. Session deletion or expiry closes every channel attached to that client. It does not stop a shared host that remains registered with the server.

Capture host/channel identity once at request admission. Server-initiated request IDs and progress tokens must remain correlated with the originating channel even after selection changes. Reuse the existing request/progress tracking primitives with host/channel identity included in their ownership keys.

Client transport initialization, activity, and expiry belong to the broker session. Backend initialization belongs to the chosen host/channel. Pass a shared decoded JSON-RPC request through the routing boundary rather than reparsing HTTP bodies in the broker and child runtime.

Workspace paths resolve inside the selected host. Native workspace and device-session identifiers retain their native representation and are scoped to that host; returned origin metadata identifies their owner. Clients select the owning host before reusing those identifiers. Do not infer a host from a path that is open in more than one host.

Catalog and initialization caches remain per host. Tool-list changes from a host reach sessions currently selecting that host; progress and responses still reach the owners of earlier calls. Retiring one host must not invalidate other hosts' catalogs or external sessions. Unknown mutation completion is never replayed against another host.

DocumentationSearch executes the selected host's native implementation. Preserve the existing documented policy of selecting the latest readable installed documentation asset; that policy does not guarantee documentation content for one specific Xcode revision. Do not introduce a version filter without an established asset compatibility contract.

## Why this composition

The current coordinator's single canonical handshake/catalog and alternative-upstream recovery assume interchangeable backends. Simply adding different Xcodes to that topology would allow schema comparisons, fallback, or invalidation to affect unrelated hosts.

An independent existing runtime per host gives each host the initialization, catalog, recovery, and operation owners it already needs. The broker adds the missing client-selection boundary. Extending a single coordinator with per-host copies of its control-plane fields would require changing most admission, canonical-state, and recovery paths together.

No package or target is added. Replace the server-wide single-runtime composition with the broker. Preserve the current per-host execution path and default consumer behavior; do not restore GUI discovery/routing or add a global catalog union.

## Verification and delivery

Deliver the broker, the two tools, documentation, and verification as one independently reviewable PR for #292.

- Two sessions select different hosts and receive different native catalogs/origin metadata.
- Two hosts using the same installation open the same saved workspace with independent operation settings.
- Select during an in-flight or queued call; completion and cancellation stay with the original host.
- Restart one host while another performs work. Only the restarted host's operations fail; its replacement retains the configured installation.
- A failed selection keeps the prior binding, and management tools allow recovery.
- Server-request IDs, progress tokens, SSE delivery, session close, and expiry stay with their owning external session/channel.
- Existing clients still use the terminal-default host and unchanged transport APIs.
- Run focused `xcodebuild test` suites for runtime, HTTP, integration, and affected external-product fixtures, then `codex-review`.
- Live verification covers same-installation and different-installation hosts with concurrent saved-project operations and independent recovery. Versions are test inputs, not routing identifiers.

## Compatibility boundary to verify

The selection scope is an MCP session. Confirm that the intended Codex clients use independent MCP sessions for independently selectable chats. If a client pools one MCP session across chats, those chats share a selection; that client integration constraint must be resolved or documented before claiming per-chat isolation.
