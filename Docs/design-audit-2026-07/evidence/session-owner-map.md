# Fix-churn hotspot 構造監査: Session/** + RuntimeCore/** owner map

全て read-only で確認。引用は file:line(リポジトリルート相対、`Sources/XcodeMCPProxyKit/` 配下は `SXP/` と略記)。**確認済み事実**と**推測(hypothesis)**は明示的に分離。

## 0. 全体構造(確認済み)

`RuntimeCoordinator` は actor ではなく `final class ... Sendable`(SXP/Internal/Session/Runtime/RuntimeCoordinator.swift:361)で、**13個以上の独立ロック付きストア**を保持する composition-root 兼 god object:
- sessionRegistry, initializeManager, canonicalBrokerState, controlPlaneDebugMirror, processToolSurfaceStore, processToolSurfaceMutationLock(RuntimeCoordinator.swift:383-409)
- upstreamHealthManager, upstreamSlotScheduler, upstreamReadinessGate/Coordinator, controlPlaneCoordinator(actor)(411-420)
- processRouteStore, xcodeProcessReconcileScheduleState, xcodeProcessEventMonitor, windowOwnerIndex(NIOLockedValueBox<WindowOwnerIndex>), availableToolsCatalogRefreshKeys, processRouteReadinessStore, upstreamsBox, leaseManager, upstreamRouter, debugRecorder(396-434)

ストア間の invariant はロックの外側で **メソッド呼び出し順序**によって維持される(explicit protocol なし)。scheduler→runtime の依存は `WeakRuntimeCoordinatorBox` 経由の closure で逆流(RuntimeCoordinator.swift:623-667)。

churn の実測: `RuntimeCoordinator+ControlPlane.swift` 41 commits、`+XcodeProcessRouting.swift` 28、`+XcodeProcessReconciliation.swift` 17。ストア3種(ProcessRouteStore/ProcessToolSurfaceStore/ProcessRouteReadinessStore)は commit 2c677e05 "consolidate process route surface state" で最近抽出されたばかり(各1-3 commits)で、**状態は箱に移ったが遷移ロジック(=invariant の owner)は coordinator extension に残った**。

## 1. ドメイン別 owner map

### (A) Upstream process pool + leases(RuntimeCore/Broker, Bridge)

- **Source of truth**: `upstreamsBox: NIOLockedValueBox<[any UpstreamSlotControlling]>`(RuntimeCoordinator.swift:401-404)。スロット identity は **配列 Int index**。append-only(Reconciliation.swift:208-211)+ in-place 置換(RouteActivation.swift:391-443)。
- **Lease**: `LeaseManager`(SXP/Internal/RuntimeCore/Broker/LeaseManager.swift:5-127)。UUID keyed state machine(queued/active/completed/timedOut/failed/abandoned)+ `activeLeaseIDsByUpstream: [Int: Set<ID>]`。
- **Scheduling**: `UpstreamSlotScheduler`(Broker/UpstreamSlotScheduler.swift)。usability 判定は init 時に注入された closure が weak box 経由で runtime の `routableProcessBoundUpstreamIndices()` を呼ぶ(RuntimeCoordinator.swift:636-657)。
- **Health/init 状態**: `UpstreamHealthManager.UpstreamState`(Bridge/UpstreamHealthManager.swift:87-128): initPhase(`.initializing(upstreamID: Int64?)`)、healthState、healthProbeGeneration。
- **Identity**: 3系統が並存 — (1) Int upstreamIndex(slot)、(2) Int64 upstreamID(init/request 試行ごと、UpstreamRouter が採番)、(3) `ProcessRouteID(processID, instanceGeneration)`。`UpstreamTopologySnapshot` には型付き `UpstreamSlotID`/`XcodeProcessID`(BridgeRuntime/UpstreamTopologySnapshot.swift:4-30)があるが **Session 層は raw Int/pid_t を使用**し、型付き ID は Session 層に到達していない。
- **Lifecycle owner**: slot の start/stop は coordinator extension(retireProcessBoundUpstream Reconciliation.swift:293-337, replaceProcessBoundUpstreamSlot RouteActivation.swift:391-443)。イベント購読は `observeUpstreamEvents`(RuntimeCoordinator.swift:750-778)。
- **Fan-out**: upstream event → `handleUpstreamExit`(UpstreamRouting.swift:261-351)が initializeManager / healthManager / upstreamRouter / leaseManager / processRouteStore / brokerState の6ストアを順に触る。
- **暗黙の同期プロトコル(確認)**: 新規スロット追加時に `upstreamRouter.appendUpstreams` / `upstreamHealthManager.appendUpstreams` / `debugRecorder.appendUpstreams` を**手動で3回**呼ぶ(Reconciliation.swift:224-226)。呼び忘れれば index 不整合。

