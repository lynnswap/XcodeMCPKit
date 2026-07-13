# Proxy Target Rearchitecture 2026-07 — Canonical Design

- Status: **APPROVED / IMPLEMENTED / VERIFIED**
- Approved: 2026-07-13
- Design baseline: `4b3c2ca493154091b267fd7beb0c1c20d9ff6438`
- Toolchain: Swift 6.3.3 / language mode 6 / strict memory safety / macOS 15.4+
- Baseline verification: `swift test --no-parallel -Xswiftc -strict-concurrency=minimal` — 926 tests / 59 suites passed in 40.091 seconds; the external product contract consumed 32.561 seconds.

This document is the only design source of truth for the proxy target migration approved on 2026-07-13. The implemented 2026-07 audit remains historical evidence; its “do not add targets” decision is superseded only for this migration.

## 1. Scope contract

### Outcome

Make the compiler enforce the boundary between proxy semantics and Streamable HTTP transport while preserving the existing `XcodeMCPProxyKit` public API. Align tests with those owners and make CI compile the package once per toolchain/source state instead of once per test shard.

### Compatibility

- Preserve the `XcodeMCPKit`, `XcodeMCPKitTesting`, and `XcodeMCPProxyKit` library products.
- Preserve the public source API and executable names.
- Preserve MCP wire behavior, proxy configuration behavior, server/adapter lifecycle, and release artifacts.
- Internal `package` and `internal` declarations may change without compatibility shims.

### Consumer stories

1. An external SwiftPM consumer imports `XcodeMCPProxyKit`, constructs `XcodeMCPProxyServer`, starts it, observes a sanitized status, and shuts it down.
2. An external SwiftPM consumer imports `XcodeMCPProxyKit`, constructs `XcodeMCPProxyStdioAdapter`, starts it, observes connection state, and stops it.
3. The repository executables invoke the public server/adapter run facades or the package-only installer facade.
4. `XcodeMCPProxyHTTP` consumes a package-only runtime port without reaching control-plane, lease, upstream, or session implementation types.

The external product contract fixture is the proxy for the first two consumers. There is no independently versioned consumer for Runtime or HTTP, so they remain internal targets in the same package and are not products.

### Non-goals

- No separate package or additional library product.
- No public API redesign or compatibility wrapper.
- No independent `ControlPlane`, `Core`, logging, process, or permission-dialog target.
- No tool behavior changes, new MCP feature, or release-format change.
- Build caching is an optimization; a cache hit never replaces an actual incremental build.

## 2. Phase 1 findings

1. `XcodeMCPProxyKit` is one 114-file target with 37k+ lines and all proxy dependencies, including NIO HTTP, TOML, AppKit, and runtime primitives.
2. The HTTP gateway reaches runtime implementation types such as `SessionContext`, `ProcessControlPlaneAuthority.CatalogDebugSnapshot`, `LeaseManager`, `ControlPlane.Route`, and `RefreshCodeIssues.DebugSnapshot`.
3. `RuntimeHTTPGatewayPort` is not a module surface: it composes implementation-level protocols and exposes NIO futures, event loops, upstream leases, and internal session identity graphs.
4. Runtime semantic owners are already explicit: `ProcessControlPlaneAuthority`, `WindowOwnershipAuthority`, `CanonicalHandshakeState`, `ControlPlaneCoordinator`, `UpstreamTopologyAuthority`, and `XcodeProcessEventMonitor`.
5. `RuntimeCoordinator` has 40 direct stored properties before its initializer. Target migration must not create a second mirrored runtime state or move these properties into a facade wrapper.
6. The largest proxy files are `DocumentationProvider.swift` (4,247 lines), `ProcessControlPlaneAuthority.swift` (2,582), and `RuntimeCoordinator.swift` (1,726), with additional `RuntimeCoordinator` extensions over 1,000 lines. Directory layout is not proof of owner separation.
7. Forty-two test/support files across ten targets use `@testable import XcodeMCPProxyKit`; five files additionally use a second-order `@testable import XcodeMCPProxyInternalTestSupport` chain.
8. The previous internal-target experiment was reverted within the same day. A new split must expose a narrow port and remove cross-owner access rather than mechanically move directories.
9. CI has eight matrix shards that each cold-build every source and test target. Most shard test bodies complete in under a second; compilation dominates runner time.
10. `PublicProductContractTests` creates a temporary external package on every run, preventing cross-run scratch-cache reuse; it accounts for most local default-suite time.
11. The watchdog polls every ten seconds, adding avoidable tail latency to short test invocations.
12. The default suite is locally green at the baseline, but GitHub Actions exposed two deterministic-contract gaps: a catalog lifecycle test asserted before `tools/list` completion, and stop-count waits can suspend without a bounded owner-state observation.

