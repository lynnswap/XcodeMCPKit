# Migration

Restart the proxy and connected MCP clients after upgrading so clients load the
current public tool definitions. Installation instructions are in the
[quick start](../../README.md#quick-start).

## Workspace and host routing

Open a saved project with `XcodeOpenWorkspace`, then pass its returned
`workspaceIdentifier` to an operation. The identifier retains its native
headless workspace and host. `XcodeListWorkspaces` lists loaded headless models;
proxy operations do not connect to GUI Xcode.

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

`ListCrashIssues` replaces `GetTopCrashIssues`. Replace `count` with `page` and
`page_size`, then follow `pagination.nextPage` until it is null. Read structured
`issues` instead of parsing the old `data` string.

`GetCrashIssue` replaces `GetCrashIssueLogs`. Pass `issue_id` from the list's
`issueId` instead of `signature_name`. It returns structured device trends and
local sample-log paths. Its distributions cover all versions and channels;
`app_version` filters sample logs only, and `is_beta` is unsupported for detail.

Check `status`, `errors`, and `provenance` when saving or updating results.
See [crash collection](../usage.md#collect-crash-reports) for query scopes,
pagination, caching, and metric definitions. Restart connected clients to load
the replacement tool definitions.

## Native helper and server configuration

Install `XcodeMCPNativeHost.app` beside the proxy commands. Reinstall the complete
package if it is missing. The default helper executes headlessly through the
selected Xcode's frameworks, without Xcode Service setup or an open GUI window.

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