### (B) Process catalog + activation + exposure(Session/Runtime)

- **Route membership/order の truth**: `ProcessRouteStore`(ProcessRouteStore.swift:109-115): recordsByKey + order + **単一 generation カウンタ**。identity は `InstanceKey(pid, appPath, developerDir, mcpbridgePath, xcodeVersion)`(56-70)。route インスタンス identity は `ProcessRouteID(pid, instanceGeneration)`(store generation から採番、222-229)。
- **Cooldown 状態も同居**: route/catalog 2スコープの unavailableUntil(72-107)。**読み取り操作(`exposure`, `unavailableProcessIDs`)が期限切れ prune で generation を進める副作用を持つ**(315-318, 486-489)。
- **Activation 状態機械**: `ProcessRouteReadinessStore`(ProcessRouteReadinessStore.swift:69-72)は**3つの独立ロック**を持つ: records(phase: pending/attaching/initialized/cataloged/abandoned + attempt + retryTimeout + catalogTimeout + catalogRPCHandles)、pendingCatalogRefreshProcessIDs(Set)、scheduledCatalogRetries(generation タグ付き)。遷移の駆動は store ではなく coordinator extension(RouteActivation.swift 全体、444行)。
- **Per-process catalog**: `ProcessToolSurfaceStore`(ProcessToolSurfaceStore.swift:72-75): catalogsByProcessID + processIDByUpstreamIndex(**upstream→pid マッピングの複製**。truth は ProcessRouteStore の route.upstreamIndices)。
- **Exposure は毎回再計算される派生値**: `exposure(policy:upstreamUsability:)`(ProcessRouteStore.swift:462-515)。4 policy(toolsCatalog/ownerRouting/windowDiscovery/initialization)で usability の解釈が分岐(469-477)。usability snapshot は呼び出し側が healthManager から都度合成(XcodeProcessRouting.swift:410-448)。
- **External I/O**: `LiveXcodeTargetDiscovery`(NSWorkspace + プロセス列挙、LiveXcodeTargetDiscovery.swift:8-40)、`XcodeProcessEventMonitor`(NSWorkspace 通知 + DispatchSourceProcess exit、XcodeProcessEventMonitor.swift:18-93)。
- **Lifecycle owner**: 再スキャンは (1) workspace 通知、(2) exit source、(3) 2s/30s 周期ループ(Reconciliation.swift:70-93、pending catalog refresh 有無で間隔切替)、(4) upstream_exit イベント(RuntimeCoordinator.swift:771-773)の4系統が `triggerXcodeProcessReconcile` に合流。
- **Fan-out**: reconcile 差分 → retire/add で 7+ ストアへ手続き的伝播(Reconciliation.swift:176-201, 244-291)。tools/list_changed 通知の発火点は2箇所(RuntimeCoordinator.swift:1035, Reconciliation.swift:198)。

### (C) Canonical tools catalog + initialize cache(Session/ControlPlane)

