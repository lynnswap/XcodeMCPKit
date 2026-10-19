# Concurrent native Xcode hosts

Approved design for [issue #292](https://github.com/lynnswap/XcodeMCPKit/issues/292).
Baseline: `7fd4d71086b585345550895c8b05d8e128a13f45`.

## Goal and scope

Keep one HTTP MCP endpoint while allowing a client to list Xcode hosts and change its selected host during a conversation. A target is an owned headless runtime or a running GUI Xcode process. Each target has its own process identity, Xcode installation, workspace models, tool catalog, and operation settings. Several targets may use the same installation and execute concurrently. Build storage and compilation caches retain Xcode's existing sharing and locking behavior; the broker does not assign host-specific DerivedData directories.

A new client starts on the server's default Xcode. Try the explicit embedding configuration first, then the server's inherited `DEVELOPER_DIR`, then `xcode-select -p`. If those selections are unavailable, discover installed Xcode applications as described in [configuration](configuration.md#xcode-compatibility). The proxy and standalone native helper share installation discovery and path normalization. Capture the resulting developer directory when registering the default host so restarting that host cannot silently change its installation.

Keep existing HTTP, STDIO-adapter, and Swift-client entry points. Headless hosts use saved models; GUI targets use Apple's bridge and the selected application's state. Preserve each target's raw tool catalog, including `tabIdentifier` for GUI tools and `workspaceIdentifier` for headless tools when advertised.

## What Apple's implementation establishes

Inspected Xcode 27.0 build 27A266a, using the installed binaries:

- `Contents/Developer/usr/bin/mcpbridge --help` documents `MCP_XCODE_PID` for choosing a process and `MCP_XCODE_SESSION_ID` for identifying a tool session.
- `mcpbridge.ToolServiceConnector.requestConnection(to:)` takes a PID. Its connection-request and assertion tables are keyed by PID.
- `mcpbridge.ToolSession` has a primary `ToolConnection`, an optional UI connection, a workspace map, and an in-flight-call map.
- `IDEIntelligenceMessaging.ToolRouting.WorkspaceEntry` carries `origin`, `nativeId`, and `path`. Origins include `ui` and `daemon`; workspace discovery is merged and tool arguments are translated for the chosen entry.
- `ToolRouting.bridgeWorkspaceArgument` resolves to `workspaceIdentifier`. The inspected argument translator removes bridge/UI selector fields before writing the native selector for the target origin.
- Xcode Service keeps active agent connections in a UUID-keyed table and uses the native `IDEWorkspaceRegistry`.

These observations support separating connection identity, workspace identity, and individual requests. They do not establish that one official bridge automatically routes across an arbitrary set of GUI processes. The bridge/service combination was inspected statically; concurrent official-Service routing was not tested.

Apple's [external-agent guide](https://developer.apple.com/documentation/xcode/giving-external-agents-access-to-xcode) documents the supported bridge entry point, but does not specify these internal routing details. Headless execution retains the decision from [#276](https://github.com/lynnswap/XcodeMCPKit/issues/276). GUI targets connect through Apple's `mcpbridge`; the proxy adds no direct BoardServices/RunningBoard connection code.

## MCP contract

Add two proxy-owned tools:

### `XcodeMCPKitListHosts`

Return existing headless hosts, candidates for installed Xcode applications, and running GUI Xcode processes. Listing reads installation and running-application metadata without starting every candidate. Include the explicitly configured/default installation even if it is absent from automatic discovery. A GUI identity includes PID, launch time, and installation so a reused PID cannot select a replacement application.

Each entry reports:

- `hostIdentifier`: logical identity, distinct from the Xcode version and native PID
- `kind`: `headless` or `gui`
- `appPath`, `developerDirectory`, and available version metadata
- default/selected status for the caller
- native PID when running, and whether the host is ready for tools

An available headless candidate is a registered configuration without a started process. Ordinary installation candidates retain their identities for the server lifetime. Independent headless hosts exist only while sessions or admitted requests retain them. Running GUI entries identify a specific application launch.

### `XcodeMCPKitSelectHost`

Input:

```json
{
  "hostIdentifier": "host-from-the-list",
  "createsNewHost": false
}
```

Select or lazily start the identified host for the caller's MCP session. With `createsNewHost: true`, create and select another independent headless host using that entry's Xcode installation. A GUI target uses one shared bridge per Xcode process and requires selection of its existing entry; `createsNewHost` is rejected for GUI targets.

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
| Saved workspace models, native IDs, scheme/destination/test-plan state | MainActor native registry in the headless process, or selected GUI application |
| Headless request Tasks, JSON-RPC, output, and artifacts | Native MCP session actor |
| Headless workspace permits and execution limits | Execution queue actor in each owned process |
| GUI native catalog and request transport | Shared `mcpbridge` runtime for that application launch |

The broker owns the external initialize response and advertises its tool service with list-change notifications. Native initialization is separate and scoped to each host, so choosing another installation does not require comparing its handshake against a server-wide canonical native result. Management tools can be listed before a host's native catalog is ready; a native-catalog failure is reported alongside that partial tool list.

The external MCP session remains connected when its selection changes. Keep the selected backend channel and channels retained by outstanding calls. Release an old channel when no admitted request still uses it. These channels are backend connections, not additional client HTTP sessions. Session deletion or expiry cancels its requests and closes its channels.

Reclaim an independent headless host after its last selecting session, admitted request, and backend channel are released. Its logical host, workspace, and device-session identifiers then become invalid; a replacement reloads the workspace by absolute path. Ordinary installation candidates and the default headless host remain registered. After a GUI target's final selection, request, and backend channel are released, deactivate its bridge runtime while retaining its application identity. A later selection waits for deactivation to finish before reconnecting. The Xcode application keeps running, including when the proxy shuts down.

Capture host/channel identity once at request admission. Server-initiated request IDs and progress tokens must remain correlated with the originating channel even after selection changes. Reuse the existing request/progress tracking primitives with host/channel identity included in their ownership keys.

Client transport initialization, activity, and expiry belong to the broker session. Backend initialization belongs to the chosen host/channel. Pass a shared decoded JSON-RPC request through the routing boundary rather than reparsing HTTP bodies in the broker and child runtime.

Workspace paths resolve inside the selected host. Native workspace and device-session identifiers retain their native representation and are scoped to that host; returned origin metadata identifies their owner. Clients select the owning host before reusing those identifiers. Do not infer a host from a path that is open in more than one host.

Each owned headless process has a separate execution queue. Hold its workspace permit through prepare, stream consumption, and cleanup; an actor's suspension alone does not end the operation. Different workspaces can proceed concurrently, while a mutation without a workspace selector excludes every workspace in that host. Limit each host to four concurrent tool calls, one heavy call, and 32 MiB of waiting request bytes. Apply no global limit across Xcode processes. GUI targets retain their application's bridge execution contract.

Cancellation requests a stop through the request scope's observed native Operations. The native action bridge actor owns a relay that keeps consuming the original stream through its natural terminal after request-facing cancellation. Cleanup awaits this relay, observed Operations, and owned preview/crash producer Tasks before releasing the workspace permit. Actions without cancellable Operations can require waiting for natural completion. This drain boundary does not join opaque native Swift Task handles.

Automatic cleanup of removed workspace directories excludes models claimed by another active request. The registry uses the request's already resolved canonical workspace key and releases its claim after stream drain and cleanup.

Catalog and initialization caches remain per host. Tool-list changes from a host reach sessions currently selecting that host; progress and responses still reach the owners of earlier calls. Retiring one host must not invalidate other hosts' catalogs or external sessions. Unknown mutation completion is never replayed against another host.

DocumentationSearch executes the selected host's native implementation. Preserve the existing documented policy of selecting the latest readable installed documentation asset; that policy does not guarantee documentation content for one specific Xcode revision. Do not introduce a version filter without an established asset compatibility contract.

## Why this composition

The current coordinator's single canonical handshake/catalog and alternative-upstream recovery assume interchangeable backends. Simply adding different Xcodes to that topology would allow schema comparisons, fallback, or invalidation to affect unrelated hosts.

An independent existing runtime per host gives each host the initialization, catalog, recovery, and operation owners it already needs. The broker adds the missing client-selection boundary. Extending a single coordinator with per-host copies of its control-plane fields would require changing most admission, canonical-state, and recovery paths together.

Use the broker to retain independent runtime, catalog, recovery, and selection state per target. GUI discovery adds selectable running processes without merging their catalogs. Preserve the headless default and existing consumer entry points.

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
- Live verification must cover same-installation and different-installation targets with concurrent saved-project operations and independent recovery. Versions are test inputs, not routing identifiers.
- Verify GUI selection and raw selectors, independent-host reclamation after the final request, and per-process execution limits. Exercise cancellation through observed native completion; stream termination alone is insufficient evidence of producer completion.

## Compatibility boundary to verify

The selection scope is an MCP session. Confirm that the intended Codex clients use independent MCP sessions for independently selectable chats. If a client pools one MCP session across chats, those chats share a selection; that client integration constraint must be resolved or documented before claiming per-chat isolation.
