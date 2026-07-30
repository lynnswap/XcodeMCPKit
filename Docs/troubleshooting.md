# Troubleshooting

## `mcpbridge` cannot be executed
`xcode-mcp-proxy-server` spawns `xcrun mcpbridge` as an upstream process.
If it fails:

- Confirm Xcode is installed and selected (`xcode-select -p`).
- Confirm `xcrun mcpbridge -h` works in Terminal.

## `MCP client ... timed out`
Ensure the proxy server is running. Before increasing any timeout, confirm that
Xcode MCP access is enabled as described in
[Set Up Your MCP Client](../README.md#1-enable-xcode-mcp-access). If the proxy
logs `route_activation_timeout`, or `bridge_pool_attach_verification_completed`
with `success=false reason=timeout`, follow the dedicated section below.
Increase `startup_timeout_sec` only when setup is correct and the upstream is
still starting too slowly.

If you see an error like:

- `timed out awaiting tools/list after 10s`

it’s usually because the upstream (`xcrun mcpbridge` / Xcode) was slow on the first `tools/list`.

- `xcode-mcp-proxy-server` prewarms and caches `tools/list` **in memory** once it’s ready, and serves it immediately on subsequent requests.
- The tool list cache is **not persisted to disk**. It survives repeated Codex restarts as long as the proxy server stays running.
- `tools/list` is intentionally treated as stable for the lifetime of the proxy process (no background refresh), to avoid upstream churn and surprise Xcode permission dialogs.

## Xcode tools are unavailable
`route_activation_timeout`, or `bridge_pool_attach_verification_completed` with
`success=false reason=timeout`, means `mcpbridge` initialized but Xcode did not
return a usable `tools/list` response before the route or bridge-attachment
deadline.

First, open your project in Xcode, choose **Xcode > Settings > Intelligence**,
and turn on **Allow external agents to use Xcode tools** under
**Model Context Protocol**. This global switch is required by
[Xcode's external-agent setup][apple-xcode-mcp-access].

`--auto-approve` only handles the per-connection **Allow** dialog; it does not
enable the global Xcode setting. If the setting is already on:

- Approve any pending Xcode connection dialog.
- When using `--auto-approve`, allow the app that launched the proxy (for
  example, Terminal or iTerm) in
  **System Settings > Privacy & Security > Accessibility**.
- Wait for the proxy's automatic retry. A recovered route logs
  `route_activation_cataloged`; a recovered secondary bridge logs
  `bridge_pool_attach_verification_completed` with `success=true`.

When Xcode does not send a JSON-RPC response for `tools/list`, the proxy cannot
recover Xcode's internal error from the stdio transport. The first timeout
therefore prints an **Xcode tools are unavailable** warning with recovery steps
and continues retrying automatically. Later retries keep the structured event
but do not repeat the warning.

## Streamable HTTP client cannot connect
- Ensure `xcode-mcp-proxy-server` is running.
- Confirm the URL is correct (default: `http://localhost:8765/mcp`).
- If you changed the listen address/port, check the discovery file: `~/Library/Caches/XcodeMCPProxy/endpoint.json`.
- Confirm `pid` is alive and `updatedAt` is recent; stale data should be ignored.
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
  - `pkill -f mcpbridge`

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
The proxy only accepts `MCP-Protocol-Version: 2025-06-18` after initialize. Reinitialize the client session if it cached an older protocol version or omitted the header.

[apple-xcode-mcp-access]: https://developer.apple.com/documentation/xcode/giving-external-agents-access-to-xcode