- **Source of truth**: `CanonicalBrokerState`(CanonicalBrokerState.swift:51-64): initializeResult/toolsCatalogRaw/sourceUpstream + **単一 generation**(clear/reset で bump、コメント 57-61)。InitializeManager は「in-flight/pending のみ保持、キャッシュは broker に一本化」と明記(InitializeManager.swift:124-127)— ここは owner 一本化が成功している箇所。
- **Load dedup 層**: `ControlPlaneCoordinator`(actor)が toolsCatalogLoad/prewarm/windowLoads + waiters + startGeneration を保持(ControlPlaneCoordinator.swift:63-99)。完了時に `brokerState.generation() == load.startGeneration` でなければ waiter へ CancellationError(555-585, 587-610)。
- **process-routing 時のバイパス**: `loadCanonicalToolsCatalog` は processRoutingEnabled なら ControlPlaneCoordinator の下で更に `loadAvailableToolsCatalogSurfaceAcrossProcessRoutes` に分岐し、ProcessToolSurfaceStore と brokerState を直接読み書き(RuntimeCoordinator+ControlPlane.swift:83-98, 100-195)。**カタログは3層キャッシュ**(per-process store → broker canonical → coordinator load dedup)+ 読み出し時 documentation overlay(RuntimeCoordinator.swift:1529-1566)。
- **store↔broker の整合**: `processToolSurfaceMutationLock` + broker generation の**反復チェック**(mutation前に2回 + 各canonical action内でonlyIfGeneration、RuntimeCoordinator.swift:952-974, 998-1038)。2回目のreadはconcurrent mutationを観測し得るためproduction-deadではないが、`ControlPlaneCoordinator`がfunnel lock外からbrokerを変更でき、validation・surface mutation・canonical projectionは不可分でない。SurfaceUpdate(canonicalAction)はstoreのlock内で計算しbrokerへ別lock下で適用するため、atomicityを保証しない。

### (D) Window/owner routing(Session/Runtime + XcodeSupport)

- **Source of truth**: `windowOwnerIndex: NIOLockedValueBox<WindowOwnerIndex>`(RuntimeCoordinator.swift:432)。identity は `Identity(pid, rawTabIdentifier, workspacePath)` + SHA256 由来 `proxyTabIdentifier`(WindowOwnerIndex.swift:5-35)。
- **External I/O**: XcodeListWindows tools/call(control-plane pinned RPC)のみが populate 経路(XcodeProcessRouting.swift:52-160 fan-out 版、RuntimeCoordinator.swift:1443-1444 pinned 版)。
- **比較ロジックの所在**: owner 解決は `cachedOwnerResolution`(XcodeProcessRouting.swift:1272-1386、115行の分岐)+ `tabConflictMessage`(1392-1422)+ `WindowOwnerIndex.owner(forWorkspacePath:eligibleProcessIDs:)`(WindowOwnerIndex.swift:78-96)に分散。eligibility(= exposure .ownerRouting)は**毎回の lookup で index の外から注入**(1388-1390)。
- **Lifecycle owner**: 削除は5箇所に分散 — windows fan-out で skip された process(XcodeProcessRouting.swift:80-82)、route unavailable(312)、route retire(Reconciliation.swift:252)、clearUpstreamState で代替 upstream なし(Initialization.swift:751)、debugReset(RuntimeCoordinator.swift:850)。
- **隠れた結合(確認)**: owner index が変化すると `invalidateControlPlane(clearToolsCatalog: true)` を発火(XcodeProcessRouting.swift:349-355, 366-372, 821-827, 849-855)。つまり **broker generation は (1) initialize キャッシュ有効性 (2) カタログ有効性 (3) owner index 変化通知 の3役を1カウンタで兼務**。window 更新のたびに in-flight カタログロードが全部 stale 化する。

## 2. Guard inventory(invariant 別、owner-absence の証拠)

