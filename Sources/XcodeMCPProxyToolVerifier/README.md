# XcodeMCPProxyToolVerifier

Live verifier for a locally built proxy and its signed headless native helper:

```sh
swift run xcode-mcp-proxy-tool-verifier
```

The default catalog run copies the tracked fixture to its output directory and explicitly opens
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

`--no-open-xcode` is removed because catalog runs are headless. `--upstream-processes`
and `--xcode-mode` remain unsupported. The default catalog run uses the proxy's
default headless host. The shared server also supports selecting other headless
hosts and running GUI Xcode processes; the verifier's default run does not test
those targets or their concurrent execution.

## Preview probes

The `previews` commands preserve the projects and source variants used to compare
Apple's native `RenderPreview` with the headless renderer. Run them from the
repository root with Swift 6.3 or later. The fixtures cover arm64 execution.

```sh
swift run xcode-mcp-proxy-tool-verifier previews list
swift run xcode-mcp-proxy-tool-verifier previews prepare \
  --fixture platform --output ProxyToolVerifierOutput/platform
```

| Fixture | Contents |
| --- | --- |
| `platform` | macOS, Mac Catalyst, tvOS, visionOS, and watchOS apps; SwiftUI, UIKit, AppKit, ClockKit, and watch Relevance previews |
| `widget` | iOS app display previews, WidgetKit, Intent/AppIntent configuration, Live Activity, empty timelines, and cancellation |
| `framework` | Standalone framework previews and a bundle resource |
| `hostless-package` | macOS Swift package library with a SwiftUI preview and no app host |
| `remote-package` | macOS app using a remote Swift package product, for automatic dependency-resolution checks |
| `general` | UIKit views/controllers, grouped and legacy SwiftUI previews, shared context, and preview state |
| `physical` | App and Widget extension with a source-selected physical device |
| `physical-bare` | The existing app fixture without a Widget extension, using the physical source variant |

Project definitions, source, assets, and case descriptions live under
[`Fixtures/PreviewVerifier`](../../Fixtures/PreviewVerifier). General and bare
physical probes reuse `Fixtures/ProxyToolVerifierFixture`. Preparation copies the
project into the requested directory; it does not change tracked files.
The case list selects representative probes. Other declarations remain in the
tracked sources for investigation.

### Capture and compare

Choose an installed Xcode and a destination title reported by
`XcodeListRunDestinations`. Capture the same case with both backends:

```sh
developer_dir=/Applications/Xcode.app/Contents/Developer

swift run xcode-mcp-proxy-tool-verifier previews capture \
  --fixture ProxyToolVerifierOutput/platform --case mac-appkit-controller \
  --developer-dir "$developer_dir" --destination "My Mac" \
  --backend headless --output ProxyToolVerifierOutput/headless

swift run xcode-mcp-proxy-tool-verifier previews capture \
  --fixture ProxyToolVerifierOutput/platform --case mac-appkit-controller \
  --developer-dir "$developer_dir" --destination "My Mac" \
  --backend native --xcode-pid "$xcode_pid" --output ProxyToolVerifierOutput/native

swift run xcode-mcp-proxy-tool-verifier previews compare \
  --native ProxyToolVerifierOutput/native --headless ProxyToolVerifierOutput/headless \
  --output ProxyToolVerifierOutput/comparison
```

Set `xcode_pid` to the running process for the selected Xcode. Native capture opens
its own project copy with `open`, discovers that document through `mcpbridge`, and
closes only that document with Xcode's scripting API. It requires Xcode's native
preview services and permission for the terminal to automate Xcode. It does not
use screen automation. Headless capture opens no Xcode windows. Without
`--native-host`, it builds the signed debug host using the selected developer
directory. Use `--native-host /path/to/XcodeMCPNativeHost.app` to test a package
already built with `scripts/build-native-host.sh`.

Each capture uses a fresh copy of the prepared project and saves `capture.json`,
the live catalog, the PNG, raw tool results, selected destination, source/project
hashes, and executable identity. The existing MCP client owns the bridge or
headless host process. Workspace and document cleanup runs after failures as
well as success; cleanup errors remain in the report. Closing the workspace
releases its preview processes, owned Simulator, and staged products. The verifier
does not remove other devices or applications. Output files remain available for
inspection; choose a new output directory for each run.

