# XcodeMCPProxyToolVerifier

Live verifier for a locally built `xcode-mcp-proxy-server` and its signed native
helper. The default run opens the tracked fixture workspace in GUI Xcode:

```sh
swift run xcode-mcp-proxy-tool-verifier
```

To preserve existing GUI windows and use an owned headless fixture when no GUI
owns the fixture path:

```sh
swift run xcode-mcp-proxy-tool-verifier --no-open-xcode
```

`--no-open-xcode` never opens a GUI window. The verifier can reuse an existing
GUI owner, or explicitly open its dedicated headless workspace to exercise the
native Open/Close lifecycle. It does not enable Xcode Service, bootstrap Service
workspace approval, or modify a shared Service process.

## Run ownership

The verifier builds the local debug proxy and uses `scripts/build-native-host.sh`
to create the signed app beside the executable. It starts a verifier-only
listener and isolates discovery, logs, reports, and cache files under
`ProxyToolVerifierOutput/`, which is ignored by Git.

When it opens a GUI fixture, it waits for that fixture's owner. With
`--no-open-xcode`, the native host can load the model without a GUI window. The
verifier supplies the standard `workspaceIdentifier` for GUI and headless
operations and records the actual owner in the report.

The tracked `Fixtures/ProxyToolVerifierFixture` supplies an app, scheme, test
target, SwiftUI preview, and String Catalog. Headless runs copy the fixture into
the output directory, where file and target mutations stay. GUI runs restore the
fixture's tracked project and String Catalog files. The verifier closes only
the dedicated headless workspace it created.
`--keep-server` retains the server for inspection; otherwise the run shuts down
its owned server and helpers.

## Catalog and verification coverage

Every run records the complete live catalog in
`ProxyToolVerifierOutput/tool-catalog.json` and operation results in
`ProxyToolVerifierOutput/report.json`. Xcode supplies the catalog dynamically.
The tool-specific argument plans describe verifier coverage; they are not a
second definition of the available tools.

A tool without a safe fixture plan, including an unknown new tool, remains in
the report as not planned. The report records skip reasons and raw descriptors
so a catalog addition can be examined without inventing arguments. Build and
test checks also record raw progress notification fields.

A successful result covers that tool's request and selected fixture conditions.
It does not establish every account, cached analytics dataset, selected app,
run destination, or Xcode-version combination. Request-owned analytics log
loading and guidance are distinct from the global product-selection cache;
optional app/scheme selection and untested cache conditions need separate checks.
Read/current-file checks retain native disk semantics. GUI build checks use the
active scheme and save pending editor changes.

## Options

```sh
swift run xcode-mcp-proxy-tool-verifier --port 18765 --request-timeout 600
swift run xcode-mcp-proxy-tool-verifier --no-open-xcode --request-timeout 600
swift run xcode-mcp-proxy-tool-verifier --keep-server
```

Use `--run-destination` with a display title from `XcodeListRunDestinations` to
choose the fixture's build and run destination. Use `--device-identifier` with
an owned Simulator UUID for both device-interaction session tools. The caller
creates and removes that Simulator. For example:

```sh
swift run xcode-mcp-proxy-tool-verifier --no-open-xcode \
  --run-destination "Verifier iPhone" --device-identifier "$verifier_device_id"
```

The verifier stops fixture operations if scheme, destination, or test-plan
selection fails. Project and target creation runs after build, runtime, and
device checks so a new target's automatic scheme cannot change those checks.

`--no-open-xcode` controls fixture-window ownership and does not disable GUI
routing. `--upstream-processes` and `--xcode-mode` are unsupported. The proxy
owns a headless host and one multiplexed connection for each GUI owner.