### G1: 「非同期カタログロードの完了は、開始後に世界が変わっていたら書き戻してはならない」
関連check/cleanupは**12箇所以上**に分散する。ただし全てが同一checkのcopyではない。generation / route lease / activation attemptの3 clockには部分ownerがあり、exposureはderived publish filter。欠けるのはcomposed admissionとatomic commitのowner:
1. ControlPlaneCoordinator.completeToolsCatalogLoad: startGeneration 比較 + onlyIfGeneration 書込(ControlPlaneCoordinator.swift:560-584)
2. completeWindowLoad: 同型(587-610)
3. cancelInvalidatedLoads / cancelLoadsStartedBeforeGeneration(ControlPlaneCoordinator+Utilities.swift:8-40)
4. applyToolCatalogSurfaceMutation: generation を**2回**チェック(test hook を挟む race window 対策が明示、RuntimeCoordinator.swift:956-963)+ 各 action で onlyIfGeneration(1005-1038)
5. processToolsCatalogLoadLeaseIsCurrent: brokerGeneration 一致 + route exposure 再確認(+ControlPlane.swift:702-728)。失敗クリーンアップ経路では **hook 前後で2回**呼ぶ(265-283)
6. recordAvailableToolsCatalog: routeID+target 同一性(519-531)→ lease current(533-539)→ 空カタログ判定(546)→ activation attempt 一致 or isCataloged(608-637)→ onlyIfGeneration mutation(639-651)の**5段直列 staleness チェック**(506-671)
7. syncCurrentProcessToolsCatalogSurfaceIfComplete: generation 比較 + onlyIfGeneration(818-835)
8. scheduleAvailableToolsCatalogCompletion: task 開始時に brokerGeneration と routeID 露出を再フィルタ(768-776)
9. scheduleMissingProcessToolsCatalogRetryのtimer callback: **6条件guard**(scheduled entry generation / captured-vs-live broker generation / routingEnabled / route存在 / pending / catalog nil、442-465)
10. ProcessRouteReadinessStore の generation タグ付き retry take/store 4メソッド(ProcessRouteReadinessStore.swift:102-173)
11. markCatalogedのexpectedAttempt検査(250-294)— activation attemptという**第3のclock**
12. 空カタログ後の RPC handle 一括 cancel(finishCatalogRequestWithoutCatalog、428-452)

fix commit群(258ace47,382bf4be,4abbc84e,51cfe2f9,04ac3cea,81e361e1,f9cb2000,eba14516等)はこのinventoryの各境界へ追加された。問題は3 clock自体の存在ではなく、それらを合成したadmissionとvalidation・surface mutation・canonical projectionのatomicityがcall site任せなこと。

### G2: 「init 試行の結果はその試行にのみ適用」(identity = upstreamIndex + upstreamID or attempt)
- clearUpstreamState(expectedUpstreamID:)(Initialization.swift:717-754)/ markUpstreamInitialized(expectedUpstreamID:)(757-770)
- sendInitializedNotificationIfNeeded: initializeAttemptMatches を**3経路**で確認 + markInitializedNotificationSent guard(553-605)
- InitializeManager: primaryInitializeMatches(362-369)、beginPrimaryInitializeSend の phase 等値(259-274)、cancelledPrimaryInitializeAttempts リスト(直近16件保持、604-620)
- ProcessRouteReadinessStore: handleTimeout / handleCatalogTimeout / storeCatalogTimeout / storeCatalogRPCHandle が (pid, upstreamIndex, attempt) の**三つ組一致**を個別に検査(308-426)。不一致なら渡された timeout/handle をその場で cancel(400-402, 423-425)
- UpstreamHealthManager: healthProbeGeneration 等値(UpstreamHealthManager.swift:598-604)

### G3: 「route/owner は usable/exposed であるときのみ routing に使う」
`unavailableXcodeProcessIDs()` / exposure 参照が**7消費点**に散在: startProcessRouteActivation(RouteActivation.swift:8)、retryPendingProcessRouteReadiness(Reconciliation.swift:385-401 — pending 集合を毎回フィルタし直して置換)、documentationCandidateProcessIDs(XcodeProcessRouting.swift:233-244)、catalogEligibleConfiguredProcessIDs(246-251)、inferredUnambiguousOwnerProcessID(660-663)、preferredAvailableRoute(764-785)、RuntimeXcodeTargetDiscovery.swift:23-26。owner lookup 側は ownerRoutingEligibleProcessIDs(1388-1390)を WindowOwnerIndex の全 query に手渡し。