To measure initial capture, an unchanged repeat, and a saved source edit in one
workspace, pass `--sequence-edit` to either backend. For timing runs, prepare the
fixture and place capture outputs outside this checkout, for example under
`~/Dev/work/preview-latency`. Otherwise its enclosing `Package.swift` can include
this repository's files in headless input validation. The JSON file specifies the
text replacement for the case's source file:

```json
{"oldString": "UIVIEW ACTUAL PREVIEW", "newString": "UPDATED ACTUAL PREVIEW"}
```

```sh
swift run xcode-mcp-proxy-tool-verifier previews capture \
  --fixture "$HOME/Dev/work/preview-latency/general" --case uiview \
  --developer-dir "$developer_dir" --destination "$destination" \
  --sequence-edit /path/to/edit.json --native-host /path/to/XcodeMCPNativeHost.app \
  --output "$HOME/Dev/work/preview-latency/headless-sequence"
```

Use a destination title reported by `XcodeListRunDestinations`. The replacement
runs through `XcodeUpdate` on the owned project copy after the unchanged repeat.
`capture.json` records each condition's tool duration and source hash in `samples`;
`capture-initial.json`, `capture-unchanged-repeat.json`, and `capture-source-edit.json`
retain its metadata and PNG path. The initial image remains `preview.png`; the
other conditions have separate PNGs. `previews compare` checks all three conditions
when both captures contain a sequence. Use the same edit JSON for both backends.

Comparison requires successful captures, matching source/project inputs, the
same case, Xcode build, and requested destination. It compares the response's
name, source line, errors, localizations, variant and canvas catalogs, and rendered
destination. Images are decoded to sRGB premultiplied RGBA pixels before exact
comparison. A native failure, missing image, incompatible input, metadata
difference, or pixel difference produces a nonzero exit status. Keep reference
captures with their execution context; images from a different Xcode or runtime
are not portable golden files.

The empty-timeline and cancellation probes intentionally exercise failures.
Use `--timeout SECONDS` to bound a capture. Their failure responses are retained;
two failed captures do not constitute a passing image comparison.

### Physical device inputs

Physical probes need a connected eligible device and locally configured signing.
Supply the source device name when preparing the project:

```sh
swift run xcode-mcp-proxy-tool-verifier previews prepare \
  --fixture physical --device-name "Your iPhone" \
  --build-settings ProxyToolVerifierOutput/local-signing.json \
  --output ProxyToolVerifierOutput/physical
```

The build-settings file maps target names to configuration names and string
values. For example:

```json
{
  "ProxyToolVerifierFixture": {
    "Debug": {
      "CODE_SIGNING_ALLOWED[sdk=iphoneos*]": "YES",
      "CODE_SIGN_STYLE[sdk=iphoneos*]": "Automatic",
      "DEVELOPMENT_TEAM[sdk=iphoneos*]": "YOUR_TEAM_ID",
      "CODE_SIGN_IDENTITY[sdk=iphoneos*]": "Apple Development",
      "PROVISIONING_PROFILE_SPECIFIER[sdk=iphoneos*]": ""
    }
  },
  "OriginalWidgetProbeExtension": {
    "Debug": {
      "CODE_SIGNING_ALLOWED[sdk=iphoneos*]": "YES",
      "CODE_SIGN_STYLE[sdk=iphoneos*]": "Automatic",
      "DEVELOPMENT_TEAM[sdk=iphoneos*]": "YOUR_TEAM_ID",
      "CODE_SIGN_IDENTITY[sdk=iphoneos*]": "Apple Development",
      "PROVISIONING_PROFILE_SPECIFIER[sdk=iphoneos*]": ""
    }
  }
}
```

Use only the app target for `physical-bare`. Preparation follows the target's
configuration references and writes the settings into its copied project. This
also supports settings such as `CODE_SIGNING_ALLOWED` that the native setting
tool may reject. It does not enable provisioning updates or register devices.
Keep team, profile, certificate, and device values in local output files.
The prepared projects retain those local settings, so review them before sharing.

Native physical capture uses Xcode's installation lifecycle. The fixture app and
PreviewShell process can remain after its document closes; the verifier closes
the document and MCP connection but does not uninstall physical-device apps.
Record pre-existing installations and processes so you can remove only those
created by your run, preserving existing app data and the system PreviewShell app.
