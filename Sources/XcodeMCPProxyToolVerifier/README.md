# XcodeMCPProxyToolVerifier

Live verifier for `xcode-mcp-proxy-server`.

GUI Xcode is the default and preserves the existing verifier workflow:

```sh
swift run xcode-mcp-proxy-tool-verifier
```

To verify Xcode 27's headless service without opening an Xcode window:

```sh
swift run xcode-mcp-proxy-tool-verifier --xcode-mode headless
```

Headless access must already be enabled. The verifier does not run
`mcp-server enable`, approve an agent or folder, change permission policy, or
stop the process-shared Xcode Service. Its `XcodeOpenWorkspace` call is the
agent and folder approval bootstrap; complete any approval requested by Xcode,
then let the call finish.

The verifier:

- builds the local debug `xcode-mcp-proxy-server`
- starts it on a verifier-only port
- in GUI mode, opens `XcodeMCPKit.xcworkspace` in Xcode
- in headless mode, starts the proxy with `--xcode-mode headless` and calls
  `XcodeOpenWorkspace` through the proxy
- detects `XcodeListWindows` versus `XcodeListWorkspaces` from `tools/list`
  and uses the advertised `tabIdentifier` or `workspaceIdentifier` schema
- uses the tracked fixture project in `Fixtures/ProxyToolVerifierFixture`
- reads and records the complete live `tools/list` catalog
- calls each tool with a fixture-safe plan one at a time; unknown tools and
  tools without safe arguments remain in the report as `not-planned`
- records raw progress notification fields for build and test operations
- closes only the headless workspace identifier returned by its own
  `XcodeOpenWorkspace` call, including when later verification fails
- writes `ProxyToolVerifierOutput/report.json`
- prints the tested tool list at the end

Logs, cache files, and reports are written under `ProxyToolVerifierOutput/`,
which is ignored by git. Headless runs also write
`ProxyToolVerifierOutput/headless-tool-catalog.json`, preserving every raw tool
descriptor for comparison with later Xcode previews.

`Fixtures/ProxyToolVerifierFixture` is a small tracked Xcode project used only
by this verifier. It gives the live tools a stable app, scheme, test target,
SwiftUI preview, and String Catalog to operate on. The verifier restores the
fixture files it mutates during a run.

Options:

```sh
swift run xcode-mcp-proxy-tool-verifier --port 18765 --request-timeout 600
swift run xcode-mcp-proxy-tool-verifier --xcode-mode headless --request-timeout 600
swift run xcode-mcp-proxy-tool-verifier --keep-server
```

`--upstream-processes` and `--no-open-xcode` apply only to GUI verification.
