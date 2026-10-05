# Native routing migration

The native backend is available on `main`. Published v0.17.0 uses the earlier
backend; its [README](https://github.com/lynnswap/XcodeMCPKit/blob/v0.17.0/README.md)
records that version's setup.

The proxy runs one owned headless host. Pass an absolute `workspaceIdentifier`
to load a saved project model. Open GUI windows do not supply editor state,
schemes, or destinations. See [Select a workspace](../usage.md#select-a-workspace).

## Server and CLI

Remove `--auto-approve` and `XcodeMCPProxyServerConfiguration.approvalPolicy`.
The `ApprovalPolicy` type and Accessibility permission automation are removed.
The helper executes headless tools without updating Xcode's agent permission
store. Startup neither registers an agent identity nor grants access to other
clients. Existing permission settings from earlier builds are left as they are.

Remove `--upstream-processes` and `upstreamProcessCount`. One native host serves
concurrent requests; there is no replacement process-count setting.

The previously removed `--xcode-mode`, `--session-id`, `--upstream-command`,
`--upstream-args`, and `--upstream-arg` remain unsupported. Remove Xcode Service
status/enable steps and explicit `mcpbridge` launches from proxy startup scripts.
Endpoint and deadline settings remain. Tool visibility is controlled by the MCP client.

`XcodeMCPProxyServerConfiguration` adds optional `nativeHostBundleURL` and
`developerDirectoryURL`. Leave them `nil` for helper and Xcode discovery, or
provide a signed app bundle and selected installation explicitly:

```swift
import Foundation
import XcodeMCPProxyKit

let server = XcodeMCPProxyServer(configuration: .init(
    nativeHostBundleURL: URL(fileURLWithPath: "/opt/xcode-mcp/XcodeMCPNativeHost.app"),
    developerDirectoryURL: URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer")
))
let endpoint = try await server.start()
try await server.shutdown()
```

The server CLI discovers the installed helper.
The standard `DEVELOPER_DIR` environment can select the headless installation.
Explicit bundle and developer-directory URLs remain available for SDK embedding.
The source and release installers now install `XcodeMCPNativeHost.app` beside
the proxy binaries. Keep that bundle with the executables when relocating them.

## Swift client transport

`XcodeMCPConfiguration` now defaults to `.streamableHTTPProxyDiscovery()`.
Start `xcode-mcp-proxy-server` before constructing a default client. This path
provides shared headless execution over HTTP.

The `.defaultMCPBridge` bridge case has been removed. For a standalone headless
session, select the native host explicitly:

```swift
import XcodeMCPKit

let client = try await XcodeMCP(configuration: .init(
    transport: .localBridge(.nativeHost())
))
let tools = try await client.listTools()
await client.close()
```

`.localBridge(.custom(command:arguments:environment:))` remains available for
generic MCP processes and tests. The HTTP `MCP-Session-Id` and adapter recovery
contract are unchanged. Inherited `MCP_XCODE_PID` and `MCP_XCODE_SESSION_ID` do not
select the proxy's backend.

## Workspace behavior

Explicit Open is optional for ordinary absolute-path operations. Save project
and source files before calling tools. Select the host's scheme, destination,
and test plan explicitly; GUI selections and unsaved buffers are not imported.

The public catalog now follows `enabledHeadlessMCPTools` only. GUI window,
current-editor, and navigator tools and `tabIdentifier` routing are removed.
Provider-union metadata and schema variants are removed; descriptors come from
the single native host. Installation and cancellation facts remain in origin
metadata. Documentation search uses the headless native action.

## Removed configuration

Remove `--config`, `MCP_XCODE_CONFIG` and TOML files. `configurationFileURL` and
`ToolPolicy` are removed from the public server API, along with per-tool disabled
name lists. The server exposes Xcode's available tools; the MCP client decides
which tools may be called.

Remove `--refresh-code-issues-mode`, its environment setting and the corresponding
feature-policy property. `XcodeRefreshCodeIssuesInFile` now uses its native
provider through the normal request route, with native progress and errors.

The server CLI also removes `--native-host-bundle` and `--developer-dir`. Keep
`XcodeMCPNativeHost.app` beside the installed executables for automatic lookup.
