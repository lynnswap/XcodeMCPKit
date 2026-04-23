# XcodeMCPKit

[日本語](README.ja.md)

An MCP proxy for Xcode MCP (mcpbridge).  
Designed so the Xcode permission dialog appears once when the proxy starts.

## Quick Start

1. Start the proxy server
   ```bash
   xcode-mcp-proxy-server
   ```
2. Click **Allow** in Xcode’s permission dialog

## Architecture

See [Architecture](Docs/architecture.md) for the process overview.
See [Maintainer Architecture](Docs/maintainer-architecture.md) for module boundaries and local verification commands.

## Installation

### 1. Install the binaries

#### Build from source

```bash
swift run -c release xcode-mcp-proxy-install
```

#### Install from GitHub Releases

Each release tag (`v*`) publishes:

- `xcode-mcp-proxy.tar.gz` (universal binary)
- `xcode-mcp-proxy-darwin-arm64.tar.gz`
- `xcode-mcp-proxy-darwin-x86_64.tar.gz`
- `SHA256SUMS.txt`

Example:

```bash
VERSION=v0.1.0
BASE_URL="https://github.com/lynnswap/XcodeMCPKit/releases/download/${VERSION}"

ARCHIVE="xcode-mcp-proxy.tar.gz"
curl -fL -O "${BASE_URL}/${ARCHIVE}"
curl -fL -O "${BASE_URL}/SHA256SUMS.txt"
grep "  ${ARCHIVE}\$" SHA256SUMS.txt | shasum -a 256 -c

tar -xzf "${ARCHIVE}"
mkdir -p "${HOME}/.local/bin"
cp bin/* "${HOME}/.local/bin/"
chmod +x "${HOME}/.local/bin/xcode-mcp-proxy" \
         "${HOME}/.local/bin/xcode-mcp-proxy-server" \
         "${HOME}/.local/bin/xcode-mcp-proxy-install"
```

If you prefer a platform-specific archive, choose one of:

- `xcode-mcp-proxy.tar.gz`: universal binary
- `xcode-mcp-proxy-darwin-arm64.tar.gz`: Apple Silicon
- `xcode-mcp-proxy-darwin-x86_64.tar.gz`: Intel

#### Optional: change the installation destination

```bash
./.build/release/xcode-mcp-proxy-install --prefix "$HOME/.local"
# or
./.build/release/xcode-mcp-proxy-install --bindir "$HOME/bin"
```

### 2. Add the install directory to your `PATH`

By default, `xcode-mcp-proxy` and `xcode-mcp-proxy-server` are installed to `~/.local/bin`.

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

### 3. Register the proxy in your MCP client

Replace `xcrun mcpbridge` with one of the following:

#### Codex

```bash
codex mcp remove xcode
# Recommended: Streamable HTTP
codex mcp add xcode --url http://localhost:8765/mcp

# Alternative: STDIO
codex mcp add xcode -- xcode-mcp-proxy
```

#### Claude Code

```bash
claude mcp remove xcode
claude mcp add --transport stdio xcode -- xcode-mcp-proxy
```

## Usage

### Proxy Server: `xcode-mcp-proxy-server`

See Quick Start for how to launch.

#### Defaults

- command: `xcrun`
- args: `mcpbridge`
- upstream processes: `1` (spawns multiple `mcpbridge` processes when increased)
- listen: `localhost:8765`
- request timeout: `300` seconds (`0` disables)
- requests sharing the same MCP session are forwarded FIFO, one at a time
- max body size: `1048576` bytes
- initialization: eager at startup
- discovery: `~/Library/Caches/XcodeMCPProxy/endpoint.json`

#### Options

