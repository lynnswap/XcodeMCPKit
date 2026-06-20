# XcodeMCPKit

[日本語](README.ja.md)

XcodeMCPKit is a local proxy for Xcode MCP. It gives your MCP clients one stable
endpoint and automates the `mcpbridge` approval flow.

## Requirements

- macOS 15.0+
- Swift 6.2+

## Install

### From GitHub Releases

- `xcode-mcp-proxy-darwin-arm64.tar.gz`
- `SHA256SUMS.txt`

```bash
VERSION=v0.11.0
BASE_URL="https://github.com/lynnswap/XcodeMCPKit/releases/download/${VERSION}"

ARCHIVE="xcode-mcp-proxy-darwin-arm64.tar.gz"
curl -fL -O "${BASE_URL}/${ARCHIVE}"
curl -fL -O "${BASE_URL}/SHA256SUMS.txt"
grep "  ${ARCHIVE}\$" SHA256SUMS.txt | shasum -a 256 -c

tar -xzf "${ARCHIVE}"
mkdir -p "${HOME}/.local/bin"
install -m 755 bin/xcode-mcp-proxy "${HOME}/.local/bin/"
install -m 755 bin/xcode-mcp-proxy-server "${HOME}/.local/bin/"
```

### From Source

Installs both the proxy server and the STDIO adapter:

```bash
swift run -c release xcode-mcp-proxy-install
```

Custom destination:

```bash
swift run -c release xcode-mcp-proxy-install --prefix "$HOME/.local"
swift run -c release xcode-mcp-proxy-install --bindir "$HOME/bin"
```

Add to `PATH`:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

## Set Up Your MCP Client

### 1. Start the Proxy Server

```bash
xcode-mcp-proxy-server --auto-approve
```

- Recommended default.
- Keep it running while MCP clients use Xcode.
- Requires macOS Accessibility permission.

Without Accessibility permission:

```bash
xcode-mcp-proxy-server
```

### 2. Register the Client

Replace `xcrun mcpbridge` with the proxy endpoint.

#### Codex

```bash
codex mcp remove xcode

# Recommended: Streamable HTTP
codex mcp add xcode --url http://localhost:8765/mcp

# Compatibility mode: STDIO
codex mcp add xcode -- xcode-mcp-proxy
```

#### Claude Code

```bash
claude mcp remove xcode

# Recommended: Streamable HTTP
claude mcp add --transport http xcode http://localhost:8765/mcp

# Compatibility mode: STDIO
claude mcp add --transport stdio xcode -- xcode-mcp-proxy
```

## Configuration

Full CLI surface:

```bash
xcode-mcp-proxy-server --help
xcode-mcp-proxy --help
```

### Common Server Options

| Option | Description |
|--------|-------------|
| `--listen host:port` | Listen address. Defaults to `localhost:8765`. |
| `--host host` / `--port port` | Listen host and port when `--listen` is not used. |
| `--upstream-processes n` | Number of upstream `mcpbridge` processes. Default: `1`, max: `10`. |
| `--request-timeout seconds` | Request timeout. `0` disables non-initialize timeouts; initialize still has a bounded handshake timeout. |
| `--config path` | TOML config path. |
| `--auto-approve` | Automatically approve the Xcode permission dialog. Requires Accessibility permission. |
| `--refresh-code-issues-mode proxy|upstream` | Serve `XcodeRefreshCodeIssuesInFile` through proxy diagnostics (`proxy`, default) or pass through to Xcode live diagnostics (`upstream`). |
| `--force-restart` | Terminate an existing `xcode-mcp-proxy-server` on the listen port and start a new one. |

### Environment Variables

| Variable | Description |
|----------|-------------|
| `LISTEN` | Listen address, for example `127.0.0.1:8765`. |
| `HOST` / `PORT` | Listen host and port when `LISTEN` is unset. |
| `MCP_XCODE_PID` | Passed through to upstream `mcpbridge`; the proxy does not interpret it. |
| `MCP_XCODE_SESSION_ID` | Optional explicit upstream Xcode MCP session ID. |
| `MCP_XCODE_CONFIG` | TOML config path. `--config` takes precedence. |
| `MCP_XCODE_REFRESH_CODE_ISSUES_MODE` | `proxy` or `upstream`. |
| `MCP_LOG_LEVEL` | `trace`, `debug`, `info`, `notice`, `warning`, `error`, or `critical`. |
| `XCODE_MCP_PROXY_ENDPOINT` | STDIO adapter upstream URL. `--url` takes precedence. |
| `XCODE_MCP_PROXY_DISCOVERY_FILE` | Discovery file override for isolated local/live test runs. |
| `XCODE_MCP_PROXY_CACHE_ROOT` | Cache root used to derive the discovery path when `XCODE_MCP_PROXY_DISCOVERY_FILE` is unset. |

### TOML Config

```toml
[upstream_handshake]
clientName = "XcodeMCPKit"

[tools]
disabled = ["RunAllTests", "RunSomeTests"]
```

| Key | Type | Default |
|-----|------|---------|
| `upstream_handshake.clientName` | string | `"XcodeMCPKit"` |
| `upstream_handshake.clientVersion` | string | `"dev"` |
| `upstream_handshake.capabilities` | table | `{}` |
| `tools.disabled` | array of strings | `[]` |

- Omitted `clientVersion`: resolved from Xcode's matching `IDEChat*Version`
  defaults entry when available.
- Disabled tools: removed from `tools/list` and rejected on direct `tools/call`.
- Config changes require restarting `xcode-mcp-proxy-server`.

## Migration

### v0.11.0

Most Codex and Claude Code setups do not need a manual migration. Check these
only if they apply:

- If you call the Streamable HTTP endpoint directly, use the server-issued
  `MCP-Session-Id`, send `MCP-Protocol-Version: 2025-06-18` after `initialize`,
  include `Accept: application/json, text/event-stream` on `POST /mcp`, and stop
  sending JSON-RPC batch requests.
- If you depended on the old SwiftPM library product, pin to `v0.10.2` or
  migrate to the executable products.

## Troubleshooting

- [Troubleshooting](Docs/troubleshooting.md)

## Maintainers

Local checks:

```bash
swift test -Xswiftc -strict-concurrency=minimal
XCODE_MCP_RUN_PROCESS_TESTS=1 swift test --no-parallel --filter ProxyProcessTests -Xswiftc -strict-concurrency=minimal
scripts/check.sh
```

Release:

```bash
scripts/publish-local-release.sh v0.11.0
```

- Module boundaries, release flow, live tests, benchmarks:
  [Maintainer Architecture](Docs/maintainer-architecture.md)

## More Documentation

- [Architecture](Docs/architecture.md)
- [Troubleshooting](Docs/troubleshooting.md)
- [MCP / Xcode MCP Benchmark Notes](Docs/mcp-benchmark.md)
- [MCP Connection Permission Dialog Investigation](Docs/mcp-permission-dialog-investigation.md)

## License

[LICENSE](LICENSE)
