# XcodeMCPProxyToolVerifier

Live verifier for `xcode-mcp-proxy-server`.

By default, the verifier opens its fixture workspace in GUI Xcode:

```sh
swift run xcode-mcp-proxy-tool-verifier
```

To leave GUI windows unchanged and use Xcode Service when the fixture is not
already available through GUI Xcode:

```sh
swift run xcode-mcp-proxy-tool-verifier --no-open-xcode --upstream-processes 2
```

Headless access must already be enabled. The verifier does not run
`mcp-server enable`, approve an agent or folder, change permission policy, or
stop the process-shared Xcode Service. Its `XcodeOpenWorkspace` call is the
agent and folder approval bootstrap; complete any approval requested by Xcode,
then let the call finish.

The verifier:

- builds the local debug `xcode-mcp-proxy-server`
- starts it on a verifier-only port
- opens `XcodeMCPKit.xcworkspace` in Xcode unless `--no-open-xcode` is supplied
- waits for the GUI fixture it opened to appear, even when Service becomes ready first
- with `--no-open-xcode`, reuses an available GUI fixture or prepares a Service fixture
- creates a uniquely named Service workspace referencing the fixture project,
  then calls `XcodeOpenWorkspace` as the first-use approval bootstrap
- uses the resolved GUI `tabIdentifier` or the Service's returned `workspaceIdentifier`
- uses the tracked fixture project in `Fixtures/ProxyToolVerifierFixture`
- reads and records the complete live `tools/list` catalog
- calls each tool with a fixture-safe plan one at a time; unknown tools and
  tools without safe arguments remain in the report as `not-planned`
- records raw progress notification fields for build and test operations
- closes only its dedicated Service workspace, including when later verification
  fails; existing Service workspaces stay open
- writes `ProxyToolVerifierOutput/report.json`
- prints the tested tool list at the end

Logs, cache files, and reports are written under `ProxyToolVerifierOutput/`,
which is ignored by git. Every run also writes
`ProxyToolVerifierOutput/tool-catalog.json`, preserving every raw tool descriptor
for comparison with later Xcode versions. The report records the fixture's
actual owner (`gui` or `service`).

`Fixtures/ProxyToolVerifierFixture` is a small tracked Xcode project used only
by this verifier. It gives the live tools a stable app, scheme, test target,
SwiftUI preview, and String Catalog to operate on. The verifier restores the
fixture files it mutates during a run.

Options:

```sh
swift run xcode-mcp-proxy-tool-verifier --port 18765 --request-timeout 600
swift run xcode-mcp-proxy-tool-verifier --no-open-xcode --request-timeout 600
swift run xcode-mcp-proxy-tool-verifier --keep-server
```

`--upstream-processes` controls the GUI and Service pools in the same automatic
proxy. `--no-open-xcode` skips opening the GUI fixture; it does not disable GUI
routing or select a server-wide mode. `--xcode-mode` is no longer accepted.
