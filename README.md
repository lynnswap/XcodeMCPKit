# XcodeMCPKit

XcodeMCPKit serves native Xcode tools through one local MCP endpoint. Pass an
absolute workspace path to use its open GUI owner, or let the native host load
the workspace model when no GUI owns it.

## Requirements

- macOS 15.4+
- Swift 6.3+ for building from source
- An Xcode installation that provides supported native GUI or headless tool contracts

Native packaging and live behavior have been verified with Xcode 27 and Swift
6.4. The inspected Xcode 26.6 installation provides its GUI catalog when a
workspace is open; its headless initialization lacks a required native contract.
Missing framework or API contracts produce diagnostics. The server keeps the
selected developer directory and does not switch to another installed SDK to
make headless initialization pass.

The release installer uses Python 3 and `codesign` to stage and verify the native
application before replacing it.

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

Install a specific release by replacing `<tag>` with its release tag:

```bash
curl -fsSL 'https://github.com/lynnswap/XcodeMCPKit/releases/download/<tag>/install.sh' | sh
```

### From Source

Installs the proxy server, STDIO adapter, and signed native helper application:

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

### 1. Start the proxy server

The installed `XcodeMCPNativeHost.app` must stay beside the proxy executables.
The server starts its own headless native host and discovers GUI Xcode owners.
You can start it with no GUI workspace open. No Xcode Service enable command,
`mcpbridge` launch, or process-count setting is required.

```bash
xcode-mcp-proxy-server --auto-approve
```

`--auto-approve` clicks **Allow** on recognized Xcode MCP connection dialogs for
all agents, including clients connecting outside this proxy. Existing approval based on the proxy's agent name, PID, and executable
path is preserved. Additionally, the English heading `Allow “…” to access Xcode?`
with an `Allow` button is approved for any agent. It applies in both GUI and
headless modes while the proxy is running. In
**System Settings > Privacy & Security > Accessibility**, allow the app that
launches the proxy (for example, Terminal or iTerm).

Without Accessibility permission, omit `--auto-approve` and click **Allow** yourself:

```bash
xcode-mcp-proxy-server
```

### 2. Register the client

Register the running proxy endpoint with your MCP client.

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
| `--native-host-bundle path` | Native helper app bundle. Defaults to automatic helper lookup. |
| `--developer-dir path` | Selected Xcode app or developer directory. Defaults to the selected Xcode installation. |
| `--request-timeout seconds` | Request timeout. `0` disables non-initialize timeouts; initialize still has a bounded handshake timeout. |
| `--config path` | TOML config path. |
| `--auto-approve` | Automatically approve Xcode MCP connection dialogs for all agents, including direct connections outside the proxy. Requires Accessibility permission. |
| `--refresh-code-issues-mode proxy|upstream` | Serve `XcodeRefreshCodeIssuesInFile` through proxy diagnostics (`proxy`, default) or pass through to Xcode live diagnostics (`upstream`). |
| `--force-restart` | Terminate an existing `xcode-mcp-proxy-server` on the listen port and start a new one. |

### Environment Variables

| Variable | Description |
|----------|-------------|
| `LISTEN` | Listen address, for example `127.0.0.1:8765`. |
| `HOST` / `PORT` | Listen host and port when `LISTEN` is unset. |
| `XCODE_MCP_NATIVE_HOST_BUNDLE` | Native helper bundle override; `--native-host-bundle` takes precedence. |
| `DEVELOPER_DIR` | Xcode selection; `--developer-dir` takes precedence. |
| `MCP_XCODE_CONFIG` | TOML config path. `--config` takes precedence. |
| `MCP_XCODE_REFRESH_CODE_ISSUES_MODE` | `proxy` or `upstream`. |
| `MCP_LOG_LEVEL` | `trace`, `debug`, `info`, `notice`, `warning`, `error`, or `critical`. Defaults to `info`; `debug` includes HTTP access and route-recovery telemetry. |
| `XCODE_MCP_PROXY_ENDPOINT` | STDIO adapter upstream URL. `--url` takes precedence. |
| `XCODE_MCP_PROXY_DISCOVERY_FILE` | Discovery file override for isolated local/live test runs. |
| `XCODE_MCP_PROXY_CACHE_ROOT` | Cache root used to derive the discovery path when `XCODE_MCP_PROXY_DISCOVERY_FILE` is unset. |

