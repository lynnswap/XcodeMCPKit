# Fix-history classification — XcodeMCPKit (HEAD a1c6218e, 2026-07-10)

## 0. Method / caveats
- Full history: **686 non-merge commits** (`git log --oneline --no-merges | wc -l`). Initial commit 0b13facb (2026-02-04).
- Area classification is **subject-keyword + scope based** (script over `git log --pretty='%h|%ad|%s'`), not per-diff path analysis. Individual commits can be misbucketed by ±few; the distribution shape is robust. Per-file fix counts below (`git log --follow`) are exact and corroborate the shape.
- All diff-level claims below are confirmed by `git show` of the named SHA; HEAD line numbers are from the working tree at a1c6218e (clean per session snapshot).

## 1. Distribution: fix-type commits per responsibility area

Type prefixes over all 686: fix 364, refactor 128, test 71, docs 36, feat 21, ci 19, plus ~30 pre-conventional subjects (of which ~10 are fixes: `Fix pinning…`, `Fix tools/list caching…`, `Reset init state…`, etc.). **Total fix-type ≈ 374 of 686 = 54.5%.**

| Area | total commits | fix-type |
|---|---|---|
| (a) proxy session / process-catalog / tool-surface | 401 | **269** |
| (b) window-owner routing / Xcode target discovery | 38 | **33** |
| (c) HTTP gateway / Streamable HTTP | 32 | 25 |
| (d) stdio adapter | 12 | 6 |
| (e) CLI / installer / verifier | 30 | 15 |
| (f) XcodeMCPKit client SDK core | 28 | 18 |
| (g) tests-only | 71 | 0 |
| (h) docs / chore / ci / release | 74 | 8 |

**Areas (a)+(b) absorb 302/374 = 81% of all fixes.** Exact per-file corroboration (fix commits touching file, `--follow`):
- `Sources/XcodeMCPProxyKit/Internal/Session/Runtime/RuntimeCoordinator.swift` — **73 fix commits** (1,679 lines at HEAD)
- `.../RuntimeCoordinator+ControlPlane.swift` — **56 fix commits** (1,475 lines)
- `.../RuntimeCoordinator+XcodeProcessRouting.swift` — **45 fix commits** (1,522 lines)

Burst days (commits/day): 2026-06-24 = 74, 06-28 = 69, 06-13 = 46, 06-23 = 42, 07-02 = 37, 07-03 = 30, 07-08 = 23. Every burst >30 except 06-13 (refactor round) and 06-28 (target reorganization) is a feature-then-fix-wave in areas (a)/(b).

## 2. Chain A — process catalog / tool surface / activation (chronological)

Recurring waves, each triggered by a feature/refactor and followed by same-day/next-day fix storms:
1. **2026-02-10..13** tools/list cache guards: 07ed869f, d4823e92, bfbf5cd5, 0d0c5ade, 535c51ee, e67538d4, a4544687, 901b5f5d (`Fix tools/list caching and warmup quarantine`).
2. **2026-03-17..18** lease/scheduler wave: 9211a5e0 (retry leases), 5aa125fb (requeue retry leases), 65010c55 (archive abandoned leases), 133d3bda, cc5f8e9b.
3. **2026-06-23** 3a9f4ae5 `feat(proxy): route tools by Xcode process catalog` → **2026-06-24: ~20 catalog fixes in one day** (96b3335e drop stale process tool catalogs, 3690dcf1+620630fe *two commits same day with identical subject* "avoid caching partial process catalogs", c3378c9d, bf7a0d83, b8aa2f9c, 68568f7e, c097afdf…).
4. **2026-06-27..28** union/race wave: 815b5f89 (race catalogs), d52d2d57 (union completed), fea6e891 (wait for union), f3f951b8 (`separate route catalog owner boundaries`), 0684c703, 81b532ae, 1d97502a, 4d15aec7, 18d51279.
5. **2026-07-02** 6e07823e `feat(proxy): reconcile Xcode process routes dynamically` → **same-day wave of ~20 fixes** (3c6d9733 drop stale completions, 5f7e332c, 300de3f8, 05cbc564, b5baa7d4, 619f05bc, 7a6b12cc→c81a63b2→b39e59e2→5c5e1ff6→a2e5568c→f3ff4a1c activation-catalog sub-chain).
6. **2026-07-07..08, PRs #168/#169/#170**: 25 commits in ~26h on branch `codex/process-tools-list-surface` (PR #170 alone: 21 fixes + 1 refactor + 3 tests, 07-07 18:57 → 07-08 20:58).