### G4: 「canonical catalog は source upstream を失ったら生き残れない」
- toolsCatalogLostItsSource(UpstreamRouting.swift:253-259、doc comment 付き)
- clearUpstreamState の surface removal 分岐(replacement 有無で2経路、Initialization.swift:733-752)
- handleInitializedNotificationSendOverload(608-628)、retireProcessBoundRoute(Reconciliation.swift:258-277)、markXcodeProcessRouteUnavailable の didChangeExposure 分岐(XcodeProcessRouting.swift:305-311)、handleUpstreamExit(UpstreamRouting.swift:314-324)
- Review checklist にも「Canonical initialize/tools cache cannot survive upstream exit/quarantine/eager retry windows」と明文化(Docs/maintainer-architecture.md:134)— **チェックリスト化されていること自体が owner 不在の症状**(型/境界で保証されず人間レビューで守っている)。

### G5: 「window owner は生きている exposed process のみ反映」
削除5箇所(§1-D 参照)+ 記録時の remove-then-record(XcodeProcessRouting.swift:811-820, 841-848)。

## 3. fallback候補の検証後inventory

1. **hint-less owner inference(WEAKENED)**: `inferredUnambiguousOwnerProcessID`(XcodeProcessRouting.swift:652-684)はowner hintが無いrequestだけのtest-pinned policy。hint付きrequestは推測へ到達せずhard rejectするため、window indexを置換する第二truthではない。残余riskは2台目Xcodeのcatalog未ロード窓でfalse-unambiguousになり得る点。
2. **catalog ベース routing**: `catalogToolRoutingDecision`(711-762)+ `preferredAvailableRoute` の version 降順ソート(771-783)。同じソートが ProcessToolSurfaceStore.catalogSort(514-526)にも**重複実装**。
3. **旧surface返却主張(REFUTED)**: generic catchのcurrentSurface返却(+ControlPlane.swift:183-194)は到達不能。cancel時の25ms poll(168-182,197-216)は並行winnerのfreshかつcompleteなsurfaceだけを待つcoalescingで、期限時はrethrowする。
4. **失敗task中のsurface再出現(REFUTED as stale fallback)**: 284-304は同generation/current leaseの並行loaderが記録したfresh catalogを保持するtest-pinned semanticsで、stale dataをsuccessへ偽装しない。
5. **空カタログ受信時**: 旧カタログを落として surface を返しつつ 250ms retry を予約(546-597)。
6. **primary index fallback(WEAKENED)**: handleUpstreamExitの`globalInit.primaryInitUpstreamIndex ?? initializeSourceUpstream() ?? 0`(UpstreamRouting.swift:326-328)。`?? 0`はcold状態でrestart strategy選択にだけ使われ、routing disabled時の規約default。ただしcurrent-primary選択が3箇所へ重複するsmellは残る。
7. **proxyTabIdentifier合成(REFUTED)**: WindowOwnerIndex.swift:121-136の両branchは同じ純決定関数を返す。lookup armは冗長だが第二truthや捏造ではない。
8. **weak box null 時の routable 全開放**: runtime が解放済みなら全 active route を routable とみなす closure fallback(RuntimeCoordinator.swift:623-628)。
9. **cachedToolsListResult(forUpstreamIndex:) の canonical fallback**(RuntimeCoordinator.swift:924-927)。
10. **legacy record()(production REFUTED / hygiene only)**: ProcessToolSurfaceStore.swift:87-95はinstanceGeneration:0を作るがproduction callerは0で、test seeding専用。production型にtest-support APIが残る衛生課題。

## 4. コピー/派生の数と整合手段

