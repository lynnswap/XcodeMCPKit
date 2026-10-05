# Configuration

For installation and MCP client registration, see the
[README quick start](../README.md#quick-start).

## Xcode compatibility

The selected installation's native contracts determine available tools; the
server does not use a version allowlist or switch installations after failure.
Missing frameworks or API contracts produce initialization diagnostics.

Xcode 27 / Swift 6.4 on macOS 26.6.2 is the verified environment for headless
initialization and saved-project operations with SIP and AMFI enabled. Other
installations need their own validation. Catalog discovery does not establish
that every tool works: previews, device operations, and account-dependent tools
can require permissions or services beyond those used by build and test.

The headless host uses the selected Xcode installation. The standard
`DEVELOPER_DIR` environment variable can select another installation:

```bash
DEVELOPER_DIR=/Applications/Xcode_27.0.app/Contents/Developer xcode-mcp-proxy-server
```

## Server options

Use `xcode-mcp-proxy-server --help` and `xcode-mcp-proxy --help` for CLI usage.

| Option | Description |
| --- | --- |
| `--listen host:port` | Listen address. Defaults to `localhost:8765`; cannot be combined with `--host` or `--port`. |
| `--host host` / `--port port` | Listen host and port when `--listen` is not used. Port `0` selects an available port. |
| `--request-timeout seconds` | Request timeout. `0` disables non-initialize timeouts; initialization remains bounded. |
| `--max-body-bytes bytes` | Maximum accepted HTTP request body size. |
| `--force-restart` | Terminate an existing `xcode-mcp-proxy-server` on the listen port before starting. |
| `--dry-run` | Print the resolved server command without starting it. |

## Environment variables

| Variable | Description |
| --- | --- |
| `LISTEN` | Listen address, for example `127.0.0.1:8765`. |
| `HOST` / `PORT` | Listen host and port when `LISTEN` is unset. |
| `XCODE_MCP_NATIVE_HOST_BUNDLE` | Helper bundle override for custom embedded/install layouts. |
| `DEVELOPER_DIR` | Xcode selection for the native host. |
| `MCP_LOG_LEVEL` | `trace`, `debug`, `info`, `notice`, `warning`, `error`, or `critical`. Defaults to `info`; `debug` includes HTTP access and routing telemetry. |
| `XCODE_MCP_PROXY_ENDPOINT` | STDIO adapter upstream URL. `--url` takes precedence. |
| `XCODE_MCP_PROXY_DISCOVERY_FILE` | Discovery file override for isolated local/live test runs. |
| `XCODE_MCP_PROXY_CACHE_ROOT` | Cache root for the discovery path when `XCODE_MCP_PROXY_DISCOVERY_FILE` is unset. |
