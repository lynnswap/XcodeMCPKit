# Migration

Restart the proxy and connected MCP clients after upgrading so clients load the
current public tool definitions. Installation instructions are in the
[quick start](../../README.md#quick-start).

## Workspace and host routing

Open a saved project with `XcodeOpenWorkspace`, then pass its returned
`workspaceIdentifier` to an operation. The identifier retains its native
headless workspace and host. `XcodeListWorkspaces` lists loaded headless models;
workspace operations use these headless models. Crash collection uses a hidden, owned
Organizer instance as described below.

| Previous call or value | Replacement |
| --- | --- |
| `XcodeMCPKitSelectHost({hostIdentifier})` followed by `tools/list` | Use the workspace identifier directly. For another installation, pass `hostIdentifier` to `XcodeOpenWorkspace`. |
| `XcodeMCPKitSelectHost({hostIdentifier,createsNewHost:true})` or `XcodeOpenWorkspace({path,createsNewHost:true})` | `XcodeOpenWorkspace({path,hostIdentifier})`. Each installation has one shared headless host; use a separate checkout when settings must differ. |
| `XcodeListWindows` and its native tab ID | Open the saved project with `XcodeOpenWorkspace`; use `XcodeListWorkspaces` to list loaded headless models. |
| `GetBuildLog({tabIdentifier: ...})` or other GUI workspace inputs | `GetBuildLog({workspaceIdentifier: ...})` using the identifier from List/Open. |
| A native workspace ID retained across host selection | A new proxy identifier from List/Open. Do not reuse an old native ID. |
| `DeviceInteractionStartWorkspaceSession` | `DeviceInteractionStartSession` with `workspaceIdentifier`; omit that field for standalone device interaction. |
| `interactSessionKey` in `DeviceInteractionSynthesize` | `interactionSessionKey`, using the session returned by the public device-start operation. |
| Native `launchSessionReference` with a separately selected host | Keep the proxy reference returned by `RunProject`; pass it to `GetConsoleOutput` to retain the creating context. |

For example, replace the host-selection sequence with:

```json
{
  "path": "/Users/me/Projects/App/App.xcworkspace",
  "hostIdentifier": "host-from-XcodeMCPKitListHosts"
}
```

Call `XcodeOpenWorkspace` with those arguments and use its returned
`workspaceIdentifier` for subsequent calls. Omit `hostIdentifier` for the default
headless host. `XcodeCloseWorkspace` releases the calling session's reference to
its headless model.

Headless work uses saved files. Save editor changes before calling tools.
GUI editor state, scheme, destination, and debugger state are not imported into
the saved model.
After a new MCP session or host restart, obtain fresh workspace and device-session
identifiers. See [workspace usage](../usage.md) for normal operations.

## Crash collection

Replace `GetTopCrashIssues` / `ListCrashIssues` and `GetCrashIssueLogs` /
`GetCrashIssue` with `SyncCrashReports` and `ReadCrashChanges`.

1. Call Sync with `collection: "issues"` and the bundle/platform query. Remove
   `count`, `page`, and `page_size`; provider paging is internal.
2. Finish bounded imports by following Sync's `nextCursor`.
3. Call Read for the same issue collection and follow its `nextCursor`. Read
   returns saved changes instead of the old `data` string or an unbounded list.
4. Pass each issue's stable `issueId` to Sync with `collection: "logs"` and
   `issue_id`. Use its ID rather than its displayed signature name.
5. Read that logs collection. Process each page before saving its continuation,
   and persist the terminal `checkpoint` for the next change window.

Sync imports at most `max_records` and `max_bytes` per step (defaults 100 and
64 MiB); one oversized file can exceed the byte budget to make progress. Read's
`limit` and `max_bytes` bound returned pages (defaults 25 and 256 KiB). Sync and
Read cursors identify different operations and cannot be interchanged. Both
retain durable progress; Read never performs network access or consumes records
on behalf of another client. Each consumer stores its own tokens.

Shared content blobs replace per-request copies. Read returns local paths and
content IDs for new or changed observations. Use `contentId` for the SHA-256
byte identity previously exposed as `logId`; the new `logId` identifies a logical
saved sample across content updates. `observedNewestFirst` means local
observation order; optional log order `occurredAtDescending` uses known event
dates and places unknown dates last. A frozen read window does not freeze
Apple's service. New observations wait for the next window, and an issue missing
from a scan is not reported as deleted or resolved.
Each changed item is returned in its latest version at the window boundary;
intermediate versions are combined rather than returned as an update history.

Remove `app_version` and `is_beta` from log Sync calls. Organizer downloads
samples and distributions for all versions, builds, and channels over the last
year. `time_period` selects a returned distribution, without filtering samples.
Sample counts are not occurrence or device counts. Unchanged issue metadata
cannot establish that an issue's sample content has not changed; synchronize its
logs again to check.

Network Sync uses a hidden, owned instance of the selected Xcode and requires
configured App Store Connect account access and Accessibility permission. New
queries reuse that process without activation or pointer movement. A previously
fetched or prefetched query starts a new hidden instance to refresh Xcode's
in-memory data.
Cancelling an active acquisition, acquisition failure, and server shutdown close
the owned instance.
No API key or manually opened Xcode is needed. Completed source metadata and
imports remain available. Workspace operations and Read remain headless.

A list without a vertical scrollbar cannot currently advance in the background.
Sync preserves captured pages and reports the acquisition as incomplete instead
of activating Xcode or moving the pointer.

`source: "cache"` imports only exact saved metadata and local files, without
starting Xcode. Explicit bundle/platform inputs do not require Products inventory
or a workspace. Network fallback retains refresh errors and original fetch times;
unverified recovered samples retain unknown freshness. A partial source attempt
does not overwrite a complete saved snapshot. Check diagnostics and acquisition
progress separately from local read completion.
An unavailable source, including a cache miss without fallback, returns `failed`
with MCP `isError` and `cacheInfo.sourceAvailable: false`. This differs from a
successful empty collection or a usable partial source.

See [crash collection](../usage.md#collect-crash-reports) for examples, query
scopes, progress, and metric definitions. Restart connected clients to load the
new tool definitions.

## Native helper and server configuration

Install `XcodeMCPNativeHost.app` beside the proxy commands. Reinstall the complete
package if it is missing. The default helper executes headlessly through the
selected Xcode's frameworks without Xcode Service setup. Workspace operations
work without an open GUI window; network crash collection retains its own
hidden Xcode instance for Organizer until active acquisition cancellation,
acquisition failure, or shutdown.

Remove these older settings from startup scripts and embedding configuration:

| Removed | Current setup |
| --- | --- |
| `--upstream-processes`, `upstreamProcessCount` | One owned host per installation multiplexes concurrent requests. |
| `--xcode-mode`, `--session-id`, `--upstream-command`, `--upstream-args`, `--upstream-arg` | Use the normal proxy server. Remove explicit Service enable/status and `mcpbridge` launch steps. |
| `--config`, `MCP_XCODE_CONFIG`, TOML files, `configurationFileURL`, `ToolPolicy`, disabled-tool lists | Configure endpoint/deadlines directly; the MCP client controls allowed tools. |
| `--refresh-code-issues-mode` and its policy/environment settings | `XcodeRefreshCodeIssuesInFile` uses its owning native context. |
| Server CLI `--native-host-bundle`, `--developer-dir` | Keep the helper beside the commands; use `DEVELOPER_DIR` to prefer an installation. Embedders can set `nativeHostBundleURL` / `developerDirectoryURL`. |
| `xcode-mcp-proxy` STDIO adapter, its `--stdio` / `--url` options, and `XCODE_MCP_PROXY_ENDPOINT` | Register the client with the server's Streamable HTTP endpoint, normally `http://localhost:8765/mcp`. |

`--auto-approve` and the embedding `.automatic` approval policy remain opt-in
Accessibility automation for agents connecting directly to GUI Xcode. They do
not change routing or Xcode's permission store. Headless operations do not require
that monitor. See [configuration](../configuration.md).

## Swift client

`XcodeMCPConfiguration` defaults to `.streamableHTTPProxyDiscovery()`. Start the
proxy before constructing the client. `.defaultMCPBridge` is removed. For a
standalone headless process, use `.localBridge(.nativeHost())`; generic processes
use `.localBridge(.custom(command:arguments:environment:))`. Standalone transports
expose their own native catalog, outside proxy handle routing.

For consumers upgrading across v0.14.0:

| Previous API | Current API |
| --- | --- |
| Fixed timeout per client only | `XcodeMCPRequestOptions.Timeout`: `.configurationDefault`, `.disabled`, `.after(Duration)`. |
| No replay choice | `XcodeMCPRequestOptions.ReplayPolicy`; only a proven rejection before processing can be replayed once. |
| No connection observation/reconnect | `connectionState()`, `connectionStates()`, `reconnect(options:)`. Obtain snapshots from the client rather than constructing them. |
| First-page `listTools()` | `listTools(options:)` loads all pages within one deadline or fails without returning a partial catalog. |
| `callTool` without progress | `callTool(_:arguments:options:onProgress:)`. |
| `notify(_:params:)` | Typed operations or `request(_:params:options:)` for non-tool requests. |
| `MCPJSONValue.init(encoding:)`, `intValue` | `MCPJSONValue.init(_:)`, `integerValue`. |
| Manual text extraction | `MCPToolResult.text`; create text with `MCPContent.text(_:)`. |

Call `close()` explicitly for graceful completion. Deinitialization only requests
cancellation. Test clients use `XcodeMCPTestRuntime.makeClient(configuration:)`
with its default local transport and `recordedToolCalls()` for decoded assertions.
See the [client guide](../../Sources/XcodeMCPKit/README.md) for current examples.

## Embedded server

The current server API is documented in
[XcodeMCPProxyKit](../../Sources/XcodeMCPProxyKit/README.md). For v0.14.0 consumers:

| Previous API | Current API |
| --- | --- |
| Synchronous server `start()`, `startAndWriteDiscovery()` | Configure discovery and call `try await start()`. |
| Server `wait()` | `waitUntilShutdown()`. Use `snapshot()` for sanitized lifecycle/readiness. |
| Server `Configuration.Limits` | Top-level `maxBodyBytes` and `requestTimeout: Duration?`. |
| `configurationFilePath` | Remove file-based tool policy; current configuration is typed. |
| Struct discovery configuration | `.disabled`, `.defaultLocation`, `.file(URL)`. |
| Public launch-plan/parser/product-metadata types | `XcodeMCPProxyServer.run(...)` for CLI hosting. |
| Public installer library APIs | `xcode-mcp-proxy-install` executable; `--dry-run` remains supported. |
| `XcodeMCPProxyStdioAdapter` and its configuration | Removed. Connect clients over Streamable HTTP; Swift clients use the [SDK](../../Sources/XcodeMCPKit/README.md). |
| `TimeInterval` request timeout | Positive `Duration?`; `nil` disables it. CLI `--request-timeout 0` also disables it. |
| `Status.upstreams`, `Status.Upstream.Health`, `queuedRequestCount`, `proxyInitialized`, `catalogAvailable` | `Status.hosts`: one `Status.Host` per Xcode installation, with its `identifier` (the `hostIdentifier` from `XcodeMCPKitListHosts`), `kind`, `state` (`stopped`, `starting`, `running`), and `activeRequestCount`. Requests queue inside each host, and the catalog is available whenever the server runs. |

Server instances are one-shot. Await `shutdown()` for
completion. Cleanup errors preserve the startup failure and remaining resource
information. Delivery-unknown operations are not replayed during HTTP recovery.

## Direct Streamable HTTP clients

Clients upgrading across v0.11.0 must send the server-issued `MCP-Session-Id`
after initialize and send individual JSON-RPC messages instead of batch arrays.
An explicit `MCP-Protocol-Version` must match negotiation. The SDK handles
these details. See the [HTTP contract](../architecture.md#streamable-http-contract)
for expiry, recovery, and header errors.