**Tool surface**: (1) upstream 実体 → (2) ProcessToolSurfaceStore per-process raw+派生4マップ → (3) CanonicalBrokerState canonical union → (4) ControlPlaneCoordinator load/waiter 状態 → (5) 読み出し時 documentation overlay → (6) DebugMirror。整合は「2ロック + non-atomic generation re-check + 呼び出し順序」(explicit protocol なし)。
**Process membership**: ProcessRouteStore(truth)に対し、ProcessToolSurfaceStore.processIDByUpstreamIndex、ProcessRouteReadinessStore 3マップ、XcodeProcessEventMonitor.exitSources、upstreamHealthManager/upstreamRouter/leaseManager/debugRecorder の per-index 配列が**同期対象8系統**。追加時は3連 appendUpstreams の手動呼び出し(Reconciliation.swift:224-226)。
**Owner mapping**: WindowOwnerIndex 1系統(良)だが、eligibility は毎回外部合成、conflict 意味論は3関数に分散、さらに §3-1 の catalog 由来推測が並走。
**Windows message 解析**: XcodeProcessRouting.xcodeListWindowsMessage(1488-1520)と XcodeSupport/XcodeWindowQueryService.extractToolMessage(23-50)が**同一ロジックの重複実装**。

**未使用の照合機構(確認)**: `ProcessRouteStore.ExposureSnapshot.epoch` と `currentEpoch()` は**production コードでは未消費**(消費者は Tests/ProxyRuntimeCoordinatorTests/RuntimeCoordinatorTests.swift:1933,7107 のみ)。exposure の一貫性照合用に見える機構が実際には使われていない。

**Docs との乖離(確認)**: Docs/maintainer-architecture.md:18-25 の Ownership Boundaries は process-bound routing / exposure / window owner / activation を一切記述していない。fix-churn の主戦場が owner map 上に存在しない。

## 5. Owner map 表(現状 / 問題 / あるべき owner hypothesis)

| 状態 | 現状の owner | 問題(確認済み) | あるべき owner(hypothesis) |
|---|---|---|---|
| route membership/order | ProcessRouteStore | 読み取りに generation bump 副作用; cooldown が同居 | 同 store。ただし exposure 計算ごと移管し read を純粋化 |
| cooldown/unavailable | ProcessRouteStore(2スコープ) | mark/prune が coordinator から都度駆動 | exposure owner に統合 |
| exposure(4 policy) | なし(毎回派生: store+healthManager+coordinator 合成) | G3 の7消費点が各自合成; epoch 未消費 | 単一 ExposureAuthority(route×usability×cooldown を1箇所で結合し epoch 発行) |
| per-process catalog | ProcessToolSurfaceStore | upstream→pid複製; production型にtest-only generation-0 seeding API | 同store。production recordはtransaction proof必須、test seedingはtest supportへ移す |
| canonical catalog + initialize cache | CanonicalBrokerState | generation が3役兼務(init/catalog/owner変化) | 役割別 epoch or カタログ transaction 型 |
| catalog load admission/commit | 部分ownerのみ(G1の12箇所) | 3 clockの合成とatomicityがcall site依存 | 単一catalog transaction owner(beginでproofを封入し、validation・surface mutation・canonical projectionを同一isolation/CASで不可分化) |
| activation 状態機械 | ProcessRouteReadinessStore(状態)+ coordinator ext(遷移) | (pid,upstream,attempt) 三つ組を呼び出し側が携行 | 状態機械に遷移も内蔵、timeout/RPC handle は phase の付随物として自動失効 |
| window owner index | WindowOwnerIndex(値型) | eligibility外部注入; 削除5箇所分散; hint-less inference policyとconflict意味論が別関数 | owner resolution service(index+eligibility+conflict意味論+明示policyを単一型に) |
| upstream slot pool | upstreamsBox + 手動3連 append | index 整合が暗黙 protocol | slot registry(append/replace/retire を単一 API に) |
| init handshake | InitializeManager(キャッシュは broker へ一本化済み) | 比較的健全。current-primary選択chainが3箇所重複 | 現状維持 + primary選択owner統合を必要性に応じ検討 |

## 6. 最重要仮説(推測、要 lead 検証)

