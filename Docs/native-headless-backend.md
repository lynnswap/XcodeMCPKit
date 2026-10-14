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

`RenderPreview` uses packaged platform renderers for SwiftUI, UIKit, and AppKit
`#Preview` definitions, SwiftUI `PreviewProvider` definitions, and iOS WidgetKit previews
in an arm64 application or app extension built with a debug dylib. The packaged
hosts cover iOS 18.4+, tvOS 18.4+, visionOS 2.4+, and watchOS 11.4+ Simulators,
plus macOS 15.4+ and Mac Catalyst 18.4+ on the local Mac.
The host builds the active scheme through Xcode's build engine, selects the
definition in source order, including files that mix providers and registries.
It resolves registry metadata or a provider's type in the built image, including linked embedded
frameworks and libraries, and extracts its view with
ABIBridge. UIKit hosts use `UIHostingController`, macOS uses `NSHostingController`,
and watchOS attaches SwiftUI's underscored hosting view to the running watch app.
These hosts capture a live view hierarchy, including view lifecycle work.
Source and host selection retain the native buildable's identity. Among applications and extensions
that compile the source, embed its runtime image, or link its object/archive product
(including linker file lists), the active scheme's runnable application takes
precedence. When that runnable is not a compatible host, a unique compatible
host can be used; ambiguous candidates use the native pipeline.
Application target ordering does not determine the host. This selection does not
recreate Xcode's complete source-specific preview dependency graph.
Source and host records must use the same supported platform and arm64 architecture
before checking for ambiguity. An extension's own bundle supplies its resources,
identifier, and entitlements. A containing application's shared Frameworks are
copied when its embedded extension binary matches the source's build UUID;
the extension's own Frameworks take precedence. The containing application's
root resources and application lifecycle are not used.
Embedded runtime images are matched to the built source's arm64 build UUID,
with exact byte comparison when UUIDs are absent. A shared filename alone
does not establish that an application contains the source binary.
The renderer loads the source's embedded runtime image by its bundle-relative
path, including images that the application's debug dylib does not load itself.
This route does not contact `previewsd` or require its Apple-restricted entitlement.
The renderer sets `XCODE_RUNNING_FOR_PREVIEWS` before loading the target's code
and signals SwiftUI when the preview code is ready, so preview-specific data is
available without leaving SwiftUI's graph waiting for injection.
It supports the preview's device, fixed-size, or size-that-fits layout and a locale
override. Locale overrides set the renderer's launch language preferences and
SwiftUI environment. The response's `supportedLocalizations` comes from Xcode's
workspace. Device-layout snapshots apply the selected Simulator device's
framebuffer mask and its enabled display exclusion area. The exclusion uses UIKit's
native rectangle and PreviewShell's corner radius and curve, rendered into a
transparent portrait overlay. Snapshot composition rotates that overlay with the
native content orientation before downsampling. Fixed-size and size-that-fits snapshots retain their rectangular
hosting view. The longest image dimension is capped at 1500 pixels without
upscaling smaller images.
Remaining platform chrome and geometry outside the iOS scene host remain tracked in
[the snapshot parity issue](https://github.com/lynnswap/XcodeMCPKit/issues/311).
Size-that-fits uses the hosting view's intrinsic size without a screen-size cap.

On iOS, ordinary SwiftUI and UIKit previews accept Color Scheme, Contrast, Dynamic
Type, Control Borders, and Orientation overrides in `previewVariantOverrides`.
macOS and Mac Catalyst expose Color Scheme; tvOS exposes Color Scheme, Contrast,
and Control Borders; watchOS exposes Dynamic Type. visionOS display overrides
remain on the native pipeline pending a native static-preview contract.
`supportedPreviewVariantOverrides` returns their native display names and values.
Color scheme, contrast, and Dynamic Type reach both the SwiftUI environment and
UIKit hosting traits. Control Borders uses SwiftUI's button-shapes environment.
Portrait, upside-down portrait, and landscape source traits use the native
counterrotation controller and a dedicated preview window scene. Orientation
overrides use the same scene. The renderer creates a local FrontBoard pseudo scene
with the device's display configuration and native display-edge settings, so UIKit
computes preview safe areas without the original app scene's populated resolver.
Its reference frame stays in the display's fixed coordinate space; native scene
bounds apply the requested orientation. This path was verified on iOS 27.2 with
Xcode 27.1 and uses ABIBridge 0.9.0's existing Objective-C APIs. Unavailable private
scene APIs use the native pipeline.

Each render owns a fresh, nonpersistent scene session with a passive delegate.
It disconnects the window scene, removes its session, and invalidates the native
scene on its call-out queue after capture, failure, or cancellation. The original
scene and session remain connected. A cleanup failure is returned with the render
failure; a successful result is published after cleanup completes. Widget snapshots
retain their existing hosting path.

UIKit previews retain their actual `UIView` or `UIViewController` in standard
SwiftUI representables. An `arguments:` group uses its native group closure and
section/index metadata. `previewCanvasControlOverrides.groupItemIndex` selects
an item, and `supportedCanvasControlOverrides.groupItems` returns the native
titles and indexes. An unsupported group index renders the default item and
returns the native warning in `errors`. `PreviewProvider` uses the first view in
SwiftUI's `_allPreviews`, retaining its name and layout, as native RenderPreview does.
Provider type identity comes from Xcode's native module and type path. Private
providers remain unavailable with Xcode 27.1, whose native RenderPreview also
reports `preview provider not found` for those definitions.
`PreviewModifier` calls `makeSharedContext()` once per concrete modifier type in
each render and applies the native modifier wrappers in their original order.
Provider contexts, device overrides, and other display traits, variants, or controls
still use the native pipeline.

On iOS Simulator, Widget previews support `StaticConfiguration` and `AppIntentConfiguration` in the
Small and Medium families. Previews can provide explicit `timeline:` entries or a
`timelineProvider:`. AppIntent provider previews retain the `using:` intent
supplied by the preview, including its default parameter values. The renderer obtains
the configuration's descriptor from `WidgetConfiguration.body` and applies its
descriptor preference transforms in their original order. It uses WidgetKit's
timeline provider context with `isPreview` enabled, the selected family, and
SpringBoard's metrics for the selected device. WidgetKit supplies the timeline's
actual `AnyView`, which is hosted with its common widget environment and
`.containerBackground(for: .widget)` content. The snapshot has the widget's
size and rounded corners, with transparency outside them.
`supportedCanvasControlOverrides.timelineIndexes` lists the available entries;
`previewCanvasControlOverrides.timelineIndex` selects an entry, defaulting to
the first. `supportedPreviewVariantOverrides["Widget Family"]` lists the
configuration's supported Small/Medium families, which can be selected through
`previewVariantOverrides`. Widget previews with disabled content margins or
changes to their descriptor's background style use the native pipeline.

Each Simulator render creates a device matching the selected destination's device
type and runtime. macOS and Mac Catalyst launch a staged application process and
return its snapshot through inherited stdout, including when the app is sandboxed.
Desktop destinations accept both Xcode's device identifier and its native preview
identifier, and return the latter (`dvtdevice-local-computer:localhost` for My Mac). Without a destination override, it retains the workspace's active
destination; unsupported destinations use the native pipeline. The returned
`renderedDestination.identifier` identifies that selected destination for reuse.
The correction deletes its temporary Simulator after success, failure, timeout, or
cancellation, and reports cleanup failures. The correction does not boot, install
to, or delete existing Simulator devices or change the workspace's active run
destination. Framework diagnostics and
subprocess logs remain in the request's artifacts directory.
The owned desktop process is stopped on cancellation or timeout. The staged
application bundle is removed after rendering or failure; snapshots
and diagnostics remain available.
The renderer starts its own application and scene lifecycle. Its executable,
package type, scene manifest, principal class, main storyboard, and extension
settings are replaced together, including platform- and device-qualified keys.
It retains the host's bundle resources and capabilities but does not run the
original `App.init` or application delegate. Preview bodies must supply their
required dependencies. Existing Simulator application data, App Group contents,
and Keychain entries are not copied to the temporary device.
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

Targets without an application or extension host or with its debug dylib disabled,
unsupported platform/architecture combinations, and source or display contracts beyond the direct capabilities described above
continue through Xcode's native preview pipeline. Those operations retain its service and entitlement
requirements, including the limitation tracked in
[issue #302](https://github.com/lynnswap/XcodeMCPKit/issues/302).

The direct route depends on private `DeveloperToolsSupport`/SwiftUI/WidgetKit source
contracts, SwiftUI's underscored `__previewThunksHaveFinishedLoading()` readiness
signal, SpringBoardHome/ChronoServices widget metrics, and Xcode's private build interfaces. The trait list is inspected with
Swift reflection because `Preview` has no exported getter for it; traits without
a direct implementation use the native pipeline. Widget descriptor and container background
fields are also read with Swift reflection because they have no exported getters.
Unknown widget configurations, descriptor transforms, or reflected representations use the
native pipeline instead of returning a partial widget. The renderer resolves its view contracts from
the selected Xcode and installed Simulator runtime. Unsupported input contracts
use the native pipeline; other contract changes produce diagnostics.
Build failures are reported before rendering so stale products are not captured.
`scripts/build-native-host.sh` builds and bundles separate renderers for all six
platforms using the selected developer directory. Apple frameworks are supplied by the installed
runtime. Device exclusion rendering also reads UIKit's display shape and the
SpringBoardServices/MobileGestalt enable conditions used by PreviewShell.

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
