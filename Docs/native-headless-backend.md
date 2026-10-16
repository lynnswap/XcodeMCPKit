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
`#Preview` definitions, SwiftUI `PreviewProvider` definitions, and iOS and watchOS WidgetKit previews
in an application or app extension built with a debug dylib, a standalone
dynamic or static framework, or a Swift package library. The packaged
hosts cover iOS 18.4+, tvOS 18.4+, visionOS 2.4+, and watchOS 11.4+ Simulators,
plus macOS 15.4+ and Mac Catalyst 18.4+ on the local Mac.
The renderers support arm64 executables on these platforms.
The host builds the active scheme through Xcode's build engine, selects the
definition in source order, including files that mix providers and registries.
It resolves registry metadata or a provider's type in the built image, including linked embedded
frameworks and libraries, and extracts its view with
ABIBridge. UIKit hosts use `UIHostingController`, macOS uses `NSHostingController`,
and watchOS attaches SwiftUI's underscored WatchKit hosting controller to the running watch app.
These hosts capture a live view hierarchy, including view lifecycle work.
Source and host selection retain the native buildable's identity. Among applications and extensions
that compile the source, embed its runtime image, or link its object/archive product
(including linker file lists), the active scheme's runnable application takes
precedence. When that runnable is not a compatible host, a unique compatible
host can be used; ambiguous candidates use the native pipeline.
For a source without a compatible application or extension, the selected native
destination recipe supplies Xcode's preview agent bundle. The renderer copies
that bundle and replaces its executable with the packaged renderer, preserving
the agent's bundle identifier and basename for `Bundle.main`. A destination
change obtains the agent from the newly selected recipe.
Dynamic frameworks are staged inside the agent application and retain their
bundle identifiers and resources for `Bundle(for:)` lookups. Linked frameworks and
dynamic libraries are copied with their resources, following the source image's
transitive Mach-O dependencies. Native build records, linker search paths, and
the importing image's runtime search paths locate built and prebuilt dependencies.
Resolved dependency references are adjusted to their staged locations
without changing the original build products.
Static archives and Swift package object products are linked into a preview
sidecar dylib using compiler autolink records and the targets' library/search
inputs. Xcode's build service supplies the selected source's dependency graph
and evaluates resource bundle paths using the completed build's parameters.
Xcode's product classifications define the preview roots and their dependency
boundaries independently of the built products' Mach-O types. Graph nodes without
built target descriptions retain their dependency edges but contribute no image.
Each static root and its owned static dependencies form a separate sidecar;
references to other roots use those roots' generated or built images.
Package roots classified as frameworks or dynamic libraries use the agent's
executable directory, preserving their native preview `Bundle.main` owner even
when their image must be linked from static inputs. Other static roots are staged
outside the agent under the native product directory's name for `Bundle(for:)`.
Dynamic dependencies beyond a package root retain their original framework bundles.
Package resource bundles reachable from the roots with available build products
are copied to the staged products directory.
The renderer sets
`PACKAGE_RESOURCE_BUNDLE_PATH` to that directory for `Bundle.module` lookups,
resolving the path after Simulator installation when necessary.
The sidecar uses the existing dependency staging and preview lifecycle.
A source-connected app supplies its native link command to the sidecar, preserving
host objects and library-loading options while loading the static source once.
The app retains its bundle, resources, entitlements, and launch environment;
the sidecar replaces its original debug image and retains the app's `Bundle(for:)`
ownership. Copied static framework resources are not assigned to classes linked
from its archive. Static-framework Widget definitions use their native extension
host for both `#Preview` and `PreviewProvider`.
Standalone static and dynamic framework images were compared with Xcode 27.1 on
macOS 26.6.2 and iOS 27.2, including static bundle lookup and dynamic framework
resources on macOS.
Source and host records must use the same supported platform and architecture
before checking for ambiguity. An extension's own bundle supplies its resources,
identifier, and entitlements. A containing application's shared Frameworks are
copied when its embedded extension binary matches the source's build UUID;
the extension's own Frameworks take precedence. The containing application's
root resources and application lifecycle are not used.
Embedded runtime images are matched to the build UUID,
with exact byte comparison when UUIDs are absent. A shared filename alone
does not establish that an application contains the source binary.
Code-signing and Simulator entitlements are read from the arm64 image.
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
UIKit size-that-fits uses the hosting view's intrinsic size without a screen-size
cap. watchOS uses its hosting controller's `sizeThatFits(in:)` with the selected
watch's screen bounds. Device layout preserves WatchKit's safe-area layout;
fixed-size and size-that-fits layouts disable it, matching the native hosts.
macOS uses the native caller's 600-by-400-point proposal. Device layout keeps that
proposal; size-that-fits uses `NSHostingController.sizeThatFits(in:)` with it.
Fixed-size layout uses the source dimensions. AppKit's normal hosting constraints
can resize the attached window; the renderer does not overwrite the result with
the view's `fittingSize`.

