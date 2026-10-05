# XcodeMCPProxyToolVerifier

Live verifier for a locally built proxy and its signed headless native helper:

```sh
swift run xcode-mcp-proxy-tool-verifier
```

Each run copies the tracked fixture to its output directory and explicitly opens
that saved workspace through the native host. It does not open Xcode windows.

## Run ownership

The verifier builds the local debug proxy and uses `scripts/build-native-host.sh`
to create the signed app beside the executable. It starts a verifier-only
listener and isolates discovery, logs, reports, and cache files under
`ProxyToolVerifierOutput/`, which is ignored by Git.

The tracked `Fixtures/ProxyToolVerifierFixture` supplies an app, scheme, test
target, SwiftUI preview, and String Catalog. The verifier mutates only its
fixture copy and closes only the workspace it created. Reports record that
workspace's path, returned identifier, and cleanup result.
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
File checks use saved content. Build and test checks use the host's explicitly
selected scheme, destination, and test plan.

## Options

```sh
swift run xcode-mcp-proxy-tool-verifier --port 18765 --request-timeout 600
swift run xcode-mcp-proxy-tool-verifier --keep-server
```

Use `--run-destination` with a display title from `XcodeListRunDestinations` to
choose the fixture's build and run destination. Use `--device-identifier` with
an owned Simulator UUID for both device-interaction session tools. The caller
creates and removes that Simulator. For example:

```sh
swift run xcode-mcp-proxy-tool-verifier \
  --run-destination "Verifier iPhone" --device-identifier "$verifier_device_id"
```

The verifier stops fixture operations if scheme, destination, or test-plan
selection fails. Project and target creation runs after build, runtime, and
device checks so a new target's automatic scheme cannot change those checks.

`--no-open-xcode` is removed because every run is headless. `--upstream-processes`
and `--xcode-mode` remain unsupported. The proxy owns one multiplexed native host.
