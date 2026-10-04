# Documentation

## Using XcodeMCPKit

- [README quick start](../README.md#quick-start): installation and MCP client registration.
- [Configuration](configuration.md): Xcode selection, CLI options, and environment variables.
- [Workspace and tool usage](usage.md): headless and GUI routing, tool catalogs,
  editor state, and cancellation.
- [Troubleshooting](troubleshooting.md): connection, helper, timeout, and diagnostic errors.
- [Migration guides](migrations/README.md): changes required when upgrading.

## Swift APIs

- [XcodeMCPKit](../Sources/XcodeMCPKit/README.md): discover and call tools from Swift.
- [XcodeMCPProxyKit](../Sources/XcodeMCPProxyKit/README.md): embed the server or STDIO adapter.
- [XcodeMCPKitTesting](../Sources/XcodeMCPKitTesting/README.md): test clients through an in-memory MCP runtime.

## Development

- [Architecture](architecture.md): request routing, catalogs, discovery, and HTTP contracts.
- [Maintainer architecture](maintainer-architecture.md): module ownership, local checks,
  live verification, release flow, and cleanup.
- [Native host design](native-headless-backend.md): Xcode framework integration through ABIBridge.
- [Live tool verifier](../Sources/XcodeMCPProxyToolVerifier/README.md): fixture-based verification.
- [MCP benchmarks](mcp-benchmark.md): measuring a running server.
- [Permission automation](permission-automation-target-design.md) and
  [dialog investigation](mcp-permission-dialog-investigation.md).

## Historical design notes

- [July 2026 design audit](design-audit-2026-07/README.md)
- [Proxy target rearchitecture](proxy-target-rearchitecture-2026-07.md)
- [Xcode 27 headless MCP investigation](xcode-27-headless-mcp-design.md)
- [Xcode 27 mcpbridge tool additions](xcode-27-mcpbridge-tools.md)