On macOS, `PreviewsInjection.MacOSPreviewHostingWindow` supplies active key/main
appearance without activating the renderer application. Device layout uses
full-size content so AppKit computes the titlebar safe area. Fixed-size layout
retains the hosting controller's normal sizing constraints.
`NSView.cacheDisplay` omits the window backdrop and WindowServer corner clipping,
so the renderer captures its own window through QuartzCore's
`CARenderServerSnapshot`. The context list contains only that window's
`layerHostingContextID`; the display name comes from `CADisplay.mainDisplay.name`.
The capture destination is a BGRA8 IOSurface tagged sRGB. The window's color space
remains at its system value, preserving native compositing and material colors.
The captured bitmap includes window corners; no radius or color correction is
applied. The window is made transparent before registration and ordered out after
capture, failure, or cancellation. It is closed before publishing a result.

This macOS path was verified with macOS 26.6.2 and Xcode 27.1 using ABIBridge 0.9.0.
Its private C call uses the observed 32-bit port, dictionary pointer, and normalized
0/1 return-register contract; the public SDK has no declaration for that function.
Snapshot option keys and the include-context-list mode are read from the exported
NSString objects, because QuartzCore compares the mode by object identity.
Unavailable private bindings use the native preview pipeline. Surface allocation,
capture, and image-conversion failures are reported as rendering errors.

