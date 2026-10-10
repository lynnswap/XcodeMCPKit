# Troubleshooting

## Native helper cannot be found or started

Keep `XcodeMCPNativeHost.app` beside `xcode-mcp-proxy-server`. Both source and
release installers copy this bundle. Reinstall a complete package if it is
missing; copying only the proxy executable is insufficient.

For a custom layout, use `XCODE_MCP_NATIVE_HOST_BUNDLE`. Embedding code can set
`nativeHostBundleURL`. The server reports a missing executable before binding
its endpoint.

Check the selected installation with `xcode-select -p`. `DEVELOPER_DIR` and
the embedding `developerDirectoryURL` can select another
Xcode app or developer directory. The host normalizes that selection and
reports missing required frameworks or native API contracts. Xcode 27 / Swift
6.4 is the verified packaging environment; other versions are not rejected by
a manufactured-version allowlist.

## Native catalog or tool request timed out

Confirm that the proxy is running and inspect its error before increasing a
client deadline. Set `MCP_LOG_LEVEL=debug` to inspect native initialization,
catalog loads, cancellation, and recovery. Check the selected Xcode installation
for missing framework or API contracts.

For workspace operations, check the absolute `workspaceIdentifier` and save
project/source changes to disk. Inspect and select the host's scheme, destination,
and test plan. GUI selection and unsaved editor state do not configure the host.
Native tool failures keep their MCP `isError` result; transport and protocol
failures remain request errors. Headless startup does not require agent-access
approval or changes to Xcode's permission store.

If a native error was suppressed, inspect `Native error presentation suppressed`
in the host's stderr or the failed tool result for its domain, code, and context.
The host closes removed saved workspaces before subsequent tool execution. A
remaining cleanup failure is reported as `Native workspace cleanup failed`;
inspect that failure before retrying an operation against the removed workspace.

## CoreSimulator service connection becomes invalid

When CoreSimulator declares that Simulator services are no longer available to
the native host, the proxy replaces its owned host and initializes the replacement.
Requests interrupted by replacement fail with `upstream unavailable`; operations
whose completion is unknown are not replayed automatically.

Replacement invalidates native workspace identifiers and sessions. Use the
absolute project path to load a workspace again, then inspect its scheme,
destination, and test plan before continuing device or build operations.

Recovery recognizes the known terminal CoreSimulator diagnostics emitted by
`xcode-mcp-native-host`. Ordinary connection interruptions and tool errors keep
their existing behavior. If a newer CoreSimulator changes its diagnostic wording,
automatic detection may not apply; restart the server to reload its native host.

## DocumentationSearch is unavailable

The startup summary reports whether the native catalog contains the tool; it
is not a search execution test. At startup the host selects the latest readable
installed documentation index and sets its location only for that process.
A saved `IDEChatDocumentationSearchConfigURL` override is not required.

If the helper reports `no installed documentation index found`, check that
Xcode's developer documentation has been installed. Asset discovery failures
are logged on stderr and do not prevent other native tools from starting. When
no installed index can be selected, the existing Xcode configuration remains
in effect. Restart the server after installing documentation, then call the tool
to verify the search itself.

## Streamable HTTP client cannot connect
- Set `MCP_LOG_LEVEL=debug` when per-connection and per-request access logs are
  needed; routine HTTP traffic is not printed at the default log level.
- Ensure `xcode-mcp-proxy-server` is running.
- Confirm the URL is correct (default: `http://localhost:8765/mcp`).
- If you changed the listen address/port, check the discovery file: `~/Library/Caches/XcodeMCPProxy/endpoint.json`.
- Treat the discovery record as a URL hint; connect and initialize to check reachability.
- Ensure `POST /mcp` sends `Content-Type: application/json` and `Accept: application/json, text/event-stream`.
- After initialize, ensure the client sends the server-issued `MCP-Session-Id` and `MCP-Protocol-Version: 2025-06-18`.

## `Address already in use` / `errno: 48`
Another process is already listening on the same port (default: `8765`).

- Stop the existing proxy server and retry:
  - `pkill -x xcode-mcp-proxy-server`
- Or rerun with `--force-restart` to terminate an existing `xcode-mcp-proxy-server` automatically:
  - `xcode-mcp-proxy-server --force-restart`

## STDIO adapter cannot connect
Ensure the proxy server is running and you are launching the adapter with `xcode-mcp-proxy`.
If you changed the server URL, pass it explicitly:

- `xcode-mcp-proxy --url http://localhost:9000/mcp`

or set `XCODE_MCP_PROXY_ENDPOINT` to the server URL. The discovery file should exist at `~/Library/Caches/XcodeMCPProxy/endpoint.json`.

## Codex `tools/call` times out after 60 seconds
Increase `tool_timeout_sec` in `~/.codex/config.toml` (this is client-side and separate from the proxy `--request-timeout`).

```toml
[mcp_servers.xcode]
command = "xcode-mcp-proxy"
args = []
tool_timeout_sec = 300
```

If you configured Codex via `--url`, set `tool_timeout_sec` on the URL server entry instead:

```toml
[mcp_servers.xcode]
url = "http://localhost:8765/mcp"
tool_timeout_sec = 300
```

## Codex shows `Transport closed` (then hangs)
If you see an error like:

- `tools/call failed: Transport closed`

it usually means the MCP server process (`xcode-mcp-proxy`) was terminated while Codex was waiting (often due to the default `tool_timeout_sec` being too short for slow Xcode operations).

- Set `tool_timeout_sec` (see above) to a value that covers the slowest Xcode tool calls you expect.
- Ensure the proxy server (`xcode-mcp-proxy-server`) is running and the discovery file is fresh: `~/Library/Caches/XcodeMCPProxy/endpoint.json`.
- If it keeps happening, restart the local processes:
  - `pkill -f xcode-mcp-proxy`
  - Restart the proxy through its normal launcher so it can stop its owned native helpers.

## Native code diagnostics

`XcodeRefreshCodeIssuesInFile` executes in its owning native Xcode context.
The proxy forwards native diagnostics, progress and errors. It does not replace
the response with navigator issues or retry a failed diagnostic operation.

## `session not found`
Ensure the client is using the server-issued `MCP-Session-Id`. Initialize requests must not rely on a caller-provided session id. `DELETE /mcp` permanently terminates the session, and the proxy also expires a session after it has had no in-flight request, open SSE stream, or other client activity for five minutes. A client that receives `404` for a session-bound request must initialize a new session; the bundled SDK and STDIO adapter perform that recovery automatically.

## `protocol version required` / `protocol version mismatch`
An explicit `MCP-Protocol-Version` must match the negotiated supported version.
When it is omitted, the proxy uses the session's negotiated version. Reinitialize
a client that cached an incompatible protocol version.
