# XcodeMCPKit

XcodeMCPKit is a local proxy for Xcode MCP. It gives your MCP clients one stable
endpoint and automates the `mcpbridge` approval flow.

## Requirements

- macOS 15.4+
- Swift 6.3+

## Install

### From GitHub Releases

```bash
curl -fsSL https://github.com/lynnswap/XcodeMCPKit/releases/latest/download/install.sh | sh
```

<details>
<summary>Other install options</summary>

Custom install directory:

```bash
curl -fsSL https://github.com/lynnswap/XcodeMCPKit/releases/latest/download/install.sh | sh -s -- --bindir "$HOME/bin"
```

Install a specific version:

```bash
curl -fsSL https://github.com/lynnswap/XcodeMCPKit/releases/download/v0.11.0/install.sh | sh
```

### From Source

Installs both the proxy server and the STDIO adapter:

```bash
swift run -c release xcode-mcp-proxy-install
```

Custom install directory:

```bash
swift run -c release xcode-mcp-proxy-install --prefix "$HOME/.local"
swift run -c release xcode-mcp-proxy-install --bindir "$HOME/bin"
```

Add to `PATH`:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

</details>

## Set Up Your MCP Client

### 1. Enable Xcode MCP Access

XcodeMCPKit automatically uses Xcode 27's headless MCP service when it is
available and enabled. This lets the proxy start before a project or workspace
is open in the Xcode app. Enabling the service is an optional, one-time system
setup performed by you:

```bash
sudo xcrun mcp-server enable
```

XcodeMCPKit never runs `sudo` or changes Xcode MCP permissions. If Xcode 27
provides the service but it is disabled, startup prints the command above and
continues with GUI Xcode routing. Older Xcode versions also continue with GUI
routing.

For GUI routing, open your project in Xcode, choose
**Xcode > Settings > Intelligence**, and turn on
**Allow external agents to use Xcode tools** under **Model Context Protocol**.
See [Giving external agents access to Xcode][apple-xcode-mcp-access].

This global Xcode setting is separate from the per-connection **Allow** dialog.
`--auto-approve` handles the GUI dialog; it does not enable headless MCP access.
The first headless `XcodeOpenWorkspace` call can separately ask you to approve
the agent and containing folder. Review that request in Xcode Service and
approve it manually; XcodeMCPKit does not broaden headless permissions.

### 2. Start the Proxy Server

```bash
xcode-mcp-proxy-server --auto-approve
```

In GUI mode, `--auto-approve` clicks the Xcode **Allow** button automatically. In
**System Settings > Privacy & Security > Accessibility**, allow the app that
launches the proxy (for example, Terminal or iTerm).

Without Accessibility permission, omit `--auto-approve` and click **Allow** yourself:

```bash
xcode-mcp-proxy-server
```

### 3. Register the Client

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

CLI help:

```bash
xcode-mcp-proxy-server --help
xcode-mcp-proxy --help
```

### Server Options

| Option | Description |
|--------|-------------|
| `--listen host:port` | Listen address. Defaults to `localhost:8765`. |
| `--host host` / `--port port` | Listen host and port when `--listen` is not used. |
| `--upstream-processes n` | Number of upstream `mcpbridge` processes per running Xcode process when the default `xcrun mcpbridge` upstream is used. Default: `1`, max: `10`. |
| `--request-timeout seconds` | Request timeout. `0` disables non-initialize timeouts; initialize still has a bounded handshake timeout. |
| `--config path` | TOML config path. |
| `--xcode-mode automatic|gui|headless` | Select Xcode routing. `automatic` (default) uses enabled headless MCP when available and otherwise uses GUI routing. `headless` fails instead of falling back. |
| `--auto-approve` | Automatically approve the Xcode permission dialog. Requires Accessibility permission. |
| `--refresh-code-issues-mode proxy|upstream` | Serve `XcodeRefreshCodeIssuesInFile` through proxy diagnostics (`proxy`, default) or pass through to Xcode live diagnostics (`upstream`). |
| `--force-restart` | Terminate an existing `xcode-mcp-proxy-server` on the listen port and start a new one. |

### Environment Variables