On iOS, ordinary SwiftUI and UIKit previews accept Color Scheme, Contrast, Dynamic
Type, Control Borders, and Orientation overrides in `previewVariantOverrides`.
macOS and Mac Catalyst expose Color Scheme; tvOS exposes Color Scheme, Contrast,
and Control Borders; watchOS exposes Dynamic Type. visionOS display overrides
remain on the native pipeline pending a native static-preview contract.
`supportedPreviewVariantOverrides` returns their native display names and values.
For ordinary previews, unsupported groups or values are ignored and reported in
`errors`. Valid overrides still apply, and the response retains the snapshot and
supported override catalog.
Color scheme, contrast, and Dynamic Type reach both the SwiftUI environment and
UIKit hosting traits. Control Borders uses SwiftUI's button-shapes environment.
On iOS 26 and later, SwiftUI previews also apply `.assistiveAccess` through the
native `clarityUIIdiom()` transform after user preview modifiers. The effective
value comes from `Preview.value(for:)`, preserving native trait combination.
The transform uses ABIBridge 0.10.0 to resolve its opaque view result; unavailable
private bindings use the native pipeline. It preserves the native preview's
read-only `accessibilityAssistiveAccessEnabled` value. The trait has no effect on
other platforms, as documented by
[`PreviewTrait.assistiveAccess`](https://developer.apple.com/documentation/developertoolssupport/previewtrait/assistiveaccess).
Portrait, upside-down portrait, and landscape source traits use the native
counterrotation controller and a dedicated preview window scene. Orientation
overrides use the same scene. The renderer creates a local FrontBoard pseudo scene
with the device's display configuration and native display-edge settings, so UIKit
computes preview safe areas without the original app scene's populated resolver.
Its reference frame stays in the display's fixed coordinate space; native scene
bounds apply the requested orientation. This path was verified on iOS 27.2 with
Xcode 27.1 and uses ABIBridge 0.9.0's existing Objective-C APIs. Unavailable private
scene APIs use the native pipeline.
On Mac Catalyst, source orientation traits leave static snapshots unrotated,
matching native RenderPreview.

On tvOS, previews use the same scene owner with the original scene's display and
orientation settings. Fixed-size previews use the source's requested frame;
device previews use the display bounds. `sizeThatFits` measures with the finite
display size and resizes the scene to the result. The hosting controller retains
its default sizing options and native safe-area regions, so overscan applies to
all sides of the preview frame. Its background comes from UIKit's native
`systemBackgroundColor` selector, which the public tvOS color API does not expose.
All three layouts were verified on tvOS 27.0 with Xcode 27.1.
Unavailable private scene or color bindings use the native pipeline.

Static iOS and tvOS snapshots allocate integer pixel dimensions with the native
FBS snapshot's unsigned conversion and use a standard 8-bit renderer. The view's
point frame and drawing rectangle are retained, including fractional dimensions.
Mac Catalyst snapshots also use a standard 8-bit renderer to avoid introducing
RGB dithering when an extended-range bitmap is encoded as PNG.

Each render owns a fresh, nonpersistent scene session with a passive delegate.
After UIKit connects, the owner sends the workspace's initial nil-diff settings
notification to the scene delegate and waits for its commit response. This lets
UIKit retain its previous settings before later frame updates. The response can
arrive on a Core Animation queue, so the completion only resumes the caller.
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
Providers with a default-valued custom `PreviewContext` render as ordinary
SwiftUI views on iOS, macOS, Mac Catalyst, and tvOS.
`PreviewModifier` calls `makeSharedContext()` once per concrete modifier type in
each render and applies the native modifier wrappers in their original order.
Widget and Activity `PreviewProvider` definitions in an iOS or watchOS Widget
extension are evaluated by the registered extension. Its original program root
initializes WidgetKit before the provider's context is read. The renderer retains
the resulting native `PreviewDescription` for destination selection and rendering,
including contexts that forward their keys to another `PreviewContext`.
Activity `PreviewProvider` contexts outside this extension path use the original Widget or WidgetBundle
program root to find the Activity configuration whose native attributes type
matches the context. The root is discovered from compiler main symbols in the
built host's debug library, identified by its Mach-O UUID. WidgetBundle descriptor
preferences retain the original configuration modifiers. If the root or private
host/preference contract is unavailable, the request uses the native pipeline.
Other unsupported display traits, variants, or controls still use the native pipeline.

On iOS Simulator, Widget previews support `StaticConfiguration`, `IntentConfiguration`, and
`AppIntentConfiguration`. Previews can provide explicit `timeline:` entries or a
`timelineProvider:`. Intent and AppIntent provider previews retain the `using:`
intent supplied by the preview, including its default parameter values.
For a Widget extension embedded in an application, the renderer installs the
containing application in an isolated Simulator and launches the original extension
through PreviewShell's ServiceHub preview service. The client has a separate bundle
identifier so it can coexist with the registered extension, and runs as a command
without opening a UI scene. PreviewShell retains foreground activation; launching
the client as another foreground application can suspend the extension's preview
assertion. This path uses the
extension's native preview provider, Widget host, and static snapshot output without
contacting `previewsd`. It preserves native content margins, disabled margins,
container backgrounds, accessory presentation, and transparency.

The first static update discovers the preview's canvas controls. Requested control
states are then sent to the same preview session, preserving its timeline entries
and provider state. WidgetKit supplies the provider context with `isPreview: false`,
matching native RenderPreview. A `WidgetPreviewContext` retains its family and
source-level preferences through the extension's native preview description.
`supportedCanvasControlOverrides.timelineIndexes` lists the available entries;
`previewCanvasControlOverrides.timelineIndex` selects an entry, defaulting to
the first. An index outside the returned control catalog adds the native warning
to `errors` while preserving the native snapshot.
`supportedPreviewVariantOverrides` returns the installed Widget preview
plugin's catalog for `Widget Family`, `Presentation`, `Color Scheme`, and
`Dynamic Type`. These values can be selected together through
`previewVariantOverrides`; the renderer applies the catalog's native render effects.
The catalog depends on the preview category and installed runtime.

On watchOS Simulator, Relevance previews use the same extension service for explicit
entries, a provider, and a provider with supplied relevance. The native Smart Stack
host supplies the watch presentation and timeline controls.
The command owns the service connection until rendering ends. Cancellation stops
the command and runs the existing Simulator cleanup. The render's
Simulator, containing application, extension process, and client application are
removed by the existing Simulator cleanup owner; cleanup failures are reported
alongside the original failure.

On watchOS Simulator, legacy ClockKit complication `PreviewProvider` contexts
supported by native RenderPreview use ClockKit's timeline construction and
NanoTimeKit's watch-face controller. The renderer archives the source template
before creating a display scene, then attaches the controller to the running
watch application for capture. This preserves the source archive's environment,
template, and face color. The result retains the source metadata and selected
destination, with an empty display-variant catalog. The source layout controls
device masking; fixed and fitting layouts retain the native watch-face snapshot
size without the device mask.

Live Activity previews use WidgetKit's archived activity views and native
WidgetRenderer controllers. `previewVariantOverrides` selects `View Style`,
`Activity View Context`, `Color Scheme`, and `Dynamic Type`; the response lists
their supported values. `previewCanvasControlOverrides.timelineIndex` selects
a content state. For `#Preview`, `toggleState` adds stale states after each fresh
state, while the Stale activity context renders every state as stale. An unsupported
timeline index renders the first state and returns the native warning in `errors`.
An Activity `PreviewProvider` context supplies one attributes/state payload and
reports timeline index `0`. It retains the context's `isStale` and view kind unless
`Activity View Context` or `View Style` overrides them. Its toggle catalog matches
native RenderPreview, but toggling does not add states to this single payload.
The renderer keeps the selected style's orientation and preferred content size.
Activity archives receive the selected family and compact layout through
WidgetKit's canonical environment key paths. Dynamic Island styles use Dark
appearance regardless of the Color Scheme override, as native RenderPreview does.
StandBy and reduced-luminance content also use Dark appearance.
Activity labels use the containing application's localized name when that
application is available, falling back to the extension's name.
Other display controls retain the native pipeline for Live Activity previews.

Each Simulator render creates a device matching the selected destination's device
type and runtime. macOS and Mac Catalyst launch a staged application process and
return its snapshot through inherited stdout, including when the app is sandboxed.
Destination selection retains the decoded native RenderPreview input and the
selected source's translation unit. Xcode's source graph and update plan choose
the destination; the correction consumes the first native update record whose
execution-point pack matches the selected source's complete preflight pack.
This source-plan producer uses ABIBridge's enum-payload and protocol-member APIs
from main revision `2d75421a2c6796787f8deb4598505c4b8589395f`; ABIBridge 0.10.0
does not include the required enum-payload construction API.
Xcode's render-destination-choice setting controls whether
`preferredRenderDestination` is considered and `availableRenderDestinations` is
returned. The correction preserves that setting, the native destination fields,
and any unmatched-preference warning. `renderedDestination` describes the native
plan's chosen destination. Destinations unsupported by the direct renderer retain
the native pipeline.
For registry and provider previews, a first renderer process evaluates the preview
declaration and traits, then returns native preview metadata without invoking the
deferred view body. Providers also return the selected child's native preview
description, which supplies evaluated source-device preferences. The host decodes
these native property lists and plans again with
the evaluated content domain and effective destination preferences. Nonempty
operation preferences take precedence over source preferences. These RenderPreview
requests use the native Location's `none` requirements. The final renderer
evaluates the declaration again and renders its body. When the native destination
is unchanged, the host reuses the build and staged product; otherwise it builds
and stages the selected destination. Native platform-specific context, orientation,
and on-device support policies are preserved in the evaluated metadata.
Preview forms unsupported by the direct renderer retain
their existing native fallback behavior.
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

Targets whose application or extension host has its debug dylib disabled,
unsupported platform/architecture combinations, and source or display contracts beyond the direct capabilities described above
continue through Xcode's native preview pipeline. Those operations retain its service and entitlement
requirements, including the limitation tracked in
[issue #302](https://github.com/lynnswap/XcodeMCPKit/issues/302).

The direct route depends on private `DeveloperToolsSupport`/SwiftUI/WidgetKit source
contracts, SwiftUI's underscored `__previewThunksHaveFinishedLoading()` readiness
signal, SpringBoardHome/ChronoServices widget metrics, WidgetRenderer activity
archive and controller contracts, and Xcode's private build interfaces. The trait list is inspected with
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
