# Troubleshooting

## A workspace operation uses the wrong state

Call `XcodeListWorkspaces` and use the returned `workspaceIdentifier`. GUI entries
use that Xcode tab's state; headless entries use saved files and their native
model's scheme, destination, and test plan. Two tabs for the same path can differ.
Do not pass a native `tabIdentifier` or call the removed `XcodeMCPKitSelectHost`.
See [migration](migrations/native-backend.md#workspace-and-host-routing) for older
clients and scripts.

If a host or MCP session restarted, list or open the workspace again. Workspace
and device-session identifiers from the old context are invalid. A GUI process
that has exited is not replaced with a headless model automatically. Reopen the
intended GUI workspace or explicitly open a saved model.

## An operation is unavailable

The public catalog describes stable proxy operations. Availability still depends
on the workspace's Xcode installation and native context. Read the tool error
for the unsupported operation or missing native contract. A public schema does
not guarantee that every installed Xcode supports that operation.

For a stale client catalog after upgrading the server, restart the MCP client.
New calls use `workspaceIdentifier` for GUI and headless work alike. Routing does
not require the client to refresh definitions after opening another workspace.

## The native helper cannot be found or started

Keep `XcodeMCPNativeHost.app` beside `xcode-mcp-proxy-server`. Reinstall the complete
package if the helper is missing; copying only the command is insufficient.
Custom layouts can use `XCODE_MCP_NATIVE_HOST_BUNDLE` or the embedding
`nativeHostBundleURL` property.

Check the `Selected Xcode` startup log. The server tries its explicit developer
directory, `DEVELOPER_DIR`, and `xcode-select -p` before discovering installations.
Unavailable selections fall through to discovery. Set `DEVELOPER_DIR` or the
embedding `developerDirectoryURL` to prefer an app. Missing native contracts
produce initialization diagnostics; the server does not switch installations
after such a failure. See [Xcode compatibility](configuration.md#xcode-compatibility).

## A tool request times out

Inspect the proxy/helper error before increasing deadlines. `MCP_LOG_LEVEL=debug`
shows HTTP, initialization, catalog, cancellation, and recovery telemetry.
Confirm the workspace path exists, save headless source/project changes, and
inspect the owning workspace's scheme, destination, and test plan. GUI selections
do not configure a separate headless model.

A `Native error presentation suppressed` message retains the native domain,
code, and context in stderr or the tool failure. `Native workspace cleanup failed`
reports cleanup of a removed model; resolve that failure before retrying against
the same removed workspace.

The proxy, SDK, and adapter default to 600 seconds. `RenderPreview` defaults to
300 seconds for build/render work, with initial preparation and cleanup outside
that budget. Give the external client enough time for the entire request.
For Codex, set `tool_timeout_sec` in the registered server entry, for example:

```toml
[mcp_servers.xcode]
url = "http://localhost:8765/mcp"
tool_timeout_sec = 600
```

For STDIO registrations, keep the existing `command`/`args` and add the same
`tool_timeout_sec` setting. A closed transport can also mean a process exited;
check server stderr and reachability instead of treating every disconnect as a
timeout.

## CoreSimulator disconnects from the native host

Known terminal CoreSimulator diagnostics trigger replacement of the affected
owned host. Interrupted requests fail; delivery-unknown operations are not
replayed. Obtain fresh workspace/device-session identifiers, then inspect scheme,
destination, and test plan before continuing. If a newer runtime changes the
diagnostic and automatic recovery does not occur, restart the server.

## DocumentationSearch is unavailable

The native host selects the latest readable installed documentation index at
startup. If it reports `no installed documentation index found`, install Xcode's
developer documentation and restart the server. Selection failure does not block
other tools and leaves Xcode's existing configuration in effect. A catalog entry
proves discovery only; call the tool to verify search execution.

## HTTP or STDIO cannot connect

Ensure the proxy is running and check its URL, normally
`http://localhost:8765/mcp`. The discovery record at
`~/Library/Caches/XcodeMCPProxy/endpoint.json` is a URL hint, not proof that the
server is reachable. For a different STDIO endpoint, use:

```sh
xcode-mcp-proxy --url http://localhost:9000/mcp
```

`XCODE_MCP_PROXY_ENDPOINT` also configures the adapter; `--url` takes precedence.
For `Address already in use` / `errno: 48`, stop the known listener or use
`xcode-mcp-proxy-server --force-restart` to replace a proxy on the selected port.

Direct HTTP clients must send `Content-Type: application/json` and
`Accept: application/json, text/event-stream` for POST. After initialize, use the
server-issued `MCP-Session-Id`. An explicit `MCP-Protocol-Version` must match the
negotiated supported version; omitted versions use the session's negotiation.
See the [HTTP contract](architecture.md#streamable-http-contract).

`session not found` means the ID is unknown, deleted, or expired. Initialize a
new session after `404`; the SDK and STDIO adapter handle this recovery. Sessions
expire after five minutes without client activity, an in-flight request, or an
open SSE stream. Recovered MCP sessions require fresh workspace/session handles.
For `protocol version required` or `protocol version mismatch`, reinitialize a
client that retained an incompatible negotiated version.

## Native code diagnostics differ from the navigator

`XcodeRefreshCodeIssuesInFile` runs in its owning native workspace. It returns
native diagnostics, progress, and errors. The proxy does not substitute navigator
issues or retry a failed diagnostic operation through another backend.
