# Maintainer guide

## Module ownership

| Module | Responsibility |
| --- | --- |
| `XcodeMCPCore` | Package-internal JSON-RPC, framing, clocks, wire I/O, and subprocess primitives. No dependency on SDK or proxy consumers. |
| `XcodeMCPInstallation` | Installation discovery and path normalization shared by proxy and native host. |
| `XcodeMCPKit` | Public Swift client and MCP values. `MCPClientSessionAuthority` owns transport identity/recovery; `InitializedMCPClientSession` owns request correlation and progress lanes. |
| `XcodeMCPNativeRuntime` / `XcodeMCPNativeHost` | Xcode framework integration, native actions, headless workspace models, execution queues, and owned preview resources. |
| `XcodeMCPProxyRuntimeContract` | Package request/reply/session values and serving protocols. No execution or I/O state. |
| `XcodeMCPProxyRuntime` | Public tool contract and handle routing (`Broker/`), and one connection per host process with its catalog, request correlation, and recovery (`Host/`). |
| `XcodeMCPProxyHTTP` | Listener, protocol validation, MCP session lifetime (`HTTPSessionStore`), responses, and SSE delivery, including each request's progress on its POST response. Depends on the runtime contract rather than concrete Runtime. |
| `XcodeMCPPermissionAutomation` | Accessibility dialog recognition and opt-in approval monitor. Independent of native execution and routing. |
| `XcodeMCPProxyKit` | Public server facade, runtime/HTTP composition, discovery, CLI hosting, and installation. |

Runtime and HTTP use Core rather than importing the public SDK. Internal targets
remain package implementation, not library products. The SDK keeps transport
and session recovery in its client session authority.

## State and lifetime boundaries

The broker owns public workspace and device-session references and binds them to
native resources in owned headless hosts. Native workspace state remains
authoritative for contents, scheme, destination, and test plan. A handle must not
become a cached second copy of those values or silently move to a replacement host.

`NativeHostConnection` is the only owner of a host process. Each start increments
its generation; handles record the generation that created them, and a request
for an ended generation fails instead of reaching the replacement process. The
connection fails in-flight requests and reports the end before it stops the old
process, so the broker invalidates handles before a new process can answer. Its
catalog cache belongs to one generation and is discarded on a catalog change.

A headless request holds its workspace execution permit through preparation,
native stream drain, observed Operation completion, and cleanup. The action
bridge owns the relay consuming the original native stream. Cancelling the
request-facing iterator signals observed Operations but does not abandon that
relay. The next request for the same workspace waits for this boundary. An action
with no cancellable Operation can take until natural completion; opaque native
Swift Task handles are not joined by this mechanism.

Shutdown stops admission and awaits owned tasks before closing workspace and
transport resources. In the native host, the main task owns shutdown and runs it
once, for whichever comes first: input end, input or output failure, or a failure
that leaves Xcode's state in the process unreliable (such as a failed testable-state
hook). The failing request still gets its reply; the proxy then fails in-flight
requests and starts a new process on the next use. Input framing and preview
product digests run off the main actor, which Xcode's models use. `deinit` is a synchronous cancellation backstop and must not
spawn an unowned task or promise graceful shutdown. Report cleanup failure
alongside the original failure. Do not replay mutations with unknown delivery.

The native host retains a dedicated stdout descriptor for MCP messages and
redirects ordinary stdout to stderr, keeping framework output out of the protocol
stream. The proxy logs stderr lines without a recognized diagnostic format at
`debug`, including test progress and other console output. The default `info`
level hides them; `MCP_LOG_LEVEL=debug` makes them available for diagnosis.
Each line of the helper's own diagnostics carries
`[xcode-mcp-native-host] ERROR : ...` or
`[xcode-mcp-native-host] WARNING : ...`. Messages with an explicit severity
retain that level, and native-host NSLog diagnostics remain errors. Log filtering
does not change recovery: terminal CoreSimulator invalidation diagnostics still
end the affected host connection.