- **仮説1(verificationで弱化)**: generation / route lease / activation attemptは別clockで部分ownerもある。欠けているのは「完了が観測した世界はまだcurrentか」の合成判定とatomic commit owner。catalog transaction候補は3clockを封入し、validation・surface mutation・canonical projectionを同じisolation boundaryまたはCASで不可分にする必要がある。
- **仮説2**: broker generation の3役兼務が「window 更新→カタログ無効化→空/stale カタログ→retry」の連鎖を生み、catalog 系 fix と owner 系 fix が相互に誘発し合っている(commit 列で catalog fix 群と owner fix 群が交互に出現することと整合)。
- **仮説3**: exposure を authority 化して epoch を消費させれば、G3 の7消費点と G4/G5 の分散削除は「exposure 変化イベント購読」1系統に畳める。

# CANDIDATE FINDINGS

## [high・WEAKENED] 3 clock の個別 owner はあるが、カタログ完了時の合成判定とatomic commitのownerが不在 (process-catalog)
EVIDENCE: RuntimeCoordinator+ControlPlane.swift:506-671 (recordAvailableToolsCatalogの5段直列check), 702-728 (processToolsCatalogLoadLeaseIsCurrent、失敗経路で2回呼ぶ265-283), 442-465 (retry timerの6条件guard); RuntimeCoordinator.swift:952-1038 (non-atomic generation re-check付きmutation lock); ControlPlaneCoordinator.swift:560-610; ProcessRouteReadinessStore.swift:102-173 (generation tag付きretry),250-294(attempt検査)。fix commits 258ace47/382bf4be/4abbc84e/51cfe2f9/04ac3cea/81e361e1/f9cb2000/eba14516はこの集合へのpatch。+ControlPlane.swiftは41 commits。
DIRECTION: (hypothesis) 単一のcatalog transaction ownerを導入し、ロード開始時にgeneration / route lease / attemptを封入する。validation・surface mutation・canonical projectionを同一isolation boundaryで直列化するか、storeがproofをconsumeするCASにする。単にcommit関数を1箇所へ寄せるだけではatomicityを保証しない。

## [high] CanonicalBrokerState.generation が3役兼務(initializeキャッシュ有効性・カタログ有効性・window owner変化通知)で、owner更新のたびに in-flight カタログロードを全滅させる (control-plane)
EVIDENCE: CanonicalBrokerState.swift:126-145 (clearInitialize/clearToolsCatalog が同一 generation を bump); RuntimeCoordinator+XcodeProcessRouting.swift:349-355, 366-372, 821-827, 849-855 (window owner 変化→ invalidateControlPlane(clearToolsCatalog: true)); ControlPlaneCoordinator.swift:576-584 (generation 不一致で waiter に CancellationError)。
DIRECTION: (hypothesis) 役割別 epoch へ分離、または owner index 変化はカタログ無効化ではなく owner-resolution 層のみの再計算にする。catalog fix と owner fix が交互に出る churn パターンの根と推測。

## [high] RuntimeCoordinator が13以上のロック付きストアを非actorクラスで束ね、ストア間 invariant を呼び出し順序で維持する god object (module-boundary)
EVIDENCE: RuntimeCoordinator.swift:361-437 (ストア列挙), 623-667 (WeakRuntimeCoordinatorBox 経由の循環依存 closure); RuntimeCoordinator+XcodeProcessReconciliation.swift:224-226 (upstreamRouter/healthManager/debugRecorder への手動3連 appendUpstreams = 暗黙同期プロトコル); UpstreamRouting.swift:261-351 (handleUpstreamExit が6ストアを順に変更)。RuntimeCoordinatorは本体1ファイル+extension 8ファイル、合計8,002行。
DIRECTION: (hypothesis) スロット pool の append/replace/retire を単一 registry API に、exposure を単一 authority に。coordinator は配線のみ残す。

