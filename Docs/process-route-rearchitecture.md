# Process Route Readiness Rearchitecture

## Goal

Keep one stable proxy endpoint while Xcode processes come and go, and make a
newly ready process route attach without depending on call-site ordering.

The internal objective is to move process route state out of
`RuntimeCoordinator` patch paths. A process route catalog acquisition must be a
single owner-managed transaction: route exposure, catalog admissibility,
surface commit, retry/deadline, and canonical cache projection cannot be
assembled independently at each caller.

## Scope

External compatibility is preserved:

- No public Swift API changes.
- No CLI or environment variable changes.
- No MCP wire shape changes.
- No persisted `tools/list` cache.

This is a single-target internal rearchitecture inside `XcodeMCPProxyKit`.

## Phase 1 Measurements

Baseline from `codex/process-tools-list-surface` at
`258ace4773a2eec41f6e3607095ee7fba9abf061`.

- `RuntimeCoordinator*.swift`: 7,629 total lines.
- Largest runtime files:
  - `RuntimeCoordinator.swift`: 1,611 lines.
  - `RuntimeCoordinator+ControlPlane.swift`: 1,485 lines.
  - `RuntimeCoordinator+XcodeProcessRouting.swift`: 1,176 lines.
  - `RuntimeCoordinator+UpstreamRouting.swift`: 1,172 lines.
  - `RuntimeCoordinator+Initialization.swift`: 836 lines.
- `RuntimeCoordinator` owns or directly reaches about 39 stored properties in
  its main declaration, plus extension-local helper state.
- Repeated process-route state references in runtime/tests:
  - `processToolSurfaceStore`: 72.
  - `xcodeProcessRouteActivationTracker`: 37.
  - `pendingProcessToolsCatalogRefreshProcessIDs`: 24.
  - `processToolCatalogExposedProcessIDs`: 14.
  - `applyToolCatalogSurfaceUpdate`: 11.
  - `unavailableXcodeProcessRoutes`: 8.
  - `scheduledProcessToolsCatalogRetries`: 7.
  - `cacheableAsCanonical`: 7.
  - `cachedOwnerBoundToolNames`: 4.
  - `rollbackRecordCatalogIfCurrent`: 3.
- Platform gates are not the issue: one `#if canImport(AppKit)` in
  `XcodeProcessEventMonitor.swift`.
- Access distribution in `XcodeMCPProxyKit`: 218 `public`, 124 `package`,
  one `open`. This change does not expand public surface.

Findings:

1. `RuntimeCoordinator` extension files are a false decomposition: they share
   one state space and rebuild the same route/catalog readiness decisions.
2. `XcodeProcessRegistry` only owns active/retired membership. Unavailable,
   cooldown, exposure, and readiness are outside it.
3. `ProcessToolSurfaceStore` mutation and canonical generation checks happen
   at separate call sites, which creates rollback patches.
4. Activation and missing-catalog retry are sibling lifecycle paths for the
   same process route catalog acquisition.
5. Canonical `tools/list` is used as a fallback source for owner-bound routing,
   creating a second source of truth; request owner hints are mixed into the
   same decision instead of being a separate routing signal.

## Target Model

### `ProcessRouteID`

Stable identity for a route generation.

```swift
struct ProcessRouteID: Hashable, Sendable {
    let processID: pid_t
    let instanceGeneration: UInt64
}
```

`pid_t` alone is not enough because stale completions from an old process
instance must not commit after a process restart.

### `ProcessRouteStore`

Owns process route membership and exposure.

Responsibility: store active/retired/unavailable process routes and produce
typed exposure snapshots.

```swift
final class ProcessRouteStore: Sendable {
    enum CooldownScope: Sendable {
        case route
        case catalog
    }

    struct Route: Sendable {
        let id: ProcessRouteID
        let target: XcodeProcessTarget
        let upstreamIndices: [Int]
    }

    struct ExposureSnapshot: Sendable {
        enum Policy: Sendable {
            case toolsCatalog
            case ownerRouting
            case windowDiscovery
            case initialization
        }

        let epoch: UInt64
        let policy: Policy
        let routes: [RouteExposure]
        let processIDs: Set<pid_t>
    }

    struct RouteExposure: Sendable {
        let route: Route
        let usableUpstreamIndices: [Int]
    }

    func reconcile(...)
    func markUnavailable(routeID: ProcessRouteID, scope: CooldownScope, untilUptimeNs: UInt64)
    func markAvailable(routeID: ProcessRouteID, scope: CooldownScope)
    func exposure(policy: ExposureSnapshot.Policy, upstreamStates: [UpstreamHealthManager.UpstreamState], nowUptimeNs: UInt64) -> ExposureSnapshot
}
```

`RuntimeCoordinator.unavailableXcodeProcessRoutes` is deleted. Exposure is not
recomputed ad hoc by `tools/list`, owner routing, and window routing.

### `ProcessRouteReadinessStore`

Owns route readiness and catalog acquisition lifecycle.

Responsibility: model initialize/catalog acquisition as one lease-based state
machine per route.