## 3. Target topology

```text
XcodeMCPProxyKit product
  └─ XcodeMCPProxyKit (public facade / composition root)
       ├─> XcodeMCPProxyHTTP (internal HTTP adapter)
       │     └─> XcodeMCPProxyRuntime (internal semantic owner)
       ├─> XcodeMCPProxyRuntime
       └─> XcodeMCPKit

XcodeMCPProxyRuntime ──> XcodeMCPKit
```

### `XcodeMCPProxyKit`

Responsibility: Compose the public proxy server and STDIO adapter lifecycles.

Owns:

- Existing public server/adapter types and configurations.
- Public-to-internal configuration projection.
- Discovery publication, executable-facing run facades, installer composition, logging bootstrap, permission automation, and live OS adapters.
- Start/shutdown ordering across HTTP, Runtime, discovery, and permission automation. HTTP owns and releases its NIO resources behind `ProxyHTTPGateway`.

Does not own route, catalog, upstream, JSON-RPC correlation, HTTP request, or SSE connection state.

### `XcodeMCPProxyRuntime`

Responsibility: Own proxy sessions and Xcode/upstream semantic execution.

Owns:

- Process/window control plane, canonical handshake/catalog, topology, health, scheduling, request leases, upstream routing, and request correlation.
- Documentation and Xcode feature workflows.
- Runtime session semantic state and notification production.
- Runtime snapshots and deterministic quiescence/state observation used by owner tests.

Constraints:

- No `NIOHTTP1` import.
- No `HTTPRequestHead`, `HTTPResponseStatus`, HTTP header, listener, channel-pipeline, or SSE framing type.
- Authority, lease, topology, health, and concrete session types remain `internal`.

### `XcodeMCPProxyHTTP`

Responsibility: Adapt Streamable HTTP connections to the proxy runtime port.

Owns:

- Listener/child-channel lifecycle, request security, route selection, body limits, HTTP status/header mapping, server-issued session IDs, negotiated-version enforcement, and SSE connection/buffer state.
- Cancellation of an admitted runtime operation when its channel or response write terminates.
- Encoding the sanitized runtime snapshot for the debug endpoint.

Constraints:

- Depends on Runtime only through the package API in section 4.
- Does not reference `ProcessControlPlaneAuthority`, `ControlPlane`, `LeaseManager`, `Upstream*`, `SessionContext`, `RuntimeCoordinator`, `DocumentationProvider`, or `RefreshCodeIssues`.

### Why `ControlPlane` is not a target

Control-plane owners consume topology proofs, health recovery leases, readiness tokens, scheduled timeouts, and upstream operation leases. Splitting it now would require either an additional file-bucket “Core” target or a large package surface that exposes the runtime’s implementation vocabulary. The owner boundary remains enforced by types inside `XcodeMCPProxyRuntime`; the module boundary is placed where an independent adapter and dependency direction actually exist.

## 4. Package API sketch

Names may be refined during implementation, but capabilities and ownership may not expand without updating this document first.

```swift
package struct ProxySessionID: Hashable, Sendable {
    package init(rawValue: String)
}

package enum ProxyRuntimeReply: Sendable {
    case response(Data)
    case accepted
}

package enum ProxyRuntimeEvent: Sendable {
    case notification(sessionID: ProxySessionID, data: Data)
    case sessionClosed(sessionID: ProxySessionID)
}

package protocol ProxyRuntimeRequestOperation: Sendable {
    func whenComplete(
        _ completion: @escaping @Sendable (Result<ProxyRuntimeReply, any Error>) -> Void
    )
    func cancel(reason: ProxyRuntimeCancellationReason)
}

package protocol ProxyRuntimeServing: Sendable {
    // Single HTTP consumer. Delivery is synchronous so this boundary owns no
    // second queue; the returned cancellation closure detaches the consumer.
    func subscribeToEvents(
        _ receive: @escaping @Sendable (ProxyRuntimeEvent) -> Void
    ) -> @Sendable () -> Void

    func beginRequest(
        _ message: ProxyRuntimeRequest,
        in sessionID: ProxySessionID?
    ) -> any ProxyRuntimeRequestOperation
    func sessionState(_ id: ProxySessionID) -> ProxyRuntimeSessionState
    func removeSession(_ id: ProxySessionID)
    func snapshot() -> ProxyRuntimeSnapshot
    func reset() async
}

package final class ProxyRuntime: ProxyRuntimeServing, Sendable {
    package init(configuration: ProxyRuntimeConfiguration)
    package func start()
    package func shutdown() async
}

package final class ProxyHTTPGateway: Sendable {
    package init(
        configuration: ProxyHTTPGatewayConfiguration,
        runtime: any ProxyRuntimeServing
    )
    package func start() async throws -> ProxyHTTPEndpoint
    package func shutdown() async
}
```

