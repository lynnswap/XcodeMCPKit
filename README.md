# XcodeMCPKit

Use Xcode's build, test, preview, and editing tools through one local MCP server.
Workspaces run headlessly when no GUI owns them; open workspaces use their Xcode
instance's active scheme and state. Xcode supplies the tool definitions and
implementations; [ABIBridge](https://github.com/lynnswap/ABIBridge) connects the
server to its native frameworks.

## Requirements

- macOS 15.4+
- Swift 6.3+ to build from source
- An Xcode installation with native MCP tools

Headless operation has been verified with Xcode 27. Xcode 26.6 provides GUI
tools, but lacks a required headless contract. See [Xcode compatibility](Docs/configuration.md#xcode-compatibility)
for installation selection and limitations.

## Quick start

### Install

Install the server, STDIO adapter, and signed native helper through Homebrew:

```bash
brew install lynnswap/tap/xcode-mcpkit
```

The Formula installs both commands on Homebrew's `PATH` and keeps the helper app
with their versioned payload. Xcode is still required to run its tools.

For an unreleased build from `main`, use the source installer:

```bash
git clone https://github.com/lynnswap/XcodeMCPKit.git
cd XcodeMCPKit
swift run -c release xcode-mcp-proxy-install
```

The source installer places the server, STDIO adapter, and signed native helper app in
`~/.local/bin`. Keep `XcodeMCPNativeHost.app` beside the executables. Add the
installation directory to your `PATH`, or put this line in `~/.zshrc`:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

For a custom destination, the installer accepts `--prefix directory` or
`--bindir directory`. Run `swift run -c release xcode-mcp-proxy-install --help`
for its options.

### Upgrade or remove

Stop the server, then upgrade and start it again:

```bash
brew update
brew upgrade lynnswap/tap/xcode-mcpkit
xcode-mcp-proxy-server
```

If an older standalone installation under `~/.local/bin` takes precedence, use
`"$(brew --prefix xcode-mcpkit)/bin/xcode-mcp-proxy-server"` and update any MCP client
configuration that names an old absolute executable path. Remove the old
standalone files only after stopping their server and confirming the new setup.
Homebrew does not remove those files or change your MCP client registrations.

To remove the Homebrew installation, stop the server and run
`brew uninstall xcode-mcpkit`.

### Start the server

```bash
xcode-mcp-proxy-server --auto-approve
```

Allow the app launching the server, such as Terminal, in **System Settings >
Privacy & Security > Accessibility**. `--auto-approve` clicks **Allow** on
recognized Xcode connection dialogs for all agents, including other clients.
Omit the flag and run `xcode-mcp-proxy-server` to approve connections manually.

Keep the server running. You can start it without opening a workspace in Xcode.

### Connect your MCP client

Codex:

```bash
codex mcp add xcode --url http://localhost:8765/mcp
```

Claude Code:

```bash
claude mcp add --transport http xcode http://localhost:8765/mcp
```

For other clients, use `http://localhost:8765/mcp` with Streamable HTTP. If an
`xcode` registration already exists, remove it first with `codex mcp remove xcode`
or `claude mcp remove xcode`.

For STDIO clients, register the adapter instead. The HTTP server must still be running:

```bash
codex mcp add xcode -- xcode-mcp-proxy
claude mcp add --transport stdio xcode -- xcode-mcp-proxy
```

## Use a workspace

Pass an absolute `.xcworkspace` or `.xcodeproj` path as `workspaceIdentifier`
to workspace tools. The server uses its open GUI owner, or loads the project
without a window. Multiple Xcode instances can share the endpoint; if several
tabs own the same path, select a `tabIdentifier` from `XcodeListWindows`.

Available tools follow each installation's catalog. See [workspace and tool
usage](Docs/usage.md) for build examples, GUI state, tool discovery, and cancellation.

## Use from Swift

Add this package from `main` and the `XcodeMCPKit` product to your target. With
the server running, discover its available tools:

```swift
import XcodeMCPKit

let xcode = try await XcodeMCP()
let tools = try await xcode.listTools()
await xcode.close()
print(tools.map(\.name))
```

See the [Swift client guide](Sources/XcodeMCPKit/README.md) for tool calls and
lifecycle handling, or [XcodeMCPProxyKit](Sources/XcodeMCPProxyKit/README.md) to
embed the server or adapter.

## Documentation

- [Configuration reference](Docs/configuration.md)
- [Workspace and tool usage](Docs/usage.md)
- [Migration guides](Docs/migrations/README.md)
- [Troubleshooting](Docs/troubleshooting.md)

For architecture, verification, and release instructions, see the
[documentation index](Docs/README.md).

## License

[MIT](LICENSE)