### The 8 most recent chain-A fixes inspected (git show)
| SHA | time (JST) | what the diff does | type |
|---|---|---|---|
| b43b1ad6 | 07-08 16:09 | adds `refreshProcessRouteActivationCatalogWaitAfterEmptyCatalog` — **re-arms the activation-catalog timeout** after an empty catalog | 局所guard (timeout re-arm) |
| 51d0070b | 07-08 16:40 | `scheduledProcessToolsCatalogRetries`: cancel+replace retry when its **tagged generation** differs from current broker generation | 局所guard (generation tag on retry) |
| 382bf4be | 07-08 17:35 | re-checks broker generation **again on the `.noChange` path** of `applyToolCatalogSurfaceMutation`; adds test hook `processToolCatalogSurfaceUpdatePassedInitialGenerationCheck` | 局所guard (double generation check) |
| 81e361e1 | 07-08 17:45 | **reverts b43b1ad6's re-arm 96 minutes later**: renames to `finishCatalogRequestWithoutCatalog`, deletes the `scheduleProcessRouteActivationCatalogTimeout` reschedule, keeps the timeout | fix-of-fix (guard oscillation) |
| 258ace47 | 07-08 17:57 | adds `process_not_exposed` stale-catalog rejection guard + re-filters routes by `processToolCatalogExposedProcessIDs()` inside the background completion task + new `syncCurrentProcessToolsCatalogSurfaceIfComplete` | 局所guard (exposure filter, 2 more call sites) |
| 2c677e05 | 07-08 19:56 | `refactor(proxy): consolidate process route surface state` — creates `ProcessRouteStore` (526 lines), renames ActivationTracker→`ProcessRouteReadinessStore`, Registry→`ProcessToolSurfaceStore`; ships 377-line `Docs/process-route-rearchitecture.md` | **構造修正** |
| 9f726a6b | 07-08 20:42 | **deletes the `exposureEpoch` lease field that 2c677e05 introduced hours earlier** (removes `invalidateExposure()`, drops `exposureEpoch` from `AvailableToolsCatalogRoute` and from `processToolsCatalogLoadLeaseIsCurrent`), replaces with live `ProcessRouteStore.containsExposedRoute(id:policy:…)` recheck | guard 撤去+再配置 (fix-of-refactor) |
| 6b454a86 | 07-08 20:58 | `ProcessRouteStore.markUnavailable` now returns `MarkUnavailableResult.didChangeExposure`; caller resyncs surface on exposure loss | 局所repair (exposure-change signal at symptom) |

Also inspected (stat-level): 4abbc84e 07-08 14:25 `guard process catalog retries by generation` (+372/-35 across 6 files — generation threading), 51cfe2f9 07-08 00:49 `guard process catalog surface generation` (adds `onlyIfGeneration` to `CanonicalBrokerState`), **f9cb2000 07-08 14:48 `roll back stale process catalog cleanup` — an explicit rollback of a prior fix's cleanup**, 04ac3cea 07-08 01:03 `drop stale empty process catalogs` (+7 source lines, pure guard).

## 3. Chain B — window-owner routing (chronological)

1. **2026-03-12** 2cd8cdcf `fall back when window lookup cannot confirm workspace`.
2. **2026-06-24** b0287004 `route window owners by Xcode process` → same-day wave: c719dcf7/fa975d2e (aggregate window lookups ×2), ea9395c4, 44baebb6, c2d7e8e0, cd03730d, 0304c2f8 (mixed/rejected owner-batch guards ×4), e87d6794 (infer unambiguous owner), aae8d64b (avoid stale window routes), 3eec1f09, b9228b53, ad492e70.
3. **2026-06-29** cb51b98f (route XcodeListWindows by catalog surface), fedf66b7 (ignore stale catalogs for window fanout), c1d37070 (clear skipped window owners — 4-line guard), 7af35941.
4. **2026-07-09, PR #172** (`codex/xcode-window-owner-routing`, merged a1c6218e): **7 fix commits in 3.5 hours**, all labeled `fix`:

