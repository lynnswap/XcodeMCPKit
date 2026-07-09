# Review-thread classification: PRs 153–172 (20 merged PRs, 2026-06-29 → 2026-07-09)

## Data basis (confirmed)
- Fetched via GraphQL `reviewThreads` for PRs 153–172; no PR had `hasNextPage=true`. Total: **28 review threads**.
- **Every one of the 28 threads was authored by `chatgpt-codex-connector` (Codex review bot)**; every reply is by `lynnswap`; all threads are resolved. There are zero human-originated review threads in this window.
- Thread-bearing PRs: 156(1), 159(3), 160(5), 161(3), 162(1), 166(3), 167(3), 169(1), 170(8). Zero-thread PRs: 153, 154, 155, 157, 158, 163, 164, 165, 168, 171, 172.

## 1. Thread counts per responsibility area (confirmed, path-based)

| Area | Threads | PRs |
|---|---|---|
| Proxy session: process route catalog / activation / reconciliation staleness | **13** | 160(1), 161(3), 169(1), 170(8) |
| Proxy session: initialize lifecycle & timeouts (InitializeManager, +Initialization) | **7** | 160(3), 162(1), 166(3) |
| Proxy session: DocumentationProvider fallback ordering/budget | **5** | 159(2), 167(3) |
| Runtime startup readiness (MCPBridgeRuntime zero-slot auto-launch) | 1 | 160 |
| Packaging (Package.swift unsafeFlags on library product) | 1 | 159 |
| Docs — but actually a live-schema correctness bug (`interactSessionKey` vs `interactionSessionKey`) | 1 | 156 |
| HTTP gateway | **0** | — |
| stdio | **0** | — |
| CLI/installer | **0** | — |
| SDK core (XcodeMCPKit) | **0** | — |
| Tests/docs threads | 0 | — |

**25 of 28 threads (89%) are inside `Sources/XcodeMCPProxyKit/Internal/Session/**`**, and 20 of those 25 are in the RuntimeCoordinator/InitializeManager control-plane cluster. File-size context: RuntimeCoordinator.swift 1679 lines, RuntimeCoordinator+ControlPlane.swift 1475, RuntimeCoordinator+Initialization.swift 836, InitializeManager.swift 639, +XcodeProcessReconciliation.swift 472, +XcodeProcessRouteActivation.swift 444, DocumentationProvider.swift 4247 (wc -l, current main a1c6218e).

## 2. Recurring invariant classes (confirmed, quoted)

### Class A — stale async completion mutates already-invalidated state (≥13 threads; dominant)
Same invariant ("a completion may only write state if the attempt/generation that issued it is still current") re-flagged across four PRs:
- PR 161, `XcodeProcessRouteActivationTracker.swift`: "this line drops the saved `catalogRPCHandle` after canceling the catalog timeout but never cancels the RPC itself … that stale request/lease can remain in flight".
- PR 161, `RuntimeCoordinator+ControlPlane.swift`: "the secondary `tools/list` RPC is not stored on the activation attempt. The catalog-phase timeout only cancels stored handles, so that fallback RPC can outlive the timed-out attempt". Fix reply: "the route loop now registers every catalog RPC handle (including secondary fallbacks) on the activation attempt" — i.e. the invariant is enforced by remembering to register at each issue site.
- PR 166, `InitializeManager.swift:184`: "`initializeAttemptMatches` can still pass while `activePrimaryInitializeUpstreamIndex()` is already nil, so `handleInitializeResponse` can treat the removed session's response as the primary result".
- PR 170 (P1), `RuntimeCoordinator+ControlPlane.swift`: "this records the catalog in `processToolCatalogRegistry` **before** `applyToolCatalogSurfaceUpdate(... onlyIfGeneration:)` can reject the stale completion … defeating the intended stale-completion guard." — diagnostic: a generation guard already existed, but sat at the apply boundary, not at the mutation owner, so a new write path bypassed it.
- PR 170: "a late `tools/list` response from the old generation can repopulate the canonical tools cache that was explicitly cleared; the later guarded sync no longer protects against the stale write because it has already happened."
- PR 160, `+XcodeProcessReconciliation.swift:382`: "`retireProcessBoundRoute` stops and retires the slot without cancelling this waiter, so the delayed operation can restart/initialize an upstream bound to a stale `MCP_XCODE_PID` … the warm-init path already has `isActiveProcessBoundUpstream` guards, and the primary path needs the same kind" — reviewer explicitly notes the guard exists in one sibling path and is missing in another (copy-the-guard recurrence signal).