The implementation may use NIO internally. `EventLoop`, `EventLoopFuture`, `Channel`, runtime authority types, and cancellation-handle implementation types must not appear in the Runtime–HTTP package API. Runtime events have one HTTP gateway consumer and cross the target boundary synchronously in production order. This avoids both an unbounded inter-target queue and a lossy global bounded queue. HTTP alone owns the bounded per-session notification buffer and cancels the subscription before closing that store during shutdown.

`ProxyRuntimeRequestOperation` is the admission/cancellation boundary. HTTP may
cancel it when the channel closes or a response write fails, but it cannot
inspect the underlying request lease, upstream operation, router token, or
refresh task. `ProxyRuntimeSessionState` exposes only existence,
initialization, and negotiated protocol version; it does not expose
`SessionContext`.

## 5. Public API and consumer code

The public API remains the declarations reachable through these roots and their existing nested values:

- `XcodeMCPProxyServerConfiguration`
- `XcodeMCPProxyServer`
- `XcodeMCPProxyStdioAdapterConfiguration`
- `XcodeMCPProxyStdioAdapter`

Before and after consumer code is intentionally identical:

```swift
let server = XcodeMCPProxyServer(configuration: configuration)
let endpoint = try await server.start()
let status = await server.snapshot()
try await server.shutdown()
```

```swift
let adapter = try XcodeMCPProxyStdioAdapter(configuration: configuration)
try await adapter.start()
await adapter.stop()
```

All declarations in `XcodeMCPProxyRuntime` and `XcodeMCPProxyHTTP` are `package` or `internal`; both targets have zero `public`/`open` declarations. The external fixture must prove that recursive implementation modules expose no usable public declaration.

## 6. Variation axes and absorption points

| Axis | Absorption point | Variant-addition trace |
|---|---|---|
| Downstream transport | `XcodeMCPProxyHTTP` target plus `ProxyRuntimeServing` | Add one adapter target/type and compose it in the facade; Runtime files do not change |
| Live/test runtime | `ProxyRuntimeServing` witness | Add one fake in HTTP tests; production HTTP files do not branch |
| Xcode process inventory | Runtime-owned `XcodeProcessEventMonitor` and sanitized inventory snapshot | Add one Runtime witness and inject it; facade and HTTP do not inspect route owners |
| Tool behavior | Existing runtime feature/handler owners | Add the feature/handler and its registration; HTTP routing does not branch by tool |
| CI execution class | Workflow lane: default, process/pipe, live/stress, external contract | Add one lane/filter; production targets do not change |

## 7. Deletion list

- Delete `RuntimeHTTPGatewayPort` and the implementation-level protocol composition rooted at it.
- Delete HTTP access to `SessionContext`, `NotificationHub`, `JSONRPCResponseRouter`, control-plane snapshots, refresh coordinator/debug state, lease manager, and cancellation handles.
- Move SSE client/buffer ownership out of runtime session state and delete the mixed `SessionContext` transport graph.
- Delete `XcodeMCPProxyInternalTestSupport` and its second-order `@testable` imports.
- Fold runtime-only fixtures into Runtime tests; retain shared test support only where at least two test targets consume it.
- Replace the eight cold-build CI shards with one build and post-build test invocations.
- Replace the temporary external consumer root with a stable fixture/scratch path that can reuse its build state.
- Remove unbounded stop-count waits and test-hook ordering used as completion proof; use bounded owner-state/recorded-event observation.

## 8. Avoided shapes

- Do not keep old `RuntimeHTTPGatewayPort` beside a new `ProxyRuntimeServing` wrapper.
- Do not make `ProxyRuntimeServing` a renaming of the current twenty-plus methods or expose `SessionContext` through a package typealias.
- Do not add `XcodeMCPProxyCore`, `XcodeMCPProxyControlPlane`, `XcodeMCPProxySupport`, or a logging target to make imports compile.
- Do not duplicate `ProxyConfig` across targets or pass one monolithic configuration value to every target. Facade projects public/file configuration into owner-specific Runtime and HTTP values.
- Do not move `SSEHub` while leaving its buffer or subscriber truth mirrored in Runtime.
- Do not make cache hits skip `swift build`; restore is followed by an incremental build every time.
- Do not use an unpinned external GitHub Action or add cache-write permissions beyond the default cache protocol.