| SHA | time | what the diff does | type |
|---|---|---|---|
| e9b6eed5 | 10:14 | introduces `WindowOwnerIndex` (new 151-line type) + proxy tabIdentifier hashing + result rewriting; `RuntimeCoordinator+XcodeProcessRouting.swift` +453 lines | 構造修正 intent, but state stays a `windowOwnerIndex.withLockedValue` box inside RuntimeCoordinator |
| 5ca620dd | 10:37 | threads `eligibleProcessIDs` filter through every resolution path; adds **local `activeAvailableOwnerProcessIDs()`** recomputing exposure from `xcodeProcessRoutes` minus `unavailableXcodeProcessIDs()` — a second source of truth for exposure | 局所guard |
| 900f54c0 | 10:50 | rewrites owner resolution precedence (nested `proxyTabResolution` func; proxy tab beats workspace) | 局所 rework |
| 39d62ce5 | 11:03 | adds `workspacePath` into the SHA256 input of `proxyTabIdentifier` (identity token was ambiguous) | 局所 (identity contract patch) |
| 8fad7133 | 11:21 | on conflict, refresh window owners **then re-resolve** (retry-then-recheck); counts raw identities not pid-sets | 局所guard (refresh+retry) |
| 96d1378b | 11:36 | adds the `rewriteXcodeListWindowsResultForClients` call to the **pinned-upstream path too** — the "results must be rewritten" invariant was enforced per call site and one site was missed | 局所guard (copied invariant, 2nd call site) |
| 436d7f94 | 11:48 | **deletes 5ca620dd's `activeAvailableOwnerProcessIDs()` (added 71 min earlier)** and delegates to `processRouteExposure(policy: .ownerRouting)`; also fixes empty-string `tabIdentifier` handling | guard 撤去→owner へ移動 |

## 4. 構造修正型 vs 局所guard型 ratio

Of the 16 fix commits diff-inspected across both chains: **2 clear 構造修正 (2c677e05, e9b6eed5) : 11 局所guard/局所patch : 3 guard-corrections that undo or relocate a guard added the same day (81e361e1←b43b1ad6, 9f726a6b←2c677e05, 436d7f94←5ca620dd) ≈ 12.5% structural.** The three same-day reversals are the strongest signal: guards are being added faster than their invariants are understood.

### Where the guards live at HEAD (file:line)
- **Quadruplicated stale-catalog guard**: `"Dropping stale process tools/list catalog"` at `RuntimeCoordinator+ControlPlane.swift:523, 627, 689, 711` — same invariant ("this catalog result is still current") enforced 4 times inside one file, from 4 different angles (route identity, readiness attempt, exposure policy, broker generation).
- Lease guards: `processToolsCatalogRouteLeaseIsCurrent` ControlPlane.swift:673-700; `processToolsCatalogLoadLeaseIsCurrent` :702-728 (called at :265, :276, :533).
- Generation checks: `toolCatalogBrokerGenerationIsCurrent` `RuntimeCoordinator.swift:998` (call sites :957, :961, :1010, :1015, :1022); `onlyIfGeneration` threading at ControlPlane.swift:306, 565, 640, 833.
- **`ProcessRouteStore.swift` has 10 separate `state.generation &+= 1` sites** (:127, :179, :220, :255, :316, :365, :393, :418, :439, :487) plus `epoch` at :34/:509 — the counter is centralized but bumped ad hoc per mutation.
- Attempt counters: `ProcessRouteReadinessStore.swift:9-50` (phase enum carries `attempt: Int`), `finishCatalogRequestWithoutCatalog` :428; reconciliation-loop generation `RuntimeCoordinator+XcodeProcessReconciliation.swift:102`.
- Cooldown constants/logic: `RuntimeCoordinator+XcodeProcessRouting.swift:268, 280, 288-321`.
- Owner-eligibility filter threading: `ownerRoutingEligibleProcessIDs` XcodeProcessRouting.swift:1388, threaded to :1276, :1293, :1321, :1330, :1370, :1397, :1411 and into `WindowOwnerIndex.swift:80/:85, :104/:108` — the same "only eligible pids may resolve" invariant passed as a parameter to 8+ sites instead of owned by the index.
- Retry scheduling is split across three owners at HEAD: `scheduleMissingProcessToolsCatalogRetry` ControlPlane.swift:419 (+ call sites :575, :593, :661), `cancelScheduledProcessToolsCatalogRetry` RuntimeCoordinator.swift:1040 (called from Reconciliation.swift:251 and XcodeProcessRouting.swift:304), and `pendingCatalogRefreshProcessIDs` in `ProcessRouteReadinessStore.swift:70-99`.

## 5. Same-pattern-multiple-commits (owner-absence signals)