### Class B — timer/timeout lifetime not tied to the attempt that armed it (≈6 threads)
- PR 160, `InitializeManager.swift:136`: "the timeout scheduled for that waiter remains stored in `state.initTimeout` … letting the stale timeout's `failInitPending` drain and fail the new waiter immediately."
- PR 160, `InitializeManager.swift:239`: "`startEagerInitializePrimary()` can call `scheduleInitTimeout()` again and replace the existing timeout, effectively restarting the client's initialize deadline".
- PR 162, `RuntimeCoordinator+Initialization.swift`: "this unconditional `scheduleInitTimeout()` still stores a global initialize timeout. That stale timer … can later fire while a subsequent eager primary initialize is starting". Fix moved decision into the owner: "decides the rearm atomically in `InitializeManager.rearmInitTimeoutForRetry`".
- PR 170: "the returned `RuntimeScheduledTimeout` is discarded, so reset can only clear `scheduledProcessToolsCatalogRetryProcessIDs`" and the mirror bug "the stale entry remains in `scheduledProcessToolsCatalogRetries` and later … calls refuse to schedule another retry".

### Class C — duplicate/no-op surface publication (2 threads, PR 170)
- "clients receive two `notifications/tools/list_changed` for one process exit (and the last-route case clears/bumps the catalog generation twice)"; "return `.noChange` when neither a catalog nor an upstream mapping existed." Signature of two owners (route retirement path + registry removeProcess) both publishing the same surface.

### Class D — fallback candidate ordering / deadline budget in DocumentationProvider (4-5 threads across PR 159 → 167, same file)
- PR 159: "gives the primary installed-asset search only a fair-share slice of the caller's timeout … The primary attempt should use the caller's remaining deadline."
- PR 167 (the very next docs PR): "this passes the full request deadline to the first action target … the loop has no time left to try the next action target or fall back … Use a per-candidate budget (as the mcpbridge path does)." — the exact budget-splitting invariant re-litigated in the opposite direction one PR later; each new provider path re-implements candidate ordering + budgets inside a 4247-line file.
- PR 167 also flagged a regression from swapping an owner: "wiring a `NoopDocumentationSearchServiceRepairer` … will skip the repair path and report DocumentationSearch unavailable, regressing the previous recovery behavior."

### Class E — availability state and scheduling decisions owned by different components (1 thread, PR 169)
- "The upstream slot scheduler still selects among active initialized process-bound upstreams based on health and **does not consult `unavailableXcodeProcessIDs`** … defeating the backoff." Fix reply: "catalog-cooldown routes now expose no routable upstream indices" — moved the knowledge into the exposure owner (layer fix, not line appeasement).

## 3. Appeasement vs layer-fix assessment (confirmed replies + speculation marked)
- **Layer fixes (good)**: PR 162 (`rearmInitTimeoutForRetry` atomically in InitializeManager), PR 169 (exposure owner hides all sibling slots), PR 170 removeProcess→`.noChange` at registry layer, and PR 170 itself performed a consolidation: commit **2c677e05 "refactor(proxy): consolidate process route surface state"** replaced `ProcessToolCatalogRegistry.swift` / `XcodeProcessRouteActivationTracker.swift` with `ProcessRouteStore.swift`, `ProcessRouteReadinessStore.swift`, `ProcessToolSurfaceStore.swift` (files confirmed present on main; old files absent).
- **Per-call-site guard propagation (recurrence-prone)**: PR 161 "registers every catalog RPC handle … on the activation attempt" (registration is still a convention each issue site must follow); PR 170 "process catalog registry mutations are now generation-gated **and rolled back** when the guarded canonical apply is rejected" (two-phase write + rollback rather than a single gated mutation point); PR 160 primary-init path copying the warm-init path's `isActiveProcessBoundUpstream` guard. Speculation: the fact that PR 170 — *after* the store consolidation — still produced 8 staleness threads suggests generation/epoch gating is still enforced at call sites rather than inside the store's mutation API.
- **One rebutted finding**: PR 161 P1 ("Start dynamic slots before activation initialize") was rejected with cited evidence ("`ManagedUpstreamSlot.send` awaits the pending start attempt instead of returning `.unavailable(.notStarted)`") — reviewer findings are not being blindly appeased.