## 9. Test topology

- `XcodeMCPProxyRuntimeTests`: RuntimeCoordinator, control plane, upstream runtime, DocumentationProvider, tool surface, feature workflow, process inventory, and retained end-to-end Runtime/HTTP characterization contracts.
- `XcodeMCPProxyHTTPTests`: gateway lifecycle, SSE delivery, and transport-owned buffering against the narrow Runtime port. New transport behavior belongs here and uses a fake `ProxyRuntimeServing` witness.
- `ProxyIntegrationTests` and `ProxyCLITests`: public facades, CLI/configuration, discovery, permission automation, installer, logging, and composition lifecycle.
- Process/pipe, live, stress, and external-product tests remain isolated only when their execution environment or failure boundary differs.
- Runtime owner tests may `@testable import XcodeMCPProxyRuntime`; HTTP tests may `@testable import XcodeMCPProxyHTTP`. A support target may not use `@testable` to re-export another target’s internals.
- Async completion uses owner snapshots, fake clocks, recorded values with bounded waits, task handles, or explicit continuations. Wall-clock sleeps and unbounded `nextValue()` calls are not completion proof.

Characterization coverage before movement:

1. HTTP Origin/security rejection occurs before Runtime invocation.
2. Initialize creates exactly one HTTP session and exposes the negotiated protocol version.
3. Runtime notifications buffer while no SSE client exists and drain once to the next SSE client, including after reconnect gaps.
4. Channel termination cancels the admitted Runtime operation.
5. Server shutdown stops admission, HTTP channels, Runtime work, permission automation, discovery, and event-loop resources before returning.
6. Per-Xcode process catalog completion/logging remains independent across attached processes.

## 10. CI build/cache design

1. Select and fingerprint Xcode/Swift before cache restore.
2. Restore `.build` using a key containing cache schema, runner OS/architecture, toolchain fingerprint, `Package.swift`/`Package.resolved` hash, build-mode/flag fingerprint, and `github.sha`.
3. Use a restore prefix that removes only the final SHA, so the latest compatible successful cache becomes the incremental base.
4. Restore tracked build-input mtimes from their Git blob identities, invalidate the Git-derived build-info output, and always run `swift build --build-tests -Xswiftc -strict-concurrency=minimal` after restore.
5. Run default, process, and STDIO tests with `swift test --skip-build` and the exact same scratch path/flags.
6. Keep the watchdog, but remove ten-second completion polling latency and retain its stall diagnostics.
7. Give the external consumer fixture a stable path and scratch directory under the workspace so repeated positive/negative builds and subsequent CI runs reuse compiled dependencies.
8. Record cache hit/miss, build duration, and one diagnostic incremental-build run. Content-derived mtimes let Swift's incremental build record distinguish changed inputs without recompiling unchanged inputs after checkout.
9. Pin every external `uses:` reference to a full commit SHA with a version comment and verify its JavaScript runtime.

## 11. Findings-to-design mapping

| Finding | Design response |
|---|---|
| 1–3 mega target and leaked gateway surface | Sections 3–4 and deletion of `RuntimeHTTPGatewayPort` |
| 4 explicit semantic owners | Runtime target responsibility; authorities stay internal |
| 5 RuntimeCoordinator state graph | No facade mirror; Runtime retains canonical owners and reports stored-property before/after |
| 6 god files | Tests and source movement follow owners; no directory-only completion claim |
| 7 testable fan-out | Section 9 and deletion of InternalTestSupport |
| 8 failed prior split | Narrow port, internal-target public inventory, and prohibited Core/ControlPlane buckets |
| 9 duplicate cold builds | Section 10 build-once/test-many |
| 10 temporary contract fixture | Stable external fixture/scratch path |
| 11 watchdog tail latency | Section 10 polling rewrite |
| 12 CI flakes | Deterministic owner-state completion and bounded recorded-event waits |

## 12. Acceptance criteria

- `swift package describe --type json` matches section 3 and contains no dependency cycle.
- `XcodeMCPProxyRuntime` has no `NIOHTTP1` import; `XcodeMCPProxyHTTP` has none of the forbidden runtime implementation references.
- Runtime and HTTP contain zero real `public`/`open` declarations.
- The facade public surface matches the baseline external consumer contract.
- The old gateway protocol graph, mixed session/SSE state, and InternalTestSupport target are absent.
- All default, process, and STDIO tests pass with the repository’s strict flags.
- External product consumers build/link and expected-inaccessible probes fail for the intended access-control reason.
- CI builds tests once per job/source state and all post-build invocations use `--skip-build`.
- Cache keys include toolchain, dependency, flags, and source-state dimensions; all action refs are full-SHA pinned.
- Before/after measurements report target graph, public/package/open distribution, testable imports, RuntimeCoordinator stored properties, largest files, default-suite duration, contract-fixture duration, cold build, and compatible-cache build.
- `codex-review` reports no accepted unresolved findings; disputed findings include executable evidence.

