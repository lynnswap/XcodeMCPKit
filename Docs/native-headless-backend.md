# Native Xcode MCP Host Design

## Scope

XcodeMCPKit owns an MCP endpoint and one headless native workspace host. The
installed Xcode supplies enabled headless tool definitions and implementations;
ABIBridge invokes those contracts inside the helper. Build, test, editing, and
other actions use saved project models without a GUI window.

The host does not connect to GUI Xcode, launch `mcpbridge` or Xcode Service, or
modify Xcode's agent permission store. The GUI path required Apple-restricted
entitlements that an independently signed executable cannot use under normal
AMFI enforcement. Headless execution removes that dependency. The approved
scope is recorded in [issue #276](https://github.com/lynnswap/XcodeMCPKit/issues/276).

## Ownership

The package retains its public products and existing HTTP, STDIO, and Swift
client APIs. `XcodeMCPNativeHost` and `XcodeMCPNativeRuntime` use ABIBridge,
Foundation/AppKit, and the shared wire target without linking NIO. Apple
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

The separate process isolates AppKit state, loaded native libraries, and
termination handlers from the HTTP server. One host serves concurrent clients;
a client disconnect does not close a shared workspace. Host restart invalidates
its native identifiers and sessions. Mutations whose delivery is unknown are
not replayed against the replacement host.

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

Execution uses `DVTStatelessAction.executeStream(inputJSON:)` with concrete ABI
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

Xcode preferences are added process-locally so installed documentation can be
located. The workspace breakpoint manager is prepared on the main thread before
debugger launch to avoid the observed `DVTGlobalCustomDataStore.defaultStore`
assertion.

The existing crash-product correction selects by bundle ID and requested platform.
The inspected native `resolveCrashProductInfo(bundleId:platform:)` could otherwise
choose the first bundle-ID match with an App Store ID, including a different
platform's product and empty cache. The correction does not reorder global
inventory or alter caches. It remains separate from generic action execution and
can be removed when the affected native contract is fixed. Cached report
retrieval does not establish online/account-dependent retrieval.

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
