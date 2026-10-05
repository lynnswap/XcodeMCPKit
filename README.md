# XcodeMCPKit

XcodeMCPKit is a server for using Xcode's MCP tools headlessly.

## Requirements

- macOS 15.4+
- An Xcode installation with native MCP tools
- [Homebrew](https://brew.sh/) for installation

## Quick start

### Install

For a new installation:

```bash
brew install lynnswap/tap/xcode-mcpkit
```

> [!NOTE]
> If you previously installed XcodeMCPKit with the shell installer or from source,
> run this command once to migrate to Homebrew, even if you have already run `brew install`:
>
> ```bash
> curl -fsSL https://github.com/lynnswap/XcodeMCPKit/releases/latest/download/install.sh | sh
> ```
>
> Restart the server and connected MCP clients afterward.

With Homebrew set up, no additional `PATH` setting is needed.

### Start the server

```bash
xcode-mcp-proxy-server
```

Keep this terminal open while using MCP. You can leave Xcode closed.

### Connect your MCP client

In another terminal, run the command for your client.

**Codex**

```bash
codex mcp add xcode --url http://localhost:8765/mcp
```

**Claude Code**

```bash
claude mcp add --transport http xcode http://localhost:8765/mcp
```

For other MCP clients, connect to `http://localhost:8765/mcp` using Streamable HTTP.

<details>
<summary>Replacing an existing MCP registration</summary>

If your client already has an `xcode` registration, remove it before running the
connection command above:

```bash
codex mcp remove xcode
# Or, for Claude Code:
claude mcp remove xcode
```

Restart clients that are already running after changing their configuration.

</details>

<details>
<summary>Clients that require STDIO</summary>

Keep the HTTP server running and register the bundled STDIO adapter:

```bash
codex mcp add xcode -- xcode-mcp-proxy
# Or, for Claude Code:
claude mcp add --transport stdio xcode -- xcode-mcp-proxy
```

For a source installation, use the adapter's full path in the chosen installation
directory in place of `xcode-mcp-proxy`.

</details>

## Other installation options

<details>
<summary>Build from source</summary>

To build `main` locally, use a Swift 6.3+ toolchain and install it in a separate
directory:

```bash
git clone https://github.com/lynnswap/XcodeMCPKit.git
cd XcodeMCPKit
swift run -c release xcode-mcp-proxy-install --bindir "$HOME/.local/opt/xcode-mcpkit-dev/bin"
```

Stop any running proxy server, then start this build by its full path:

```bash
"$HOME/.local/opt/xcode-mcpkit-dev/bin/xcode-mcp-proxy-server"
```

Connect your client using the HTTP commands in Quick start. No `PATH` change is
needed. The two commands and `XcodeMCPNativeHost.app` are installed together;
keep the helper app beside the commands.

Without `--bindir`, the source installer defaults to `~/.local/bin` and replaces
existing commands there, including links created by the Homebrew migration.
Using a separate directory keeps development builds independent of that installation.

The installer also accepts `--prefix directory` to install into its `bin`
subdirectory. Run `swift run -c release xcode-mcp-proxy-install --help` for details.

</details>

<details>
<summary>Migration from a custom installation directory</summary>

For an old custom location, use the same `--prefix` or `--bindir`; for example:

```bash
curl -fsSL https://github.com/lynnswap/XcodeMCPKit/releases/latest/download/install.sh | sh -s -- --bindir /path/to/bin
```

Only the specified old installation directory is migrated. If you keep copies
in multiple locations, repeat the migration with each location's `--bindir`.

</details>

## Update or uninstall a Homebrew installation

Stop the server before updating, then start it again:

```bash
brew update
brew upgrade lynnswap/tap/xcode-mcpkit
xcode-mcp-proxy-server
```

To uninstall, stop the server and run `brew uninstall xcode-mcpkit`.

## Documentation

- [Configuration](Docs/configuration.md)
- [Workspace and tool usage](Docs/usage.md)
- [Troubleshooting](Docs/troubleshooting.md)
- [Migration guides](Docs/migrations/README.md)
- [Development and architecture](Docs/README.md)

## License

[MIT](LICENSE)