- **'stale' guard fixes: 15 commits** across ≥6 distinct call-site families: catalogs (96b3335e, 04ac3cea, 3c6d9733, 258ace47, 382bf4be, fedf66b7), retries (51d0070b), cleanup rollback (f9cb2000), window routes/owners (aae8d64b, 436d7f94), initialize callbacks/timeouts (3fcb0808, 3a3ff4a2), documentation state (435fe2b8, 623b467e), HTTP sends (520fa318).
- **Generation-guard commits: 3** explicitly (2de161d5 refactor introduced broker generation on 06-13; 4abbc84e and 51cfe2f9 extended it to retries and surface on 07-08) — the mechanism keeps acquiring new consumers per incident instead of gating all mutations at one boundary.
- **Timeout/retry re-arm oscillation: ~40 'timeout' + 27 'retry/rearm' subjects**; concrete flip-flops: d814a29a 07-03 "stop process tools retry after timeout" vs 7a8d3714 07-03 "retry process catalog fallback timeouts" (same day, opposite directions); b43b1ad6→81e361e1 (07-08, re-arm then un-re-arm); d01a4424→51a9044c 07-03 (keep timeout armed → only rearm while pending); 2c8be76f 07-07 "retry activation after timeout".
- **Duplicate-subject commits on one day**: 3690dcf1 and 620630fe (06-24) both "avoid caching partial process catalogs".
- **The repo's own (deleted) diagnosis**: `Docs/process-route-rearchitecture.md` created in 2c677e05, deleted next day in 5397ebec (07-09 03:28). It states verbatim: "RuntimeCoordinator extension files are a false decomposition: they share one state space", "`ProcessToolSurfaceStore` mutation and canonical generation checks happen at separate call sites, which creates rollback patches", "Canonical `tools/list` is used as a fallback source for owner-bound routing, creating a second source of truth". Hours after that doc landed, 9f726a6b/6b454a86 patched the new stores, and the next morning PR #172 grew `RuntimeCoordinator+XcodeProcessRouting.swift` to 1,522 lines (doc's baseline measurement: 1,176).

## 6. Confirmed facts vs speculation

**Confirmed** (all of the above tables, SHAs, line numbers, doc quotes). **Speculation, marked**: (i) area bucket counts have keyword-classifier noise, ±5% per bucket; (ii) that PR #172's fixes were reactive to live testing rather than review feedback is inferred from the 10-20 minute inter-commit cadence, not from PR metadata; (iii) whether `WindowOwnerIndex` state should live inside `ProcessRouteStore` exposure rather than a separate locked box is a design hypothesis, not a measured defect.

# CANDIDATE FINDINGS

## [high] 81% of all 374 fixes land in proxy runtime (process catalog + window-owner routing); RuntimeCoordinator files absorb 73/56/45 fix commits each (proxy-session)
EVIDENCE: 686 non-merge commits, ~374 fix-type; area (a) 269 fixes + area (b) 33 fixes = 302/374. git log --follow fix counts: RuntimeCoordinator.swift 73, RuntimeCoordinator+ControlPlane.swift 56, RuntimeCoordinator+XcodeProcessRouting.swift 45. Files are 1,679/1,475/1,522 lines at HEAD. Deleted design doc (2c677e05:Docs/process-route-rearchitecture.md) itself calls the extension split 'a false decomposition ... one state space'.
DIRECTION: Hypothesis: the fix distribution is a structure problem, not a bug-count problem — the shared RuntimeCoordinator state space is the recurrence engine; audit should target its owner map rather than any individual symptom.

## [high] Catalog-staleness invariant has no single owner: identical 'Dropping stale process tools/list catalog' guard exists at 4 sites, enforced via 4 different mechanisms (proxy-session)
EVIDENCE: RuntimeCoordinator+ControlPlane.swift:523, 627, 689, 711 (route-identity check, readiness-attempt check, exposure-policy check, broker-generation check). Mechanisms accreted per incident: broker generation (2de161d5), retry generation tag (4abbc84e, 51d0070b), surface onlyIfGeneration (51cfe2f9, 382bf4be), exposure filter (258ace47), lease recheck (9f726a6b). ProcessRouteStore.swift bumps state.generation at 10 separate sites (:127,:179,:220,:255,:316,:365,:393,:418,:439,:487).
DIRECTION: Hypothesis: 'is this catalog result still admissible' should be one owner-managed admission decision (exactly what the deleted rearchitecture doc proposed as 'a single owner-managed transaction'); the 4 guards are the same invariant re-derived per call site.

