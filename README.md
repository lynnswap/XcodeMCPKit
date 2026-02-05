# XcodeMCPProxy

[日本語](README.ja.md)

An MCP proxy for Xcode MCP (`mcpbridge`).  
The Xcode permission dialog appears once when the proxy starts.

## Quick Start

1. Start the proxy
   ```bash
   scripts/run_proxy.sh
   ```
2. Point your client to `http://127.0.0.1:8765/mcp`
3. Click **Allow** in Xcode’s permission dialog

For Codex over STDIO, use `xcode-mcp-proxy --stdio` (it starts HTTP/SSE + STDIO in one process).  
Alternatively, `xcode-mcp-stdio-proxy` runs the STDIO adapter separately and connects to an existing proxy.

## Features

- `mcpbridge` runs as a **single process**
- Multi-client support via `Mcp-Session-Id`
- JSON-RPC over HTTP + SSE (Streamable MCP)

Architecture: `Docs/architecture.md`

## Usage

### Run Script

```bash
scripts/run_proxy.sh
```

Optional environment variables:

- `HOST` (default: `127.0.0.1`)
- `PORT` (default: `8765`)
- `LISTEN` (overrides host/port)
- `XCODE_PID` (optional)
- `LAZY_INIT` (set to any value to pass `--lazy-init`)
- `STDIO` (enable STDIO mode)
- `STDIO_NO_PROXY` (use the separate STDIO adapter and connect to an existing proxy)
- `STDIO_FRAMING` (`ndjson` or `content-length`)

### Manual Start

```bash
swift run xcode-mcp-proxy --listen 127.0.0.1:8765
```

The proxy initializes the Xcode MCP session at startup so the permission dialog appears immediately. Use `--lazy-init` to defer initialization until the first client request.

To target a specific Xcode process:

```bash
swift run xcode-mcp-proxy --xcode-pid 12345
```

### STDIO Mode (Codex)

```bash
swift run xcode-mcp-proxy --stdio
```

This starts the HTTP/SSE proxy and STDIO adapter in one process.

To run the STDIO adapter separately:

```bash
swift run xcode-mcp-stdio-proxy --no-spawn-proxy --proxy-url http://127.0.0.1:8765/mcp
```

For `scripts/run_proxy.sh`, use `STDIO=1`.  
If the HTTP/SSE proxy is already running, set `STDIO_NO_PROXY=1` to avoid starting it again.

## Defaults

- Listen address: `127.0.0.1:8765`
- `mcpbridge` command: `xcrun`
- `mcpbridge` args: `mcpbridge`
- Request timeout: `300` seconds (`0` disables)
- Max body size: `1048576` bytes
- Initialization: eager at startup

Environment variables:

- `MCP_XCODE_PID` (alternative to `--xcode-pid`)
- `MCP_XCODE_SESSION_ID` (fix the Xcode MCP session id)
- `MCP_LOG_LEVEL` (log level: trace|debug|info|notice|warning|error|critical)

Logs are written to stderr.

## Options

| Option | Description |
|--------|-------------|
| `--listen host:port` | Listen address |
| `--host host` | Listen host |
| `--port port` | Listen port |
| `--stdio` | Run STDIO adapter alongside HTTP/SSE proxy |
| `--stdio-framing kind` | `ndjson` or `content-length` |
| `--upstream-command cmd` | `mcpbridge` command |
| `--upstream-args a,b,c` | `mcpbridge` args (comma-separated) |
| `--upstream-arg value` | Append a single `mcpbridge` arg |
| `--xcode-pid pid` | Xcode PID |
| `--session-id id` | Xcode MCP session id |
| `--max-body-bytes n` | Max request body size |
| `--request-timeout seconds` | Request timeout (`0` disables) |
| `--lazy-init` | Delay initialization until first request |

## Client Config

**Claude Code** (`~/.claude/settings.json`):

```json
{ "mcpServers": { "xcode": { "url": "http://127.0.0.1:8765/mcp" } } }
```

**Codex** (`~/.codex/config.toml`):

```toml
[mcp_servers.xcode]
url = "http://127.0.0.1:8765/mcp"
```

**Codex (STDIO)**:

```bash
codex mcp add xcode -- xcode-mcp-proxy --stdio
```

This starts the HTTP/SSE proxy and STDIO adapter in one process.  
If you want the STDIO adapter separately, use `xcode-mcp-stdio-proxy --no-spawn-proxy`.

## Endpoints

- `POST /mcp` (JSON-RPC; responds with JSON or SSE and returns `Mcp-Session-Id`)
- `GET /mcp` (SSE; requires `Mcp-Session-Id` and `Accept: text/event-stream`)
- `GET /events`, `GET /mcp/events` (SSE aliases)
- `DELETE /mcp` (close session)
- `GET /health`

## Sessions & Multiple Clients

- Use a **unique `Mcp-Session-Id` per client**.
- If `initialize` is sent without `Mcp-Session-Id`, the proxy generates one and returns it in the response header.
- For SSE, include `Mcp-Session-Id` on `GET /mcp`.

## Troubleshooting

- `mcpbridge` fails to run  
  Apple documentation notes:

  > In Terminal, use the xcrun mcpbridge command to configure the agentic coding tool to use Xcode Tools.

  Reference: [Giving external agentic coding tools access to Xcode](https://developer.apple.com/documentation/Xcode/giving-agentic-coding-tools-access-to-xcode#Configure-external-coding-tools-to-use-the-MCP-server)

  ```bash
  claude mcp add --transport stdio xcode -- xcrun mcpbridge
  codex mcp add xcode -- xcrun mcpbridge
  ```

- `MCP client ... timed out`  
  Ensure the proxy is running, then increase `startup_timeout_sec` if needed.

- Codex `tools/call` times out after 60 seconds  
  Increase `tool_timeout_sec` in `~/.codex/config.toml` (this is a Codex client-side timeout and is separate from the proxy `--request-timeout`).
  ```toml
  [mcp_servers.xcode]
  url = "http://127.0.0.1:8765/mcp"
  tool_timeout_sec = 300
  ```

- STDIO adapter fails to start  
  If the HTTP/SSE proxy is already running, use `xcode-mcp-stdio-proxy --no-spawn-proxy` (or `STDIO_NO_PROXY=1` with `scripts/run_proxy.sh`) so the adapter does not try to start another proxy.

- Permission dialog does not appear  
  If `--lazy-init` is enabled, the dialog appears on the first request instead of startup.

- `session not found`  
  Verify the `Mcp-Session-Id` matches the session that was initialized.

## License

[LICENSE](LICENSE)
