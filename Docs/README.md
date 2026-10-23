# Documentation

## Use the server

- [Quick start](../README.md#quick-start): install, start, and connect an MCP client.
- [Workspace and tool usage](usage.md): find a workspace, run tools, and manage sessions.
- [Configuration](configuration.md): Xcode selection, CLI options, and environment settings.
- [Troubleshooting](troubleshooting.md): connection, workspace, helper, and timeout errors.
- [Migration](migrations/native-backend.md): update older tool calls, Swift APIs, and startup scripts.

## Use the Swift libraries

- [XcodeMCPKit](../Sources/XcodeMCPKit/README.md): discover and call MCP tools.
- [XcodeMCPProxyKit](../Sources/XcodeMCPProxyKit/README.md): embed the server.
- [XcodeMCPKitTesting](../Sources/XcodeMCPKitTesting/README.md): use the client API with an in-memory runtime.

## Maintain the project

- [Architecture](architecture.md): public contracts, routing, sessions, and HTTP delivery.
- [Maintainer guide](maintainer-architecture.md): module ownership, native integration constraints, and verification.
- [Live tool verifier](../Sources/XcodeMCPProxyToolVerifier/README.md): disposable fixtures and preview comparisons.
- [Homebrew distribution](../Homebrew/README.md): release approval, publication, and recovery.
