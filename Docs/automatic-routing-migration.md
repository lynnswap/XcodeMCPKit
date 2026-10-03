# Native routing migration

The proxy starts an owned native host and discovers GUI Xcode owners. Pass an
absolute `workspaceIdentifier`; an open GUI owner takes priority, and the native
host loads the model when no GUI owns the path. See
[Select a workspace](../README.md#select-a-workspace).

## Server and CLI

Remove `--upstream-processes` and `upstreamProcessCount`. The runtime owns one
headless host and one connection per GUI owner, with concurrent requests on each
connection. There is no process-count replacement option.

The previously removed `--xcode-mode`, `--session-id`, `--upstream-command`,
`--upstream-args`, and `--upstream-arg` remain unsupported. Remove Xcode Service
status/enable steps and explicit `mcpbridge` launches from proxy startup scripts.
Endpoint, deadline, tool visibility, and permission automation settings remain.

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

CLI equivalents are `--native-host-bundle` and `--developer-dir`.
`XCODE_MCP_NATIVE_HOST_BUNDLE` and `DEVELOPER_DIR` are their environment defaults.
The source and release installers now install `XcodeMCPNativeHost.app` beside
the proxy binaries. Keep that bundle with the executables when relocating them.

## Swift client transport

`XcodeMCPConfiguration` now defaults to `.streamableHTTPProxyDiscovery()`.
Start `xcode-mcp-proxy-server` before constructing a default client. This path
provides automatic GUI ownership and headless fallback.

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

Explicit Open is optional for ordinary absolute-path operations. GUI builds use
Xcode's active scheme and save pending editor changes. Native read/current-file
results remain disk-backed. Catalog availability requires the native host;
GUI success no longer substitutes for a missing native catalog.
