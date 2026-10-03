# Troubleshooting

## Native helper cannot be found or started

Keep `XcodeMCPNativeHost.app` beside `xcode-mcp-proxy-server`. Both source and
release installers copy this bundle. Reinstall a complete package if it is
missing; copying only the proxy executable is insufficient.

For a custom layout, supply `--native-host-bundle /path/XcodeMCPNativeHost.app`
or `XCODE_MCP_NATIVE_HOST_BUNDLE`. Embedding code can set
`nativeHostBundleURL`. The server reports a missing executable before binding
its endpoint.

Check the selected installation with `xcode-select -p`. `--developer-dir`,
`DEVELOPER_DIR`, and the embedding `developerDirectoryURL` can select another
Xcode app or developer directory. The host normalizes that selection and
reports missing required frameworks or native API contracts. Xcode 27 / Swift
6.4 is the verified packaging environment; other versions are not rejected by
a manufactured-version allowlist.

## Native catalog or tool request timed out

Confirm that the proxy is running and inspect its error before increasing a
client deadline. The native host supplies the canonical catalog. A stalled or
failed host catalog cannot be replaced with a successful GUI catalog. GUI
catalog refreshes are background routing work and do not block a successful
native host response.

Set `MCP_LOG_LEVEL=debug` to inspect native connection startup, catalog loads,
request cancellation, and recovery. Approve pending connection dialogs when
needed. With `--auto-approve`, grant Accessibility permission to the app that
launches the proxy. Opening a GUI workspace or enabling Xcode Service is not a
prerequisite for the headless catalog.

For workspace operations, check the absolute `workspaceIdentifier` and any
reported GUI owner or tab candidates. An unavailable known GUI owner returns an
error rather than redirecting the operation. A path without a GUI owner loads
through the host's native model. Native tool failures keep their MCP `isError`
result; transport and protocol failures remain request errors.

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

## `XcodeRefreshCodeIssuesInFile` intermittently returns `error 5`
When the proxy runs in `--refresh-code-issues-mode upstream`, Xcode's live diagnostics service is prone to transient failures when `XcodeRefreshCodeIssuesInFile` is fired in bursts for the same `tabIdentifier`.

- The default mode is `proxy`, which serves `XcodeRefreshCodeIssuesInFile` through `XcodeListNavigatorIssues`-style diagnostics to avoid switching Spaces.
- In `upstream` mode, `xcode-mcp-proxy-server` serializes `XcodeRefreshCodeIssuesInFile` per `tabIdentifier` and retries the specific `SourceEditorCallableDiagnosticError error 5` response a small number of times.
- This reduces cold-start contention, but it can increase latency when many refresh requests target the same tab at once.
- Queued refreshes are no longer rejected because of a fixed queue cap, but they still consume the request's end-to-end timeout budget while waiting for their turn.
- If the request deadline is reached before a queued refresh starts running, the proxy returns the same timeout response it would use for an in-flight timeout.
- If you need Xcode's native live diagnostics behavior, start the proxy with `--refresh-code-issues-mode upstream` (or `MCP_XCODE_REFRESH_CODE_ISSUES_MODE=upstream`).

## `session not found`
Ensure the client is using the server-issued `MCP-Session-Id`. Initialize requests must not rely on a caller-provided session id. `DELETE /mcp` permanently terminates the session, and the proxy also expires a session after it has had no in-flight request, open SSE stream, or other client activity for five minutes. A client that receives `404` for a session-bound request must initialize a new session; the bundled SDK and STDIO adapter perform that recovery automatically.

## `protocol version required` / `protocol version mismatch`
An explicit `MCP-Protocol-Version` must match the negotiated supported version.
When it is omitted, the proxy uses the session's negotiated version. Reinitialize
a client that cached an incompatible protocol version.

[apple-xcode-mcp-access]: https://developer.apple.com/documentation/xcode/giving-external-agents-access-to-xcode