## [medium] Exposure(usable route集合)が owner 不在の毎回再計算派生値で、7消費点が各自合成。照合用 epoch は production 未消費 (process-routing)
EVIDENCE: ProcessRouteStore.swift:462-515 (exposure、読み取り中に prune で generation bump の副作用 315-318, 486-489); XcodeProcessRouting.swift:410-448 (usability snapshot を呼び出し側が合成); 消費点: RouteActivation.swift:8, Reconciliation.swift:385-401, XcodeProcessRouting.swift:233-251, 660-663, 764-785, RuntimeXcodeTargetDiscovery.swift:23-26。ExposureSnapshot.epoch/currentEpoch() の消費者は Tests のみ (RuntimeCoordinatorTests.swift:1933, 7107)。
DIRECTION: (hypothesis) ExposureAuthority を単一 owner 化し、変化を epoch 付きイベントで配信。G4/G5 の分散削除(5箇所)も購読1系統に畳む。

## [medium・WEAKENED] Window owner resolutionはindex / eligibility / conflict / hint-less inference policyに分散するが、catalog inferenceは第二truthではない (window-owner-routing)
EVIDENCE: XcodeProcessRouting.swift:652-684のinferredUnambiguousOwnerProcessIDはhint-less requestだけのtest-pinned policyで、hint付きrequestはhard rejectする。owner lookup、eligibility注入、conflict messageはXcodeProcessRouting.swift:1272-1422とWindowOwnerIndex.swift:78-96へ分散。旧surface返却・25ms poll・proxyTabIdentifier捏造・production fake routeIDという元の複合主張はverification/fallbacks.mdで反証済み。
DIRECTION: (hypothesis) owner resolutionを単一serviceにし、index + eligibility + conflict意味論 + hint-less inference policyを1境界へ集める。inferenceを残すなら適用条件をpublic/wire contractに明示する。

## [medium] Activation 状態機械が状態(store)と遷移(coordinator extension)に分割され、(pid, upstreamIndex, attempt) 三つ組を全呼び出し側が携行 (route-activation)
EVIDENCE: ProcessRouteReadinessStore.swift:69-72 (3つの独立ロック), 308-426 (handleTimeout/handleCatalogTimeout/storeCatalogTimeout/storeCatalogRPCHandle が三つ組一致を個別検査、不一致で即cancel); RuntimeCoordinator+XcodeProcessRouteActivation.swift 全体444行が遷移駆動; +ControlPlane.swift:849-857 (fallback RPC を activation attempt に登録するコメント付き回避策)。
DIRECTION: (hypothesis) 遷移を store 内の状態機械に内蔵し、timeout/RPC handle を phase の付随リソースとして phase 遷移時に自動失効させる。

## [medium] 識別子の型不在: 型付き UpstreamSlotID/XcodeProcessID が Session 層に届かず raw Int/pid_t が3種の identity 系統(index/upstreamID/ProcessRouteID)と混在 (identity)
EVIDENCE: UpstreamTopologySnapshot.swift:4-30 (型付きIDの定義) vs Session層全域で raw Int (例: ProcessToolSurfaceStore.swift:74 processIDByUpstreamIndex: [Int: pid_t]); UpstreamHealthManager.swift:60-72 (Int64 upstreamID); ProcessRouteStore.swift:222-229 (ProcessRouteID採番); ProcessToolSurfaceStore.swift:87-95 (偽ID生成経路の現存)。
DIRECTION: (hypothesis) slot/route/attempt の identity を型で区別し、偽ID生成経路(record legacy API)を削除。

## [low] Docs の Ownership Boundaries に fix-churn 主戦場(process routing/exposure/window owner/activation)が存在しない (docs)
EVIDENCE: Docs/maintainer-architecture.md:18-25 は process-bound routing 系ストアを一切記述せず。同:134 の Review Checklist『Canonical cache cannot survive upstream exit/quarantine/eager retry windows』は G4 invariant を型でなく人間レビューで守っている証拠。churn 実測: +ControlPlane 41 / +XcodeProcessRouting 28 / +XcodeProcessReconciliation 17 commits、ストア3種は commit 2c677e05 で新規抽出。
DIRECTION: (hypothesis) 構造修正後に owner map を docs に反映。checklist 項目は型/単一 owner で置換できたものから削除。