```swift
final class ProcessRouteReadinessStore: Sendable {
    enum State: Sendable, Equatable {
        case idle
        case initializing(upstreamIndex: Int, attempt: Int)
        case waitingCatalog(upstreamIndex: Int, attempt: Int)
        case ready(upstreamIndex: Int, attempt: Int)
        case backoff(attempt: Int, reason: RetryReason)
        case abandoned(reason: String)
    }

    enum CatalogOutcome: Sendable {
        case usable(rawResult: JSONValue)
        case empty
        case failed(any Error)
        case timedOut
        case cancelled
    }

    struct CatalogLease: Sendable {
        let routeID: ProcessRouteID
        let upstreamIndex: Int
        let attempt: Int
        let exposureEpoch: UInt64
    }

    func beginInitialization(routeID: ProcessRouteID, upstreamIndex: Int, nowUptimeNs: UInt64) -> Start?
    func markInitialized(routeID: ProcessRouteID, upstreamIndex: Int, nowUptimeNs: UInt64) -> CatalogLease?
    func finishCatalog(_ outcome: CatalogOutcome, lease: CatalogLease) -> ReadinessTransition
    func abandon(routeID: ProcessRouteID, reason: String) -> ReadinessTransition
}
```

This replaces `XcodeProcessRouteActivationTracker`,
`pendingProcessToolsCatalogRefreshProcessIDs`, and
`scheduledProcessToolsCatalogRetries` as independent state owners. Runtime code
still schedules timers and sends RPCs, but it does not decide state transitions.

### `ProcessToolSurfaceStore`

Owns process-bound tool catalogs and exposed surface projection.

Responsibility: store usable process catalogs, keep upstream-to-process
catalog mappings, and project the catalog set for the currently exposed
process IDs into a canonical surface update. Current route identity and
exposure epoch are validated immediately before callers mutate this store;
the store owns the idempotent catalog mutation and canonical projection result.

```swift
final class ProcessToolSurfaceStore: Sendable {
    struct Catalog: Sendable {
        let routeID: ProcessRouteID
        let target: XcodeProcessTarget
        let upstreamIndex: Int
        let rawResult: JSONValue
    }

    struct SurfaceUpdate: Sendable {
        enum CanonicalAction: Sendable {
            case noChange
            case syncCanonical(rawResult: JSONValue, sourceUpstream: Int)
            case clearCanonical
        }
    }

    func recordCatalog(routeID: ProcessRouteID, target: XcodeProcessTarget, upstreamIndex: Int, rawResult: JSONValue, exposedProcessIDs: Set<pid_t>?) -> SurfaceUpdate
    func removeProcess(processID: pid_t, exposedProcessIDs: Set<pid_t>?) -> SurfaceUpdate
    func removeUpstream(upstreamIndex: Int, replacementUpstreamIndex: Int?, exposedProcessIDs: Set<pid_t>?) -> SurfaceUpdate
    func recomputeSurface(exposedProcessIDs: Set<pid_t>, publishesToolsListChanged: Bool) -> SurfaceUpdate
    func availableToolCatalogSurface(processIDs: Set<pid_t>?) -> AvailableToolCatalog?
}
```

Empty `tools` remains a valid wire shape, but it is not a usable process-bound
catalog. It is rejected before `recordCatalog` and does not overwrite an
existing usable surface.

### `CanonicalBrokerState`

Remains the wire-facing canonical cache owner only.

It does not own process routing, owner-bound tool metadata, or process surface
currentness. It only receives projections from `ProcessToolSurfaceStore`:

```swift
enum CanonicalProjection: Sendable {
    case sync(rawResult: JSONValue, sourceUpstream: Int)
    case clear
    case noChange
}
```

## RuntimeCoordinator After

`RuntimeCoordinator` becomes an effect runner:

1. Discover/reconcile Xcode process targets.
2. Ask `ProcessRouteStore` for membership/exposure transitions.
3. Start/stop upstream slots and timers as effects.
4. Send initialize/tools RPCs.
5. Pass RPC outcomes back to `ProcessRouteReadinessStore`.
6. Pass usable catalog commits through the generation-gated surface mutation
   boundary.
7. Project complete surfaces into `CanonicalBrokerState` from that same
   boundary.

It must not:

- Store route unavailable/cooldown state.
- Store pending process catalog retry sets.
- Roll back catalog registry mutations.
- Infer owner-bound tools from canonical cache.
- Recompute exposure through unrelated helper paths.

## Consumer Flow Sketch

Foreground `tools/list`:

```swift
let exposure = routeStore.exposure(policy: .toolsCatalog, upstreamStates: states, nowUptimeNs: now())
let surface = surfaceStore.availableToolCatalogSurface(processIDs: exposure.processIDs)
if surface?.processIDs == exposure.processIDs {
    return .init(rawResult: surface.rawResult, sourceUpstream: surface.sourceUpstream)
}
readiness.scheduleCatalogAcquisition(for: missingRoutes(in: exposure), exposureEpoch: exposure.epoch)
return partialSurfaceOrUnavailable(surface)
```

Catalog completion:

