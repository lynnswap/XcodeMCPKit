# Native Xcode MCP Host Design

## Scope

XcodeMCPKit owns one MCP endpoint and independently managed headless native
workspace hosts. Each host loads its selected Xcode's tool definitions and
implementations; ABIBridge invokes those contracts inside the helper. Build,
test, editing, and other actions use saved project models without a GUI window.

The host does not connect to GUI Xcode, launch `mcpbridge` or Xcode Service, or
modify Xcode's agent permission store. The GUI path required Apple-restricted
entitlements that an independently signed executable cannot use under normal
AMFI enforcement. Headless execution removes that dependency. The approved
scope is recorded in [issue #276](https://github.com/lynnswap/XcodeMCPKit/issues/276).

## Ownership

The package retains its public products and existing HTTP, STDIO, and Swift
client APIs. `XcodeMCPNativeHost` and `XcodeMCPNativeRuntime` use ABIBridge,
Foundation/AppKit, and the shared wire target without linking NIO. The internal
`XcodeMCPInstallation` target shares installation discovery and path normalization
with the proxy without importing its networking runtime or ABIBridge. Apple
frameworks are loaded from the selected installation and are not redistributed.

| Resource | Owner |
| --- | --- |
| HTTP sessions, request correlation, deadlines, progress and cancellation | Proxy runtime |
| Host launch, process I/O, exit and restart | Process runtime |
| Xcode images, ABI handles and native values | Native runtime |
| Workspace identifiers, saved project models and selected operation settings | Native workspace registry |
| Action streams and native cancellation | Native runtime using Apple's executor |
| Per-request artifacts and conversation context | Native runtime |
| Build engine | Native host and its Swift Build child |
| Direct SwiftUI preview build, rendering, and temporary Simulator cleanup | Native preview correction |

The separate process isolates AppKit state, loaded native libraries, and
termination handlers from the HTTP server. The broker owns logical host
identities and client selections; each host keeps an independent runtime,
native catalog, and recovery path. A client can select another host while
earlier calls remain attached to their original backend channels.

One host can serve several clients, and a client disconnect does not close its
shared workspaces. Restart invalidates that host's native identifiers without
restarting other hosts. Mutations whose delivery is unknown are not replayed
against a replacement or another host. See the
[concurrent-host design](concurrent-native-hosts-design.md).

## Workspace access

`workspaceIdentifier` accepts a native identifier or an absolute `.xcworkspace`
or `.xcodeproj` path. The common resolver loads a model lazily for scoped
operations. `XcodeOpenWorkspace` supports explicit preloading and
`XcodeCloseWorkspace` closes an existing model without opening a missing one.

Models use saved files. Open GUI windows, unsaved buffers, and GUI scheme or
destination selection do not configure the host. Agents inspect and select the
host's scheme, destination, and test plan through the corresponding native tools.
Unscoped tools such as documentation search do not require a workspace.

## Dynamic tool contracts

The host reads the native action registry and `enabledHeadlessMCPTools` selection,
then converts the native input/output metadata into MCP descriptors. Registration
alone does not expose an internal action. Tool names and schemas are not stored
as a second hand-maintained catalog. Xcode 27 supplied 54 enabled headless tools
in the verified environment; that count is not an API guarantee.

The common context adapter injects `temporaryArtifactsPath` and `conversationID`.
It removes the native schema's internal `tabIdentifier` parameter and supplies
workspace context through the registry. Each request has its own artifacts
directory within a conversation. Origin metadata records the selected installation
and `toolCancellation: "task"`.

Most actions use `DVTStatelessAction.executeStream(inputJSON:)` with concrete ABI
metadata and conformance handles. JSON decoding, action behavior, output encoding,
and native errors remain Apple's implementation. Images and values stay alive
for the action stream. Progress and completion become MCP notifications/results;
a stream ending without a final result is an error. Cancellation cancels the
matching task and is cooperative after native dispatch.

New tools require no per-tool source changes when they use these shared
contracts. Changes to the registry, schema representation, scope protocols, or
executor ABI require updates at that boundary. Missing contracts produce
diagnostics. The host resolves addresses from the selected installation at
runtime instead of storing offsets or guessing private layouts.

## Initialization and signing

The helper creates an AppKit event loop, `IDEApplication`, and retained document
controller with prohibited activation policy, then initializes the headless IDE.
It remains a proper application bundle and terminates through the native
application lifecycle. Framework diagnostics go to stderr; stdout carries MCP.

The bundle retains `com.apple.dt.mcp-server` for Xcode's headless role selection.
Its code-signing identifier is `com.lynnswap.XcodeMCPNativeHost`. Launch uses the
owned executable's absolute path. These identifiers do not grant Apple privileges.

`scripts/build-native-host.sh` assembles and signs the app and nested libraries.
It uses only the public
`com.apple.security.cs.allow-dyld-environment-variables` entitlement so the loader
can relaunch with paths for the selected Xcode frameworks under hardened runtime.
Apple Service entitlements and BoardServices registration are not copied.
Source builds use ad-hoc signing; distribution uses the repository's Developer ID
and notarization workflow.

Build/test success under SIP and AMFI does not establish every preview, device,
debugger, account, or analytics operation. Such tools retain the permissions and
services required by the native implementation. Authentication equivalence cannot
be inferred from a matching bundle identifier or a successful notarization.

## Native corrections

Before loading Xcode frameworks, the host selects the latest installed developer
documentation asset by Xcode version and then documentation release. It supplies
that index through a process-local `IDEChatDocumentationSearchConfigURL` value.
This avoids dependence on the headless downloadable-asset coordinator finding
an index and leaves persisted Xcode preferences unchanged. DocumentationSearch
continues through the native action executor without a generated helper process.
Restart the host after installing newer documentation to select the new asset.

The host also resolves the installed Metal compiler with `xcrun` under the
selected developer directory. For a downloaded Metal Toolchain, it supplies
the containing directory and the identifier from `ToolchainInfo.plist` to
Xcode's native downloadable-toolchain provider through process-local settings.
Swift Build scans the containing directory for `.xctoolchain` bundles; passing
the bundle itself leaves the compiler stub selected. This setup runs before
Xcode initializes the provider and keeps the build service selected by the
caller. Install the Metal Toolchain separately and restart the host after
installing or replacing it. Persisted Xcode preferences are unchanged.

The workspace breakpoint manager is prepared on the main thread before
debugger launch to avoid the observed `DVTGlobalCustomDataStore.defaultStore`
assertion.

The existing crash-product correction selects by bundle ID and requested platform.
The inspected native `resolveCrashProductInfo(bundleId:platform:)` could otherwise
choose the first bundle-ID match with an App Store ID, including a different
platform's product and empty cache. The correction does not reorder global
inventory or alter caches. It remains separate from generic action execution and
can be removed when the affected native contract is fixed. Cached report
retrieval does not establish online/account-dependent retrieval.

`RenderPreview` uses a packaged iOS Simulator renderer for individual SwiftUI
`#Preview` definitions in an arm64 Simulator application built with a debug dylib,
on iOS 18.4 or later.
The host builds the active scheme through Xcode's build engine, selects the
definition from the built `PreviewRegistry` metadata, including linked embedded
frameworks and libraries, and extracts its view with
ABIBridge. A public `UIHostingController` renders the view and captures the image.
Framework and library sources use an application that embeds their runtime image
or links their object/archive product, including linker file lists. Application
target ordering does not determine the host.
This route does not contact `previewsd` or require its Apple-restricted entitlement.
The renderer sets `XCODE_RUNNING_FOR_PREVIEWS` before loading the target's code
and signals SwiftUI when the preview code is ready, so preview-specific data is
available without leaving SwiftUI's graph waiting for injection.
It supports the preview's device, fixed-size, or size-that-fits layout and a locale
override. Locale overrides set the renderer's launch language preferences and
SwiftUI environment. The response's `supportedLocalizations` comes from Xcode's
workspace. The image captures the rectangular hosting view; hardware display
cutout masks are not applied.
Size-that-fits uses the hosting view's intrinsic size without a screen-size cap.

Each render creates a Simulator matching the selected destination's device type
and runtime. Without a destination override, it retains the workspace's active
destination; unsupported destinations use the native pipeline. The returned
`renderedDestination.identifier` identifies that selected destination for reuse.
The correction deletes its temporary Simulator after success, failure, timeout, or
cancellation, and reports cleanup failures. The correction does not boot, install
to, or delete existing Simulator devices or change the workspace's active run
destination. Framework diagnostics and
subprocess logs remain in the request's artifacts directory.
The staged application bundle is removed after rendering or failure; snapshots
and diagnostics remain available.
Before replacing the main executable, the correction reads its signed entitlements
and its separate Simulator `__TEXT,__entitlements` section. The packaged renderer
archive is relinked with the original section when present, and the original signed
entitlements are applied to the final application signature. This preserves App
Group and Keychain access without putting Simulator-only entitlements into the
real signature, where AMFI can reject them. Unsigned products remain supported.
Source and destination resolution and initial ABI binding precede the timeout;
the timeout covers the native build and rendering, including a late switch to
the native preview pipeline. Cleanup failures after timeout are reported with the
timeout error. The build method binding is
cached for subsequent requests. Initial binding can make the first request take
longer than the rendering timeout.

Targets without an application host or with its debug dylib disabled, other
platforms, `PreviewProvider` definitions, grouped previews, WidgetKit
previews, orientation and modifier traits, variant overrides, and canvas controls
continue through Xcode's native preview pipeline. Those operations retain its service and entitlement
requirements, including the limitation tracked in
[issue #302](https://github.com/lynnswap/XcodeMCPKit/issues/302). WidgetKit's
container background requires a protocol-extension call that ABIBridge 0.9.0
cannot bind to a concrete view; the renderer does not return a partial widget.

The direct route depends on private `DeveloperToolsSupport`/SwiftUI source
contracts, SwiftUI's underscored `__previewThunksHaveFinishedLoading()` readiness
signal, and Xcode's private build interfaces. The trait list is inspected with
Swift reflection because `Preview` has no exported getter for it; traits other
than layout use the native pipeline. The renderer resolves its view contracts from
the selected Xcode and installed Simulator runtime. Unsupported input contracts
use the native pipeline; other contract changes produce diagnostics.
Build failures are reported before rendering so stale products are not captured.
`scripts/build-native-host.sh` builds and bundles the Simulator renderer using
the selected developer directory. Apple frameworks are supplied by the installed
runtime.

## Standalone host

```sh
./scripts/build-native-host.sh --developer-dir /Applications/Xcode.app/Contents/Developer
.build/native/XcodeMCPNativeHost.app/Contents/MacOS/xcode-mcp-native-host
```

Launch the packaged executable; the bare SwiftPM binary lacks the required app
bundle. After MCP initialization, `tools/list` returns the headless catalog and
`tools/call` executes its contracts. EOF cancels outstanding requests and closes
models owned by this host. Explicit helper and developer-directory URLs are also
available through the public embedding configuration.