## [high] Same-day guard oscillation: 3 of 16 inspected fixes reverse or relocate a guard added hours earlier in the same PR (proxy-session)
EVIDENCE: b43b1ad6 (07-08 16:09, re-arm activation timeout) reverted by 81e361e1 (17:45); 2c677e05's exposureEpoch lease (19:56) deleted by 9f726a6b (20:42); 5ca620dd's activeAvailableOwnerProcessIDs (07-09 10:37) deleted by 436d7f94 (11:48). Plus explicit rollback commit f9cb2000 'roll back stale process catalog cleanup' and same-day opposite-direction pair d814a29a vs 7a8d3714 (07-03). 15 commits total carry 'stale' in the subject across 6+ call-site families.
DIRECTION: Hypothesis: guards are written before the terminality/ownership semantics of catalog acquisition are pinned down; the audit should extract the intended lifecycle contract (attach → catalog → surface → retire) and check which transitions currently have two writers.

## [high] Window-owner routing (PR #172): 7 fixes in 3.5 hours; owner-eligibility invariant threaded as a parameter to 8+ sites instead of owned by WindowOwnerIndex/exposure (window-owner-routing)
EVIDENCE: PR #172 chain e9b6eed5→436d7f94 all 2026-07-09 10:14-11:48. eligibleProcessIDs threading at RuntimeCoordinator+XcodeProcessRouting.swift:1276,1293,1321,1330,1370,1388,1397,1411 and WindowOwnerIndex.swift:80/85,104/108. 96d1378b shows the per-call-site 'rewrite results for clients' invariant missed the pinned-upstream path (RuntimeCoordinator.swift:1442-1449). WindowOwnerIndex state is a locked box inside RuntimeCoordinator, while eligibility truth lives in ProcessRouteStore exposure policy (436d7f94 repointed it there).
DIRECTION: Hypothesis: owner resolution (identity index) and owner eligibility (exposure) are two halves of one routing decision currently split across RuntimeCoordinator, WindowOwnerIndex, and ProcessRouteStore; the June-24 wave (12 owner-batch fixes in one day) is the same absence recurring.

## [medium] Feature-then-fix-wave pattern repeats on every routing feature: 3 features each followed by ~20 same/next-day fixes (proxy-session)
EVIDENCE: 3a9f4ae5 (06-23 route tools by process catalog) → 74 commits on 06-24; 6e07823e (07-02 dynamic reconciliation) → 37 commits same day; PR #170 (07-07/08) 21 fixes+1 refactor in 26h; PR #172 (07-09) 7 fixes in 3.5h. Merge-commit titles confirm the branch-per-wave structure (PRs #159-#172 in 8 days).
DIRECTION: Hypothesis: the integration surface (RuntimeCoordinator) lacks a contract that new routing features can be validated against pre-merge; fix waves are the contract being discovered in production.

## [medium] The consolidation refactor 2c677e05 was structurally correct in diagnosis but immediately incomplete: its own artifacts were patched within hours and its design doc deleted next morning (proxy-session)
EVIDENCE: 2c677e05 (07-08 19:56) created ProcessRouteStore/ProcessToolSurfaceStore/ProcessRouteReadinessStore + 377-line Docs/process-route-rearchitecture.md; 9f726a6b (20:42) and 6b454a86 (20:58) patched them; 5397ebec (07-09 03:28) deleted the doc. Doc findings 3 and 5 ('mutation and generation checks at separate call sites ... creates rollback patches'; 'second source of truth') describe defects still present at HEAD (ControlPlane.swift 4x stale guard; retry state split across ControlPlane.swift:419/RuntimeCoordinator.swift:1040/ProcessRouteReadinessStore.swift:70-99).
DIRECTION: Hypothesis: the rearchitecture stopped at store extraction without moving the decision logic; RuntimeCoordinator still composes admission/retry/surface decisions from store queries at each call site, so the stores are data holders, not owners.

## [low] Non-proxy areas are comparatively healthy: HTTP gateway 25 fixes (mostly one 06-16 modernization wave), stdio 6, SDK 18, CLI 15 (http-gateway)
EVIDENCE: Keyword-classified counts (method caveat noted in report). HTTP gateway fixes cluster around 20ea7ab3 'feat!: modernize streamable HTTP transport' (06-16, 8 same-day follow-ups: c00f1625, adeea3ad, 65bf4a48, 50f923dc, d5016b5b...) and the 06-25 client-transport wave in XcodeMCPKit (3a0828b1, 3bae88f3, 1a67984b, 520fa318, 39d2dcbb, de774378); both waves terminated rather than recurring.
DIRECTION: Hypothesis: these areas show the normal feature-stabilize-stop pattern, confirming the recurrence problem is specific to the proxy runtime's shared-state routing core, not to the team's process overall.
