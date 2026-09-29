# Automatic Xcode routing migration

The proxy now discovers GUI Xcode and enabled Xcode Service automatically.
A request's standard `workspaceIdentifier` selects a workspace by absolute path
or by an opaque identifier returned by Service. `tabIdentifier` remains available
for selecting a specific GUI tab, including when multiple windows own the same
path. See [Select a Workspace](../README.md#select-a-workspace).

## CLI

Remove these server options from launch scripts and service definitions:

- `--xcode-mode`
- `--session-id`
- `--upstream-command`
- `--upstream-args`
- `--upstream-arg`

These options are rejected rather than aliased. Use `--upstream-processes n`
to set the connection count per GUI process and for the Service pool (`1...10`,
default `1`). Endpoint, timeout, tool visibility, and permission controls remain
available. Service must already be enabled in the selected Xcode installation;
the proxy does not change that permission.

Inherited `MCP_XCODE_PID` and `MCP_XCODE_SESSION_ID` are stripped from bridge
launch environments. The proxy supplies a GUI PID from process discovery;
Service bridges use the native default connection.

## Embedded server

Replace `upstream: .defaultMCPBridge(processesPerXcode: n)` with
`upstreamProcessCount: n` in `XcodeMCPProxyServerConfiguration`. Remove `xcodeMode`
and Apple session-ID configuration. The nested `XcodeMode` and `Upstream` types,
including `Upstream.custom`, have been removed.

```swift
let server = XcodeMCPProxyServer(
    configuration: .init(upstreamProcessCount: 2)
)
let endpoint = try await server.start()
// Use endpoint.url.
try await server.shutdown()
```

The general `XcodeMCPKit` client still supports
`.localBridge(.custom(command:arguments:environment:))`. Tests and general MCP
clients can use that transport directly. The HTTP `MCP-Session-Id` header and
STDIO adapter session recovery are unchanged; they are independent of Apple's
bridge environment variable.

## Live verifier

Remove `--xcode-mode`. Use `--no-open-xcode` to skip opening a GUI fixture window.
The verifier resolves the fixture's actual owner from the inventories and records
that owner in its report. Catalog artifacts are now named `tool-catalog.json`.