## 4. Follow-up chain evidence (title/body-based; zero-thread PRs are not silent areas)
- **Process route catalog chain — 7 PRs in 10 days**: 155 "Fix stalled proxy tools list requests" → 160 "Reconcile Xcode process routes dynamically" → 161 "Retry … catalog activation" → 165 (stabilize 161's flaky test; body: "test race in `processRouteActivationCatalogAcceptsSecondaryFallbackForCurrentAttempt`") → 168 "control-plane timeout for route activation catalog" → 169 "Fix process route catalog retry loop" → 170 "Fix process tools list surface recovery".
- **Initialize lifecycle chain**: 162 → 163 (test stabilization of 162's area) → 166.
- **Control-plane cancellation chain**: 153 "Drain control-plane cancellation tasks during shutdown" → 158 "Make control-plane cancellation cleanup deterministic".
- **Test-flake stabilization: 5 of 20 PRs** (154, 157, 163, 165, 171) exist only to deracify async runtime tests (HTTP pending responses, STDIO parallel runs, cached-initialize notifications, route-activation fallback). PR 171 body: "a manually delivered upstream response could race ahead of the test helper's pending-response registration."
- **Window routing (PR 172)**: 0 review threads, but the merge a1c6218e contains **7 commits, 6 of which are pre-merge hardening fixes on the same feature**: e9b6eed5 (feature) → 5ca620dd "ignore unavailable window owners" → 900f54c0 "let proxy tabs disambiguate owners" → 39d62ce5 "include workspace in proxy tabs" → 8fad7133 "harden owner conflict resolution" → 96d1378b "proxy pinned window lookups" → 436d7f94 "ignore unusable stale window owners". Confirmed via `git log a1c6218e^1..a1c6218e^2`. The commit subjects show the *same staleness/owner-conflict invariant class* (Class A) appearing in the brand-new window-owner area at birth. Speculation: window-owner state (`WindowOwnerIndex.swift`) is the next likely locus of Class-A findings.

## 5. Where findings do NOT concentrate (confirmed)
HTTP gateway, stdio adapter, CLI/installer, and the XcodeMCPKit SDK library received **zero review threads** across all 20 PRs; their only appearances are as test-flake stabilization targets (154, 157, 171). The audit hotspot is entirely intra-`XcodeMCPProxyKit/Internal/Session` — module boundaries themselves drew no findings.

# CANDIDATE FINDINGS

## [high] Staleness/generation invariant has no single mutation owner in the process-catalog control plane (proxy-session/process-catalog)
EVIDENCE: 13 review threads across PRs 160/161/169/170 flag stale async completions writing invalidated state. Key quote (PR 170, P1, RuntimeCoordinator+ControlPlane.swift): 'this records the catalog in processToolCatalogRegistry before applyToolCatalogSurfaceUpdate(... onlyIfGeneration:) can reject the stale completion... defeating the intended stale-completion guard.' Even after commit 2c677e05 consolidated state into ProcessRouteStore/ProcessRouteReadinessStore/ProcessToolSurfaceStore, PR 170 still drew 8 staleness threads. RuntimeCoordinator+ControlPlane.swift is 1475 lines on main (a1c6218e).
DIRECTION: Hypothesis: move generation/epoch validation inside the store mutation API (writes take the issuing generation and are rejected atomically at the store) instead of call-site guards + rollback; every RPC/lease should be registered by construction, not by convention.

## [high] Attempt-scoped resource lifetime (RPC handles, timeouts, waiters) enforced per call site by convention (proxy-session/initialize-lifecycle)
EVIDENCE: 7 initialize-lifecycle threads (PR 160 x3, 162, 166 x3) plus PR 161's two handle-registration threads share the pattern 'X scheduled by attempt N survives into attempt N+1'. PR 160 InitializeManager.swift:136: 'the timeout scheduled for that waiter remains stored in state.initTimeout... the stale timeout's failInitPending drain and fail the new waiter immediately.' PR 161 fix reply: 'the route loop now registers every catalog RPC handle (including secondary fallbacks) on the activation attempt' — registration remains a per-site obligation. PR 166 flagged that removeSession 'cancels whatever token is currently installed' (global) instead of the removed attempt's token.
DIRECTION: Hypothesis: an attempt-owning type (attempt struct owning its timeout, RPC handles, readiness token, waiter set) whose deinit/transition cancels everything, replacing the parallel dictionaries in InitializeManager/RuntimeCoordinator state.

## [medium] Review findings concentrate 89% in XcodeMCPProxyKit Internal/Session; zero in HTTP gateway, stdio, CLI, SDK core (module-boundary)
EVIDENCE: GraphQL thread paths for PRs 153-172: 25/28 threads under Sources/XcodeMCPProxyKit/Internal/Session/**; 0 threads on HTTPGateway/stdio/CLI/XcodeMCPKit files. Process-route-catalog area required 7 follow-up PRs in 10 days (155, 160, 161, 165, 168, 169, 170 per merged-PR titles/bodies).
DIRECTION: Hypothesis: module boundaries are sound; audit effort should target the RuntimeCoordinator control-plane cluster, not package layout.

## [medium] DocumentationProvider re-implements candidate ordering and deadline-budget splitting per provider path (proxy-session/documentation-provider)
EVIDENCE: Same budget invariant flagged in opposite directions in consecutive docs PRs: PR 159 'gives the primary installed-asset search only a fair-share slice of the caller's timeout' vs PR 167 'passes the full request deadline to the first action target... no time left to... fall back. Use a per-candidate budget (as the mcpbridge path does).' DocumentationProvider.swift is 4247 lines (wc -l on main a1c6218e). PR 167 also flagged NoopDocumentationSearchServiceRepairer regressing mcpbridge repair.
DIRECTION: Hypothesis: extract a single candidate-pipeline owner (ordered candidates + per-candidate budget + reserved-fallback slot) that all provider paths flow through.

## [medium] 5 of 20 merged PRs are pure async-test-flake stabilization — runtime is hard to observe deterministically from tests (tests)
EVIDENCE: PRs 154, 157, 163, 165, 171 exist only to fix test races (bodies confirmed). PR 165 body: 'the notification observation does not guarantee the secondary upstream has been marked as initialized in runtime state yet.' PR 171 body: 'a manually delivered upstream response could race ahead of the test helper's pending-response registration.'
DIRECTION: Hypothesis: tests lack a synchronous state-observation seam on RuntimeCoordinator/session state; flake fixes keep adding per-test wait loops instead of a deterministic quiescence/observation API.

## [medium] Window-owner routing (PR 172) inherited the staleness invariant class at birth: 6 pre-merge hardening commits, 0 review threads (window-routing)
EVIDENCE: git log a1c6218e^1..a1c6218e^2 shows 7 commits: feature e9b6eed5 plus 5ca620dd 'ignore unavailable window owners', 900f54c0 'disambiguate owners', 39d62ce5 'include workspace in proxy tabs', 8fad7133 'harden owner conflict resolution', 96d1378b 'proxy pinned window lookups', 436d7f94 'ignore unusable stale window owners'. Commit subjects match Class-A staleness/owner-conflict pattern seen in process-catalog threads. New owner file: Sources/XcodeMCPProxyKit/Internal/Session/Runtime/WindowOwnerIndex.swift.
DIRECTION: Hypothesis: WindowOwnerIndex is the next recurrence locus; check whether owner freshness/conflict resolution is validated inside the index or at each lookup call site.