## 13. Implementation and verification result

### Enforced graph and surface

- Package graph: `XcodeMCPProxyRuntime -> XcodeMCPKit`; `XcodeMCPProxyHTTP -> XcodeMCPProxyRuntime + XcodeMCPKit`; `XcodeMCPProxyKit -> XcodeMCPProxyHTTP + XcodeMCPProxyRuntime + XcodeMCPKit`.
- Public symbol graph: `XcodeMCPProxyKit` 127 symbols; `XcodeMCPProxyRuntime` 0; `XcodeMCPProxyHTTP` 0.
- Boundary script rejects Runtime HTTP imports/configuration leakage, facade listener ownership, HTTP concrete Runtime references, and restoration of the deleted target/support graph.
- `RuntimeCoordinator` direct stored-property inventory is unchanged from the baseline (the same source heuristic reports 41 declarations in both revisions, including one computed property; the design audit's direct stored-property count remains 40). No mirror runtime state was introduced.
- Largest semantic owners remain in Runtime: `DocumentationProvider.swift` 4,247 lines, `ProcessControlPlaneAuthority.swift` 2,582, and `RuntimeCoordinator.swift` 1,738. They moved to the semantic target without a file-bucket target or facade wrapper.

### Test ownership and coverage

- The second-order `XcodeMCPProxyInternalTestSupport` import chain is deleted.
- `@testable import XcodeMCPProxyKit` falls from 42 baseline files to 17. Current owner imports are 29 Runtime, 10 HTTP, 17 facade, 5 `XcodeMCPKit`, and 2 core-test-support occurrences across 50 files; files may import more than one module for retained end-to-end characterization.
- CI's seven major Runtime suites are explicit shards. The Runtime remainder is computed as the whole Runtime test target minus those seven suites, so a newly added suite cannot silently fall outside the matrix. The verified partition is 48/46/41/20/20/41/41 major tests, 386 Runtime remainder tests, and 288 tests in other targets.
- Final default suite: 933 tests / 61 suites in 13.485 seconds, compared with 926 / 59 in 40.091 seconds at baseline.
- Process lane: 24 tests / 5 suites. STDIO lane: 7 tests / 1 suite.
- Stable external product contract repeat: 6.549 seconds, compared with 32.561 seconds at baseline.

### Build and cache

- Isolated cold `swift build --build-tests -Xswiftc -strict-concurrency=minimal`: 48.45 seconds wall clock.
- Compatible restored-cache incremental build after the normalized cache seed: 5.17 seconds wall clock. Only the deliberately invalidated build-info source and its owning module were recompiled; the first normalization pass rebuilt the pre-normalization local cache in 52.95 seconds.
- Git-derived build info is explicitly invalidated after cache restore; tracked input mtimes are deterministically derived from Git blob identity before the mandatory incremental build.
- Checkout/cache actions are full-SHA pinned, `actionlint` and `shellcheck` pass, and every test shard restores the exact build artifact and uses `--skip-build`.

### Review closure

Accepted review findings fixed at their owners:

1. SSE notifications now buffer whenever no client is connected, including reconnect gaps.
2. The Runtime-to-HTTP queue was deleted; synchronous subscription leaves bounded per-session storage in HTTP only.
3. Permission-dialog inventory starts even when custom upstream configuration disables process routing.
4. Failed request operations terminalize their cancellation handles before crossing the Runtime boundary.
5. CI Runtime remainder is a complete difference set rather than a hand-maintained allow-list.
6. Session close events originate at `SessionRegistry`, covering DELETE, debug reset, and internal removal paths exactly once.

One finding is disputed: process-bound routing does start the live process monitor because `RuntimeCoordinator.start()` installs the change handler and `XcodeProcessEventMonitor.setChangeHandler` calls `start()`. The startup reconcile loop consumes changes that arrive during the initial snapshot. `processRoutingStartupConsumesInventoryChangeBeforeEagerInitialization`, `startCachesTheInitialRunningApplicationSnapshot`, and `launchAndTerminationReplaceTheTargetCache` pass as executable evidence.