```swift
let transition = readiness.finishCatalog(.usable(rawResult: raw), lease: lease)
guard case .catalogUsable = transition else { return }
guard routeLeaseIsCurrent(lease.routeID, exposureEpoch: lease.exposureEpoch) else { return }

let result = surfaceStore.recordCatalog(
    routeID: lease.routeID,
    target: target,
    upstreamIndex: lease.upstreamIndex,
    rawResult: raw,
    exposedProcessIDs: exposure.processIDs
)
apply(result)
```

Process exit:

```swift
let transition = routeStore.retire(routeID, reason: reason)
readiness.abandon(routeID: routeID, reason: "route_retired")
let surface = surfaceStore.removeRoute(routeID, exposure: transition.exposure)
apply(surface)
```

## Implemented Deletion List

- `RuntimeCoordinator.unavailableXcodeProcessRoutes`.
- `XcodeProcessRouteUnavailableRecord` as a free-standing runtime record.
- `pendingProcessToolsCatalogRefreshProcessIDs`.
- `scheduledProcessToolsCatalogRetries`.
- `XcodeProcessRouteActivationTracker` as a separate activation-only tracker.
- `ProcessToolSurfaceStore.rollbackRecordCatalogIfCurrent(...)`.
- `ProcessToolSurfaceStore.restoreCatalogIfMissing(...)`.
- Process-routing owner-bound fallback to canonical cached tools.
- Catalog `record -> apply -> rollback` recipes.

Still present by design:

- `RuntimeCoordinator.applyToolCatalogSurfaceUpdate(...)` remains the
  canonical projection applicator, but not the process-surface stale filter.
- `cacheableAsCanonical` remains at the generic `ControlPlaneCoordinator`
  boundary; process route currentness is carried by route ID and exposure epoch.
- `cachedOwnerBoundToolNames()` remains only for non process-routing fallback.
- `tabIdentifier` and `workspacePath` arguments remain process-routing signals
  even when process tool catalogs are still loading.

## Avoided Shapes

- Do not add another guard to `recordAvailableToolsCatalog`.
- Do not add another retry set next to activation retry.
- Do not keep old `ProcessToolSurfaceStore` and wrap it with a second
  surface owner.
- Do not use `CanonicalBrokerState.generation()` as a process route exposure
  epoch.
- Do not keep owner-bound routing alive by reading canonical cached tools; use
  request owner hints and the Xcode window owner map instead.

## Test Boundary

Owner-level tests replace call-site recipe tests:

- `ProcessRouteStoreTests`
  - reconcile adds/retires route generations.
  - route cooldown changes exposure once and expires deterministically.
  - `toolsCatalog`, `ownerRouting`, and `windowDiscovery` policies share one
    snapshot path with explicit policy differences.
- `ProcessRouteReadinessStoreTests`
  - initialize success creates a catalog lease.
  - empty catalog, catalog timeout, failure, and late response are lease-bound.
  - retry is one per route generation.
- `ProcessToolSurfaceStoreTests`
  - usable catalog commit requires current route ID and exposure epoch.
  - empty catalog cannot overwrite usable catalog.
  - remove route with remaining complete surface syncs remaining surface.
  - no-op remove does not publish or bump canonical projection.
- `ProxyRuntimeCoordinatorTests`
  - integration path only: process exit/restart/readiness and foreground
    `tools/list` behavior.
  - no direct `record -> apply -> rollback` recipes.

## Finding Response Table

| Finding | Design response |
| --- | --- |
| `RuntimeCoordinator` shared state across extension files | Move route, readiness, and surface state into three owner stores. |
| Active/retired owned separately from unavailable/cooldown | `ProcessRouteStore` owns all route membership and exposure. |
| Registry mutation before canonical generation guard | Runtime validates route ID, exposure epoch, and broker generation before `ProcessToolSurfaceStore` mutation; mutation and canonical projection share one generation-gated boundary, so rollback APIs are removed. |
| Activation retry and missing catalog retry are sibling paths | `ProcessRouteReadinessStore` owns one lease and retry state machine. |
| Canonical cache used as routing metadata fallback | Owner-bound routing reads exposed process surface metadata, and treats request `tabIdentifier` / `workspacePath` arguments as owner hints while catalogs are still loading. |
| Partial surface represented by loose `cacheableAsCanonical` flag | Process surface projection carries the present process IDs; `cacheableAsCanonical` is only the final control-plane projection decision. |

## Acceptance Checks

- `RuntimeCoordinator` no longer stores process route unavailable, process
  catalog pending retry, or activation tracker state.
- Process route exposure is read from `ProcessRouteStore.ExposureSnapshot`.
- Exposure epoch changes whenever route membership, cooldown, or cooldown
  pruning changes the exposed process set.
- Process catalog mutation cannot occur before route ID, exposure epoch, and
  broker generation are checked.
- `tools/list` canonical cache is not used as a process-surface stale filter.
- Owner-bound tool routing does not read canonical cache while process routing
  is enabled; owner-hinted requests still use the window owner map before
  process catalogs are available.
- Empty process catalog is rejected before surface overwrite.
- Focused owner tests and `swift test -Xswiftc -strict-concurrency=minimal`
  pass.
