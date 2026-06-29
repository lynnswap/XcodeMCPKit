# XcodeMCPProxyToolVerifier

Live verifier for `xcode-mcp-proxy-server`.

```sh
swift run xcode-mcp-proxy-tool-verifier
```

The verifier:

- builds the local debug `xcode-mcp-proxy-server`
- starts it on a verifier-only port
- opens `XcodeMCPKit.xcworkspace`
- uses the tracked fixture project in `Fixtures/ProxyToolVerifierFixture`
- reads the live `tools/list` catalog
- calls each available tool one at a time
- writes `ProxyToolVerifierOutput/report.json`
- prints the tested tool list at the end

Logs, cache files, and reports are written under `ProxyToolVerifierOutput/`,
which is ignored by git.

`Fixtures/ProxyToolVerifierFixture` is a small tracked Xcode project used only
by this verifier. It gives the live tools a stable app, scheme, test target,
SwiftUI preview, and String Catalog to operate on. The verifier restores the
fixture files it mutates during a run.

Options:

```sh
swift run xcode-mcp-proxy-tool-verifier --port 18765 --request-timeout 600
swift run xcode-mcp-proxy-tool-verifier --keep-server
```