Parse an HTTP body once and pass its parsed message onward. Host and Origin validation happen
before routing or side effects; JSON-RPC arrays are rejected at the HTTP boundary.
See the [HTTP contract](architecture.md#streamable-http-contract) for session,
header, and notification-buffer behavior.

## Native integration constraints

The native host runs as an AppKit application with a retained document controller
and prohibited activation policy. Its separate process contains loaded Xcode
images, ABI values, termination handlers, and native workspace state. ABIBridge
resolves complete method signatures from the selected installation; missing
contracts produce diagnostics instead of guessed offsets or layouts.

The host reads the native action registry and `enabledHeadlessMCPTools` to obtain
backend capabilities. Native registration alone does not expose an internal
action. The action adapter supplies conversation and request-artifact context.
Workspace scope comes from the native contract. A stream ending without a final
result is an error. Public operations and backend metadata have separate owners;
a backend schema change must not replace the public contract.

Saved models are loaded lazily. A Swift package directory and its `Package.swift`
resolve to one model. Package resolution precedes initial destination readiness.
Removed workspace directories are cleaned up before later operations, while
models claimed by another active request remain open until that request drains.
Native error panels are suppressed in headless execution and their diagnostics
are attached to tool failures or stderr, so a locked desktop cannot block the
host waiting for modal dismissal.

Process-local corrections select the latest installed documentation index and
installed Metal toolchain without changing persisted Xcode preferences. The
Metal provider receives the directory containing `.xctoolchain` bundles, not the
bundle itself. Restart the host after replacing either asset. The breakpoint
manager is prepared on the main thread before debugger launch to avoid native
global-store initialization assertions.

### Crash acquisition and change reading

`SyncCrashReports` owns acquisition and bounded local import.
`ReadCrashChanges` reads committed changes without network access, workspace
resolution, or Products inventory. They replace the native crash actions in the
catalog; the native action input/output schemas are not decoded or invoked.

`StartCrashSync` saves an explicit bundle/platform request and starts a
host-owned job that follows all local import continuations. It returns before
product lookup or Organizer work. `WaitForCrashSync` observes saved state and
progress with a bounded wait; ending a wait or disconnecting its client leaves
the job running. `CancelCrashSync` requests cancellation and returns while
cleanup continues. Terminal state is published after the operation drains.
Job records and revisions persist in the crash cache. An owner lease prevents
another host from marking a live job interrupted; observing unfinished work
after its owner has exited records an interrupted state and recovery diagnostic.
Automatic import stops on a record failure and keeps the partial result's Sync
continuation for an explicit retry. Source-only errors still permit importing
the data that acquisition returned.

`ResumeCrashSync` creates a job with a new ID and `previousJobId` from saved
conditions of interrupted, failed, or cancelled work. It retains the original
job and its results, recovers saved pages and pending imports, and starts network
scans at the first page. Recovery selects the newest saved continuation for
an import run because previous continuation responses are immutable. Unreadable
acquisition snapshots retain their diagnostics while a new scan is attempted.
Active owners and completed jobs reject resume. Reclaiming a leftover Organizer requires the recorded PID, application path,
and launch date to match its running instance. Read checkpoints are independent
of the new job's acquisition and remain valid.

Network Sync starts a dedicated Apple-signed Xcode with
`NSWorkspace.OpenConfiguration`, `createsNewApplicationInstance`, and
`-ApplePersistenceIgnoreState YES`. Organizer uses its existing account;
Accessibility access is required. AX operations target that instance's PID,
and completion, failure, or cancellation requests normal termination. GUI
activation can occur. Other workspace operations stay headless.

The host opens the exact product/filter URL, clears name and unresolved-only
filters, waits for matching refreshed native cache headers and an idle crash
list, and collects 25-issue pages. Displayed names are not page identifiers;
unsymbolicated addresses can differ from the same issue's cached name. A normal
idle empty page establishes the end. A short list uses a pointer scroll gesture when needed; window or pointer
interference stops collection. Pages are copied from Organizer's eight-entry LRU
to the server's exact-query source store as they arrive. A cross-process lock
serializes access to Xcode's shared Products cache.

Detail URLs use stable issue IDs and request all-version, all-build,
all-channel yearly distributions and saved samples. The requested period selects
a distribution. A failed detail refresh may recover saved samples with unknown
freshness, without presenting a cached distribution as current. Partial attempts
preserve a complete exact source snapshot and retain usable recovery data.

Source snapshots contain metadata and log-directory references rather than
base64 bodies. The canonical query excludes the inventory-derived App Store ID;
explicit app/platform cache operations therefore need no workspace or inventory.
Product lookup remains inside the network fetch closure so lookup failures can
use exact-cache fallback. Original timestamps and diagnostics survive fallback.

A durable SQLite cache records scope identities, observed issue/content changes,
sync workqueues, and immutable read batches. Shared SHA-256 blobs hold sample
bytes. Verified unchanged local file identity/generation can reuse a blob;
otherwise import streams the file and hashes its contents. Source enumeration
and body import are separate so bounded imports do not materialize every body
before returning. A single oversized file is permitted as a streaming step to
avoid starvation. Blob publication precedes committed references to it.

Sync continuations preserve acquisition/import progress independently of consumer
positions. Read freezes a change high-water mark and page ordering. Each cursor
replays its saved result; only a terminal read returns a checkpoint for the next
window. Consumers keep their own tokens, without a server-side consumer registry
or acknowledgement operation. Cache status includes pending sync information for
resuming interrupted work. Read's JSON byte budget is separate from Sync's import
byte budget. Unavailable or mismatched tokens fail explicitly.

Per-issue observation watermarks retain the selected source's known cache refresh
time and the acquisition order, including observations whose content is unchanged.
Resuming an older issue batch cannot replace newer imported metadata; a known
older cache snapshot is also skipped when synchronized in a later run. Log imports
compare the actual saved file contents at import time.
Reader windows select each item's latest version at their upper boundary and
compare its content with the checkpoint version. Intermediate revisions are
coalesced; a return to the baseline content produces no change.

Observation order is local and provider scans are non-atomic. Optional log event
ordering places unknown dates last. No provider revision or conditional delta
API exists; unchanged issue metadata cannot justify skipping future sample checks.
Sample retention does not establish all incident history, and missing files or
issues do not establish deletion. Local read completion and acquisition progress
remain distinct. Counts describe native unique devices or saved samples and
cannot be treated as additive occurrence counts.

### Preview rendering

The direct renderer handles supported SwiftUI/UIKit/AppKit preview definitions
and WidgetKit contexts using packaged platform applications. Xcode still owns
build planning, definition identity, destination resolution, and supported native
metadata. Unsupported source/display contracts use the native preview pipeline,
including its service and entitlement requirements. Build failures must be
reported before capture so stale products are never presented as a new preview.

Source selection follows native build records and complete preflight identity.
Prefer the active scheme's compatible runnable; use a unique compatible host
when available. Ambiguous hosts retain the native route. Match embedded images
by build UUID or exact bytes when UUIDs are absent, never by filename alone.
Preserve source platform, architecture, and bundle ownership during staging.

Applications and extensions retain their resources and entitlements. Hostless
previews use the selected native recipe's preview agent identity. Dynamic images
follow transitive Mach-O dependencies and retain framework bundles. Static and
package roots use separate sidecars derived from Xcode's product graph, linker
inputs, and resource paths. Do not infer package resource ownership solely from
Mach-O type. `PACKAGE_RESOURCE_BUNDLE_PATH` points to staged package resources
and is resolved after Simulator installation when needed.

Packaged renderers own their application/scene lifecycle; they do not run the
original app initializer or delegate. Preview bodies supply their dependencies.
Original Simulator data, App Groups, and Keychain contents are not copied into
the temporary device. Preserve both signed entitlements and any Simulator-only
Mach-O entitlement section; putting the latter in the real signature can cause
AMFI rejection. Extension clients use a separate identifier to coexist with the
original extension; native Widget services use the original extension identity.

Each render owns its temporary scene. UIKit scenes require the native creation
notification, initial settings acknowledgement, and teardown on the call-out
queue. Preserve the original application's connected scene and session. Device
masking and orientation use native display configuration; fixed/fitting layouts
retain their own geometry. Static snapshots cap the longest dimension at 1500
pixels without upscaling. macOS capture uses the renderer window's own compositor
context and sRGB IOSurface to preserve materials and window corners; exported
snapshot mode objects must retain their identity. Unavailable private bindings
use the native pipeline; allocation/capture failures remain rendering errors.

Widgets use their registered extension and native preview description, controls,
provider state, and static snapshot services. Keep the client from taking the
foreground away from PreviewShell, which can suspend extension assertions.
Activity and legacy complication contexts preserve native attributes, timelines,
family, and appearance. Unknown reflected configurations or transforms use the
native route instead of constructing a partial preview. SwiftUI readiness must
be signalled after loading source code to avoid a graph waiting for injection.

A workspace's preview session owns staged products, renderers, and its temporary
Simulator. Reuse requires unchanged build inputs/products, execution context,
definition, locale, and native destination resolution. Re-resolve current
warnings and preferences on every call. Changed code, resources, or destination
retire the affected state before staging replacements. Closing a workspace,
failure, timeout, cancellation, and shutdown stop owned renderers and remove
owned devices/products, never the user's existing Simulator devices. Preserve
artifacts and report cleanup failures with the original error. Source resolution
and initial ABI binding can precede the rendering timeout.

### Packaging and signing

`scripts/build-native-host.sh` owns app assembly, Info.plist, entitlement, and
signing for source, Homebrew, and release builds. Launch the packaged executable;
the bare SwiftPM binary lacks its required bundle. The app retains the native
headless role identifier and uses its own code-signing identity. These identifiers
do not grant Apple privileges.

Only the public dynamic-loader entitlement is used for loading the selected
Xcode's frameworks under hardened runtime. Apple-restricted Service entitlements
and BoardServices registration are not copied. Workspace operations use owned
models, and crash downloads operate GUI Organizer without changing agent
permissions. The separate opt-in Accessibility monitor
presses recognized connection dialogs' Allow button.

Verify helper startup and workspace operations under normal SIP/AMFI, including
a Developer ID hardened-runtime build before distribution. Signing/notarization
alone does not prove access to a privileged service. Preview, device, debugger,
and account operations require their own checks.

## Verification

Run the relevant existing suite with an explicit macOS destination, for example:

```sh
xcodebuild test -workspace XcodeMCPKit.xcworkspace -scheme XcodeMCPProxyRuntimeTests -destination 'platform=macOS'
```

| Test target | Boundary |
| --- | --- |
| `XcodeMCPCoreTests` | Wire/framing and low-level HTTP transport. |
| `XcodeMCPProcessRuntimeTests` | Process I/O and termination with fake drivers and opt-in live cases. |
| `XcodeMCPNativeRuntimeTests` | Native schemas, workspace/execution lifetime, previews, and documentation assets. |
| `XcodeMCPProxyRuntimeTests` | Public/backend contracts, handle routing, scheduling, and recovery. |
| `XcodeMCPProxyHTTPTests` | HTTP/SSE gateway with a runtime-contract fake. |
| `ProxyIntegrationTests` | Actual HTTP/runtime and configuration composition. |
| `PublicProductContractTests` | Supported library consumers compiled from an external package. |

Core fixtures live in `XcodeMCPCoreTestSupport`, shared proxy fixtures in
`XcodeMCPProxyTestSupport`, and scripted host processes (`FakeHostSession`) in
`XcodeMCPProxyRuntimeTestSupport`. A fixture used by one suite stays with that
suite. Keep deterministic observations at owner boundaries instead of adding
production test hooks or reproducing internal branch order in assertions.

`scripts/verify-proxy-target-boundaries.sh` checks dependency direction;
`scripts/check.sh` runs the full local maintainer checks. Package test schemes
can include several targets. Filtering execution does not prove compilation
isolation; inspect `swift build --target <target> -v` when that boundary matters.
When moving suites, verify each discovery identifier belongs to exactly one CI
shard. CI compilation caches still require an actual incremental build.

Process suites opt in with `XCODE_MCP_RUN_PROCESS_TESTS=1`. Stress tests opt in
with `XCODE_MCP_RUN_STRESS_TESTS=1` and are excluded from normal checks/CI. The
manual live-server benchmark is:

```sh
python3 scripts/benchmark-live-server.py --agents 4 --requests-per-agent 100
```

It uses persistent sessions against a running server and deletes those sessions
on exit. Non-loopback endpoints require `--allow-non-loopback`.

For live checks, use the [tool verifier](../Sources/XcodeMCPProxyToolVerifier/README.md)
and disposable saved projects with an explicit scheme, destination, and test plan.
The legacy `ProxyLiveMCPBridgeTests` suite name remains a test identifier for
owned-host smoke cases. Verify workspace listing and operations with GUI Xcode
both closed and running; neither case may connect to the GUI process or require
its MCP connection approval.
Isolate discovery, fixtures, and logs under a temporary root and stop only servers,
models, devices, and processes created by the run. Do not use the user's default
discovery file for tests. Match verification claims to the operations actually run.

## Release

[Homebrew distribution](../Homebrew/README.md) owns approval, publication, bottle
verification, and recovery. Approved releases use `scripts/release.py start`;
source CI pins the commit and content, prepares the draft and Formula, and waits
for publication approval before tap dispatch. Both source and Homebrew installs
keep the signed helper beside the commands. Release orchestration tests use:

```sh
python3 -B -m unittest discover -s scripts/tests -v
```