| Variable | Description |
|----------|-------------|
| `LISTEN` | Listen address, for example `127.0.0.1:8765`. |
| `HOST` / `PORT` | Listen host and port when `LISTEN` is unset. |
| `MCP_XCODE_PID` | Set by the proxy on GUI process-bound upstream `mcpbridge` children. Headless routing leaves the stock bridge unbound. An inherited value is only passed through when process-bound Xcode routing is not active. |
| `MCP_XCODE_SESSION_ID` | Optional explicit upstream Xcode MCP session ID. |
| `MCP_XCODE_CONFIG` | TOML config path. `--config` takes precedence. |
| `MCP_XCODE_REFRESH_CODE_ISSUES_MODE` | `proxy` or `upstream`. |
| `MCP_LOG_LEVEL` | `trace`, `debug`, `info`, `notice`, `warning`, `error`, or `critical`. |
| `XCODE_MCP_PROXY_ENDPOINT` | STDIO adapter upstream URL. `--url` takes precedence. |
| `XCODE_MCP_PROXY_DISCOVERY_FILE` | Discovery file override for isolated local/live test runs. |
| `XCODE_MCP_PROXY_CACHE_ROOT` | Cache root used to derive the discovery path when `XCODE_MCP_PROXY_DISCOVERY_FILE` is unset. |

### TOML Configuration

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

### v0.14.0

- The Swift client and embedded proxy APIs now use typed connection state,
  `Duration` deadlines, explicit async lifecycle completion, and a smaller
  server/adapter public surface.
- Deprecated wrappers are not retained.
- CLI users can keep the normal server and adapter commands, but must replace
  the adapter's old `--stdio` alias with `--url`.
- See the [v0.14.0 migration guide](Docs/migration-2026-07.md) for the complete
  old-to-new symbol and behavior mapping.

### v0.11.0

If you use the proxy through Codex or Claude Code, no migration is required.
Only the following cases need changes:

- Direct Streamable HTTP clients:
  after `initialize`, send the server-issued `MCP-Session-Id` and
  `MCP-Protocol-Version: 2025-06-18`. Include
  `Accept: application/json, text/event-stream` on `POST /mcp`, and do not send
  JSON-RPC batch requests.

## Troubleshooting

- [Troubleshooting](Docs/troubleshooting.md)

## Maintainers

Local checks:

```bash
swift test -Xswiftc -strict-concurrency=minimal
XCODE_MCP_RUN_PROCESS_TESTS=1 swift test --no-parallel --filter XcodeMCPProcessRuntimeTests -Xswiftc -strict-concurrency=minimal
XCODE_MCP_RUN_PROCESS_TESTS=1 swift test --no-parallel --filter ProxyStdioAdapterTests -Xswiftc -strict-concurrency=minimal
scripts/check.sh
```

To diagnose Xcode permission dialogs without launching `mcpbridge`, run the
package-only maintainer tool with explicit existing process identities:

```bash
swift run xcode-mcp-permission-approver \
  --xcode-pid <xcode-pid> \
  --agent-pid <proxy-server-pid> \
  --agent-path <proxy-server-path> \
  --assistant-name XcodeMCPKit
```

Release:

```bash
gh workflow run release.yml --ref main -f version=v0.11.0
```

Edit the draft release notes, then publish the release manually.

- Module boundaries, release flow, live tests, benchmarks:
  [Maintainer Architecture](Docs/maintainer-architecture.md)

## Documentation

- [Swift client API](Sources/XcodeMCPKit/README.md)
- [Embedded proxy API](Sources/XcodeMCPProxyKit/README.md)
- [v0.14.0 breaking API migration](Docs/migration-2026-07.md)
- [Architecture](Docs/architecture.md)
- [Troubleshooting](Docs/troubleshooting.md)
- [MCP / Xcode MCP Benchmark Notes](Docs/mcp-benchmark.md)
- [MCP Connection Permission Dialog Investigation](Docs/mcp-permission-dialog-investigation.md)
- [Permission Automation Target Design](Docs/permission-automation-target-design.md)
- [Xcode 27 mcpbridge Tool Additions](Docs/xcode-27-mcpbridge-tools.md)

## License

[LICENSE](LICENSE)

[apple-xcode-mcp-access]: https://developer.apple.com/documentation/xcode/giving-external-agents-access-to-xcode