The proxy owns one headless native connection and one native connection for each
GUI Xcode owner. Each connection supports concurrent requests. Workspace
arguments choose the owner for each operation. Inherited `MCP_XCODE_PID` and
`MCP_XCODE_SESSION_ID` do not select the backend.

See [automatic routing migration](Docs/automatic-routing-migration.md) for
removed CLI flags, configuration properties, and the Swift client transport change.

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

## Tool discovery

The proxy exposes tools from the catalogs that native and GUI connections
actually supply. Each explicit `tools/list` refreshes discovery, and concurrent
callers share an in-flight load. If the selected SDK cannot initialize the
headless host, a usable GUI catalog remains available for that GUI's operations.
The headless failure still applies to requests that require a headless model.

For tools shared by several providers, the public schema preserves their
variants. Each tool's `_meta["com.lynnswap.xcode-mcpkit/providers"]` lists the
providers and their original `descriptor`, including input and output schemas.
Provider metadata identifies the Xcode installation, process, and cancellation
contract. A call uses the selected owner's definition, captured for that request;
another provider's schema cannot change its response contract mid-operation.

The helper's initialize and catalog results expose installation facts under
`_meta["com.lynnswap.xcode-mcpkit/origin"]`. `toolCancellation` is `task` for the
headless host, `nativeMessage` for a GUI connection with native cancellation,
or `waitForNativeCompletion` when GUI cancellation is advisory. Inspect the
reported contract for the connection you use. The connection checks its SDK's
native message decoder; the Xcode version number does not choose this behavior.

## Select a workspace

Pass an absolute project or workspace path as the standard `workspaceIdentifier`
argument. An open GUI owner takes priority. If no GUI owns the path, the native
host loads its workspace model lazily for the requested operation. You do not
need to open a GUI window or call `XcodeOpenWorkspace` first.

Use `XcodeListWindows` to inspect GUI tabs. When several tabs own the same path,
select a `tabIdentifier` from the reported candidates. A lost known GUI owner
produces an error rather than replaying the operation in another workspace.
Native `workspaceIdentifier` values from `XcodeOpenWorkspace` or
`XcodeListWorkspaces` select the host that owns that model, independently of
unrelated GUI inventory failures. A known GUI owner that lacks the requested
tool returns an explicit error. Close a headless workspace explicitly
when you no longer need it; the host closes only resources it owns during shutdown.

GUI operations use Xcode's workspace context. GUI builds save pending editor
changes and use the active scheme. Native file-reading tools return disk-backed
content; they do not promise an unsaved editor buffer. Tools without workspace
scope, such as `DocumentationSearch`, prefer the native host when it advertises
the requested tool.

Cancellation follows the selected connection's native capability. Xcode 27 can
receive a matching native cancel message. Xcode 26.6 cancellation is advisory
after dispatch: the operation remains tracked until its native completion or a
connection failure. Cancelling a queued request can prevent its dispatch.
Shutdown reports dispatched calls that lack confirmed cancellation; closing
their connection does not establish that Xcode stopped the native operation.

The former proxy-only `workspacePath` input is unsupported. Native list results
can still include `workspacePath` as output.

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

To diagnose permission dialogs without launching a native connection, run the
package-only maintainer tool with explicit existing process identities:

```bash
swift run xcode-mcp-permission-approver \
  --xcode-pid <xcode-pid> \
  --agent-pid <proxy-server-pid> \
  --agent-path <proxy-server-path> \
  --assistant-name XcodeMCPKit
```

Release: save the approved notes in a UTF-8 file, create a draft targeting the
approved full commit SHA on `main`, then start the release workflow:

```bash
gh release create v0.17.0 --repo lynnswap/XcodeMCPKit --draft \
  --target <approved-commit-sha> --title v0.17.0 \
  --notes-file /path/to/release-notes.md
gh workflow run release.yml --repo lynnswap/XcodeMCPKit --ref main -f version=v0.17.0
```

CI runs the checks, builds and verifies the assets, then attaches them and
publishes the same draft while preserving its title and notes. Failed checks
leave the draft unpublished. See the [release flow](Docs/maintainer-architecture.md#release-flow)
for existing drafts, prereleases, and retries.

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