| Option | Description |
|--------|-------------|
| `--upstream-command cmd` | `mcpbridge` command |
| `--upstream-args a,b,c` | `mcpbridge` args (comma-separated) |
| `--upstream-arg value` | Append a single `mcpbridge` arg |
| `--upstream-processes n` | Spawn `n` upstream `mcpbridge` processes (default: 1, max: 10) |
| `--session-id id` | Explicit Xcode MCP session ID |
| `--max-body-bytes n` | Max request body size |
| `--request-timeout seconds` | Request timeout (`0` disables non-initialize timeouts; `initialize` still uses a bounded handshake timeout) |
| `--config path` | Path to proxy config TOML for overriding the upstream handshake |
| `--auto-approve` | Opt in to auto-approve the Xcode permission dialog |
| `--refresh-code-issues-mode mode` | Serve `XcodeRefreshCodeIssuesInFile` via proxy navigator issues (`proxy`, default) or pass through to Xcode live diagnostics (`upstream`) |
| `--force-restart` | If the listen port is in use, terminate an existing `xcode-mcp-proxy-server` and restart |

#### Environment Variables

| Variable | Description |
|----------|-------------|
| `LISTEN` | Listen address; example: `127.0.0.1:8765` |
| `HOST` | Listen host; used with `PORT` when `LISTEN` is unset |
| `PORT` | Listen port; used with `HOST` when `LISTEN` is unset |
| `MCP_XCODE_PID` | Passed through to upstream `mcpbridge`; the proxy itself does not parse it |
| `MCP_XCODE_SESSION_ID` | Optional explicit upstream session ID |
| `MCP_XCODE_CONFIG` | Proxy config TOML path; `--config` takes precedence |
| `MCP_XCODE_REFRESH_CODE_ISSUES_MODE` | `proxy` or `upstream` |
| `MCP_LOG_LEVEL` | Log level: `trace`, `debug`, `info`, `notice`, `warning`, `error`, `critical` |
| `XCODE_MCP_PROXY_DISCOVERY_FILE` | Override the discovery file path for isolated local/live test runs |
| `XCODE_MCP_PROXY_CACHE_ROOT` | Override the cache root used to derive the discovery path when `XCODE_MCP_PROXY_DISCOVERY_FILE` is unset |

Logs are written to stderr.

## Maintainer Commands

```bash
scripts/check-architecture.sh
scripts/test-fast.sh
scripts/test-process.sh
scripts/check.sh
scripts/test-live-mcpbridge.sh
```

- `test-live-mcpbridge.sh` is local-only and intentionally excluded from CI.
- The live script uses the currently running Xcode session, requires exactly one Xcode process, uses `127.0.0.1:0`, and writes discovery output under a temp path.

#### Proxy Config

| Key | Type | Default |
|-----|------|---------|
| `upstream_handshake.protocolVersion` | string | `"2025-03-26"` |
| `upstream_handshake.clientName` | string | `"XcodeMCPKit"` |
| `upstream_handshake.clientVersion` | string | `"dev"` |
| `upstream_handshake.capabilities` | table | `{}` |
| `tools.disabled` | array of strings | `[]` |

If `clientVersion` is omitted, the proxy auto-resolves it from the Xcode `IDEChat*Version` entry matching `clientName` when available.

Example:

```toml
[upstream_handshake]
clientName = "XcodeMCPKit"

[tools]
disabled = ["RunAllTests", "RunSomeTests"]
```

Disabled tools are removed from `tools/list` and rejected on direct `tools/call` requests with a tool error. The config is loaded when the proxy starts; restart `xcode-mcp-proxy-server` after editing the file.

### Adapter: `xcode-mcp-proxy`

#### Options

| Option | Description |
|--------|-------------|
| `--request-timeout seconds` | HTTP request timeout (`0` disables) |
| `--url url` | Explicit upstream URL (example: `http://localhost:9000/mcp`) |

#### Environment Variables

| Variable | Description |
|----------|-------------|
| `XCODE_MCP_PROXY_ENDPOINT` | Override upstream URL; `--url` takes precedence |

## Troubleshooting

[Troubleshooting](Docs/troubleshooting.md)

## References

- [MCP / Xcode MCP Benchmark Notes](Docs/mcp-benchmark.md)
- [MCP Connection Permission Dialog Investigation](Docs/mcp-permission-dialog-investigation.md)

## License

[LICENSE](LICENSE)
