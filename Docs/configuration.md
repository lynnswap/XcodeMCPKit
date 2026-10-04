# Configuration

For installation and MCP client registration, see the
[README quick start](../README.md#quick-start).

## Xcode compatibility

The installed frameworks' contracts determine available tools. These are verified
installations, not a version allowlist:

| Installation | Verified behavior |
| --- | --- |
| Xcode 27 / Swift 6.4 | Native packaging, headless tools, and GUI tools. |
| Xcode 26.6 | GUI tools with a workspace open; headless initialization lacks a required native contract. |

The server keeps the selected developer directory and reports missing framework
or API contracts. It does not switch SDKs to make headless initialization pass.
Usable GUI catalogs remain available when the selected headless host cannot initialize.

The headless host uses the selected Xcode installation. The standard
`DEVELOPER_DIR` environment variable can select another installation:

```bash
DEVELOPER_DIR=/Applications/Xcode_27.0.app/Contents/Developer xcode-mcp-proxy-server
```

GUI operations use the installation that owns the workspace, even when it
differs from the headless selection. See [workspace routing](usage.md#select-a-workspace).

## Server options

Use `xcode-mcp-proxy-server --help` and `xcode-mcp-proxy --help` for CLI usage.

| Option | Description |
| --- | --- |
| `--listen host:port` | Listen address. Defaults to `localhost:8765`; cannot be combined with `--host` or `--port`. |
| `--host host` / `--port port` | Listen host and port when `--listen` is not used. Port `0` selects an available port. |
| `--request-timeout seconds` | Request timeout. `0` disables non-initialize timeouts; initialization remains bounded. |
| `--auto-approve` | Approve recognized Xcode access dialogs for all agents. Requires Accessibility permission. |
| `--max-body-bytes bytes` | Maximum accepted HTTP request body size. |
| `--force-restart` | Terminate an existing `xcode-mcp-proxy-server` on the listen port before starting. |
| `--dry-run` | Print the resolved server command without starting it. |

## Environment variables

| Variable | Description |
| --- | --- |
| `LISTEN` | Listen address, for example `127.0.0.1:8765`. |
| `HOST` / `PORT` | Listen host and port when `LISTEN` is unset. |
| `XCODE_MCP_NATIVE_HOST_BUNDLE` | Helper bundle override for custom embedded/install layouts. |
| `DEVELOPER_DIR` | Xcode selection for the headless host; GUI connections use their owning installation. |
| `MCP_LOG_LEVEL` | `trace`, `debug`, `info`, `notice`, `warning`, `error`, or `critical`. Defaults to `info`; `debug` includes HTTP access and routing telemetry. |
| `XCODE_MCP_PROXY_ENDPOINT` | STDIO adapter upstream URL. `--url` takes precedence. |
| `XCODE_MCP_PROXY_DISCOVERY_FILE` | Discovery file override for isolated local/live test runs. |
| `XCODE_MCP_PROXY_CACHE_ROOT` | Cache root for the discovery path when `XCODE_MCP_PROXY_DISCOVERY_FILE` is unset. |
