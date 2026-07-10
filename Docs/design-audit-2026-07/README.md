# Design Audit 2026-07

- 実施日: 2026-07-10
- 基準 commit: `a1c6218e`(main、クリーンツリー)
- 手法: 証拠収集 7 系統(git 履歴分類 / レビュー thread 分類 / 両ライブラリの public API surface / MCP spec 2025-06-18 一次照合 / Session 内部 owner map / module 境界)+ 全主要 finding への adversarial 検証(反証試行・失敗トレース構築)。反証が成立した主張は「反証済み」節に分離し、本文の finding は検証通過分のみ。
- **注意: 本文の file:line は基準 commit 時点のスナップショット。**修正着手時は現 HEAD で再確認すること。
- 付随資料: [evidence/](evidence/)(収集レポート 7 本)、[verification/](verification/)(検証レポート 8 本)、[handoff-prompt.md](handoff-prompt.md)(修正作業の引き継ぎプロンプト)
- 監査証拠 status: **CORRECTED**(2026-07-10、`eab7260d` で再照合)。
- 設計status: **APPROVED** (2026-07-10)。実装契約の正本は [canonical-design.md](canonical-design.md)。以下のowner mapとprimary fixは監査時の仮説であり、競合時はcanonical designを優先する。
- 互換方針: **BREAKING CHANGES ALLOWED**(2026-07-10ユーザー決定)。既存source/CLI surfaceのcompatibility layerは既定で追加せず、残すcontractをdesign gateで確定して不要APIを直接削除・型変更する。wire/package/product境界まで変える場合は、許可の有無とは別にconsumer storyと影響をcanonical designへ記録する。

## 結論

1. **外部 product/access boundary と README の signature parity は概ね健全。** 直近 20 PR のレビュー thread 28 件では module 境界への指摘が 0、両 Kit の README と実シグネチャのドリフトも 0。外部 consumer package をコンパイルする `PublicProductContractTests` は良い境界テストだが、存在しない旧モジュール名を検査する trivially-green な項目もあり、これらだけで public surface の到達可能性や lifecycle 契約まで健全とは判定しない。
2. **構造問題は proxy runtime に集中。** 全履歴 686 non-merge commits 中、conventional `fix` は 364 件(旧形式の fix 候補を含めると約374件)。subject-keyword の area 分類ではその約81%が process catalog / window-owner routing に属し、レビュー thread の 89% が `Internal/Session` に集中する。area 分類 script と raw review-thread export は repo に保存されていないため、81%/89% は監査時分類値として扱う。再現可能な補助指標は fix commit touch 数が本体73 / `+ControlPlane` 56 / `+XcodeProcessRouting` 45。同日中に guard を追加して数時間後に撤回するサイクルも3件ある。根は「**非同期完了の観測世界がまだ現在かという合成判定に owner がいない**」(F1)と「**broker generation の3役兼務**」(F2、client-visible bugあり)。
3. **API usability:** `XcodeMCPKit`(SDK)は小さく統制されているが、「**session lifecycle の観測と回復**」という変動軸が欠落(F7)。`XcodeMCPProxyKit`は同一尺度で数えたpublic keyword linesの約38%(72/191)を狭義launch-plan層が占める。repo executableは`run()` facadeだけを直接呼ぶ一方、そのpackage-internal実装はLaunchPlanを消費するため「repo自身が未使用」ではない。外部scratch packageのcompile contractはsurfaceへの到達を検査するが、force-restart/port検出までcomplete behaviorを実行するin-repo production consumerはなく、READMEのexternal custom-launcher storyはpublic APIだけでは完遂できない(F5)。

2c677e05で作られ翌日削除された`Docs/process-route-rearchitecture.md`(`git show 2c677e05:Docs/process-route-rearchitecture.md`で復元可能)は有用な先行仮説を含む。mutationとgeneration checkの分離などFindings 1/3は現HEADでも裏づく一方、Finding 5の「canonical catalogがownershipの第二truth」はverificationで弱化された。store抽出後も遷移ロジックがcoordinatorに残った事実は確認できるが、それがchurnの直接原因という因果は仮説としてdesign gateで検証する。

## Owner map(proxy runtime、現状 → あるべき姿)

| 状態 | 現状の owner | 問題 | あるべき owner(仮説) |
|---|---|---|---|
| route membership / cooldown | `ProcessRouteStore` | 読取り(`exposure`)が prune で generation を進める副作用持ち | 同 store。read を純粋化 |
| exposure(4 policy 派生値) | **不在**(7 消費点が store+healthManager から都度合成) | `ExposureSnapshot.epoch` は production 未消費 | 単一 ExposureAuthority(epoch 発行) |
| canonical catalog + init cache | `CanonicalBrokerState` | **generation が 3 役兼務**(F2) | 役割別 epoch に分離 |
| カタログ完了の staleness 判定 | **不在**(call site ごとに 3 clock を ad hoc 合成) | F1。fix 25 連発の震源 | 単一「catalog transaction」型 |
| activation 状態機械 | 状態=`ProcessRouteReadinessStore` / 遷移=coordinator extension | (pid, upstream, attempt) 三つ組を全呼出し側が携行 | 遷移を store 内蔵、timeout/RPC handle は phase 付随物として自動失効 |
| window owner 解決 | `WindowOwnerIndex` + coordinator 分岐 + eligibility 外部注入 | 削除 5 箇所分散、conflict 意味論 3 関数分散 | index+eligibility+conflict を単一 service に |
| upstream slot pool | `upstreamsBox` + 手動 3 連 `appendUpstreams`(`RuntimeCoordinator+XcodeProcessReconciliation.swift:224-226`) | index 整合が暗黙プロトコル | append/replace/retire を単一 registry API に |
| init handshake | `InitializeManager`(キャッシュは broker に一本化済み) | 健全(owner 一本化の成功例) | 現状維持 |

## 主要 Finding(adversarial 検証後の verdict)

### F1 [CONFIRMED] カタログ完了の「観測世界はまだ現在か」判定に owner がいない

- 症状: stale-catalog 系 fix 25+ コミット、PR #170 だけで staleness 指摘 8 thread。
- 破られた invariant: 検証の結果、単一 invariant の 12 コピーではなく **3 つの独立 clock**(broker generation / route-lease 同一性 / activation attempt)で、各 clock には部分的 owner が存在する。owner 不在なのは **3 clock の合成判定**。`recordAvailableToolsCatalog`(`RuntimeCoordinator+ControlPlane.swift:506-671`)は 5 段直列チェック、retry timer は 6 条件 guard と、call site ごとに異なる部分集合・順序で組み立てられている。
- 検証で確定した具体的欠陥:
  - **TOCTOU gap**: route 置換は generation を bump しない(`.syncCanonical` 経路、`RuntimeCoordinator.swift:1020-1028`)ため、route チェック(:533)と書込(:639)の間の置換で stale route のカタログが着地しうる。`ProcessToolSurfaceStore.recordCatalog` は内部検証なしの無条件書込。
  - **非原子的な反復 check**: funnel の2回目 generation check(`RuntimeCoordinator.swift:961`)と失敗経路の2回目 lease check(`+ControlPlane.swift:276-283`)は、2回の read 間に別 thread の mutation が割り込めるため production でも競合を検出しうる。ただし check と mutation を同じ isolation boundary で直列化せず、TOCTOU は閉じない。
  - **到達性未確定の非ゲート API**: `setCachedToolsListResult`(`RuntimeCoordinator.swift:929-935`)は `onlyIfGeneration` なしで canonical catalog を書く。ただし通常の initialized `tools/list` は local handling で先に処理され、uninitialized request は routing 前に reject されるため、唯一の Source caller `MCPForwardingService.swift:97` へ至る production request path は確認できなかった。confirmed bypass ではなく legacy/dead-path 候補として F9 に分離する。
- primary fix 仮説: ロード開始時に (generation, route lease, attempt) を封入する単一の catalog transaction owner を置く。単に commit 関数を1箇所へ寄せるだけでは不十分で、validation・surface mutation・canonical projection を同じ isolation boundary で直列化するか、store が transaction proof を consume する CAS として成立させる。canonical 書込 API はこの証明を必須にする。
- 対症療法(採らない): n 箇所目の call site への generation チェック追加。4abbc84e / 51cfe2f9 / 382bf4be がこの形で、同日撤回(81e361e1, 9f726a6b)を生んだ。
- 詳細: [verification/staleness-guards.md](verification/staleness-guards.md)

### F2 [CONFIRMED・client-visible] broker generation の 3 役兼務 — window 変化が無関係な tools/list を落とす

- 失敗トレース(検証済み): client の `tools/list` ロード中(startGeneration=G)に Xcode の tab/window が変化 → owner index 更新 → `invalidateControlPlane(clearToolsCatalog: true)`(`RuntimeCoordinator+XcodeProcessRouting.swift:849-855`)→ generation G→G+1 → in-flight waiter 全員に CancellationError → **ErrorMapper に CancellationError ケースが無く default に落ち、client は `-32000 "upstream timeout"` を受信**(`+ControlPlane.swift:33-52`)。upstream は健全でカタログ内容も不変。
- 破られた invariant: 「catalog の無効化はカタログに影響する事象に限る」。canonical catalog は per-process tools/list の union で window index に依存しないことを検証済み。
- owner: `CanonicalBrokerState.generation` が init-cache 無効化・catalog 無効化・owner 変化通知を 1 カウンタで兼務(`CanonicalBrokerState.swift:126-156`)。
- primary fix 仮説: 役割別 epoch へ分離し、owner index 変化を catalog invalidation から切断する。`CancellationError` は caller cancel / shutdown / invalidation / supersession を区別しないため、ErrorMapper へ一律 case を足してはいけない。まず cancellation reason を owner 境界で型に分け、F2 の内部 invalidation 自体を除去した後、consumer-visible reason だけを正しく map する。
- 詳細: [verification/generation-tripleduty.md](verification/generation-tripleduty.md)

### F3 [CONFIRMED] attempt スコープの資源寿命が「登録の慣習」で守られている

attempt/resource lifetimeへ直接帰属できるreview threadは約9件(initialize lifecycle 7件 + handle登録2件、狭義Class Bは約6件)。より広いRuntimeCoordinator/InitializeManager control-plane clusterは20件。「attempt Nが予約したtimeout/RPC handleがattempt N+1へ漏れる」がPR #160/#161/#162/#166で反復し、PR #161の修正後も登録は各発行siteの義務として残る。primary fix仮説はattemptをowner型にし、phase遷移時に付随資源(timeout, RPC handle, waiter)を自動失効させること。

### F4 [構造事実 CONFIRMED / flake 因果 PLAUSIBLE] RuntimeCoordinator の偽の分解と test-hook idiom

- 本体+8 extension files で 8,002 行。`final class ... Sendable`(actor でない)が 13+ のロック付き store を束ね、store 間整合は呼出し順序で維持。fix コミット数: 本体 73 / +ControlPlane 56 / +XcodeProcessRouting 45。
- `RuntimeCoordinatorTestHooks`(`RuntimeCoordinator.swift:38-56`、10 closures)が production build にも含まれる path ~25 箇所から呼ばれ、`#if DEBUG` は repo 全体で0件。hook 名 `processToolCatalogSurfaceUpdatePassedInitialGenerationCheck` が示す通り、テストを内部 guard の通過順序へ結合する。20 PR 中5 PRが純粋な flake 修正という履歴とは相関するが、hooks がその原因であることまでは証明できないため verdict は **PLAUSIBLE**。owner-boundary state を観測するテストへ移す設計候補とする。
- `ControlPlane.DebugMirror` は毎回 primary から全量再構築される read-model で production 挙動に影響しない(WEAKENED)。ただし鮮度は手動 `syncDebug` の慣習依存で、テスト同期プリミティブとしての flake 源になりうる。

### F5 [CONFIRMED] XcodeMCPProxyKit: public keyword lines の ~38% が「二つの半端な story」

- 狭義launch-plan族は同一尺度で72/191 public keyword lines(~38%)。repo executableは直接使わず、3つとも`run()`だけを呼ぶ12〜21行のthin shellだが、`run()`はpackage-internal `Launcher`を介してLaunchPlanを使うためpackage内では利用されている。問題はREADMEが売るexternal custom-launcher storyがpublic APIでは完遂不能なこと: `Launcher`はpackage、`ExistingServerController`はinternal、`isAddressAlreadyInUse`とlogging bootstrapもpackage。外部launcherにとって`forceRestart`は読み取り専用データ、`PortInUseError`はメッセージ整形器(トレース済み)。
- 3 つの `LaunchPlan` の payload optional が repo 自身の launcher に can't-happen guard を 3 個強制、README は `plan.configuration!` を例示(`Sources/XcodeMCPProxyKit/README.md:139`)。`LaunchAction` の associated value 化で型ごと消える。
- `XcodeMCPProxyInstaller`は40 public keyword lines(surfaceの~21%)。module外のin-repo production callerは12行のmainのみだが、module READMEにはembedder例があり、外部利用の有無はrepoから確認できない。
- primary fix: 契約をどちらかに決める — (推奨) `run()` を launcher 契約とし plan 族を package 降格、または plan 族を契約とし force-restart / port 検出 / logging を public 化。
- 詳細: [verification/launchplan.md](verification/launchplan.md)

### F6 [CONFIRMED] XcodeMCPProxyServer の lifecycle と観測性

- `start()`/`startAndWriteDiscovery()` は同期で内部 NIO `.wait()`。repo 自身の Launcher が async 関数からこれを呼び cooperative thread をブロック。
- ELG が init で生成され deinit なし — 構築して start しなかったインスタンスは NIO thread を leak(トレース済み)。
- embedder への観測点ゼロ: health/debug は自 HTTP endpoint 経由のみ、logger 注入不可、**discovery file 書込失敗は warning に握りつぶされ `startAndWriteDiscovery()` は成功を返す**(adapter が endpoint を見つけられない事態を embedder が検知不能)。
- 詳細: [verification/server-lifecycle-hooks.md](verification/server-lifecycle-hooks.md)

### F7 [CONFIRMED] XcodeMCPKit SDK / stdio adapter: 「lifecycle の観測と回復」軸の欠落

| 欠落 | 規範レベル | 要点 |
|---|---|---|
| HTTP 404 → 新 initialize で再セッション | **spec MUST 違反** | transport は 404 を `transportUnavailable` に写像、SSE GET は 404 を terminal 扱い。**proxy-server 再起動後、稼働中の stdio adapter は恒久的に回復不能**(トレース済み) |
| timeout 時の `notifications/cancelled` 送出 | spec SHOULD 逸脱 | timeout で throw するが通知しない。task cancel 時の非送出は spec 上 MAY(usability gap) |
| per-request timeout 設定 | spec SHOULD | per-client 設定のみ。progress でのリセットは spec 上 MAY(SHOULD 主張は反証済み) |
| 接続状態の観測 | — | `isClosed` も状態 stream も切断 callback もなし。切断理由文字列は次リクエスト以後失われる |
| progress callback が `callTool` 返却後に発火しうる | — | delivery Task を remove するのみで cancel/await しない(トレース済み) |

エラーモデル: `XcodeMCPError` は `LocalizedError` 非準拠(repo 自身の ToolVerifier が `String(describing:)` で回避)、stale discovery file が `invalidRequest` に誤分類(実際は「proxy 未起動」環境問題)。ergonomics: `MCPJSONValue` subscript 不在・`intValue`/`integerValue` 完全重複、`MCPContent` 全 case の `raw:` 必須による二重記述、`listTools()` の `nextCursor` 無視、TestRuntime の `configuration.transport` silent 無視。詳細: [verification/kit-usability.md](verification/kit-usability.md)、[verification/client-lifecycle.md](verification/client-lifecycle.md)

CodexのHTTP adapterは`openai/codex@1f0566d3`でsession-id付きPOST/GETの404だけをtyped `SessionExpired404`にする。request send pathはこのtyped errorをsingle-flight recoveryへ接続し、元操作を1回だけreplayするが、GET streamの404が同じ回復経路を通ることまでは確認できない。この骨格は参考になる一方、Codexはoriginal attempt / reinitialize / replayを単一deadlineに束ねず、generic retry分類には文字列解析も含むため、そのまま採用しない。XcodeMCPKit側は**serverが処理前に拒否したと型で証明できる404だけ**replay可とし、1 logical deadline・single-flight・one-shotをsession ownerの契約候補にする。Codexも上位`listTools`で`next_cursor`を捨てるためpaginationの先例にはしない。

### F8 [CONFIRMED] HTTP gateway の spec 照合(2025-06-18 一次情報照合済み)

- **Origin 検証が `/health`・`/debug/*` で免除**(`HTTPHandler.swift:280-287`)— spec は「all incoming connections で MUST」。loopback bind は DNS rebinding の標的で、悪意ページから `GET /debug/upstreams?includeSensitive=1`(redaction 解除)と `POST /debug/reset` が Origin 無検証で到達可能。**独立した P0 security fix。タスク A の design gate より先、または並行して修正する。**
- `MCP-Protocol-Version` 欠如の無条件 400 は over-strict(spec は negotiated version 依拠を明示的に許容、400 MUST は invalid/unsupported 限定)。negotiated version は SessionRegistry に保持済み。`Docs/architecture.md:87` が契約として明文化しているため、意図的なら doc に「spec より厳格」と明記、そうでないなら fallback 実装。
- id 無し initialize / malformed message への HTTP 200 + JSON-RPC error は「受理できない notification には HTTP error status MUST」の縁に抵触。
- server→client request の SSE 迂回: POST 応答が常に単一 JSON のため GET stream/buffer 行き。**buffer 50件超は無警告 drop**。client は request を受信できず、proxy も upstream へ failure/cancel を返さない。`ServerRequestTracker` の既定300秒は response-ID route mapping の lazy TTL にすぎず、active timer でも upstream response deadline でもないため、upstream の実際の待機時間は未確認。
- HTTPはbatchを400でrejectするが、executor内部では`ForwardExecutor.swift:193`のrefresh splitがarray payloadを生成し、`forceBatchArray`/`pendingBatches`が現役。external dead codeとして即削除せず、内部payloadを単一message列へ正規化してcontract testを通した後に分岐を削除する。
- 詳細: [verification/http-spec.md](verification/http-spec.md)、[evidence/mcp-contract.md](evidence/mcp-contract.md)

### F9 整理・衛生(確認済み、低リスク)

- `PublicProductContractTests.swift:588-592` は存在しないモジュール名(`XcodeMCPCore` 等)の import 失敗を検査しており trivially green。実 invariant を検査する形に書き直し。
- `setCachedToolsListResult` は非ゲート canonical 書込 API だが、現 source call graph で production request からの到達性を確認できない。production bypass として直すのではなく、到達性を contract test で確定し、dead なら API と cacheable branch を削除、到達可能なら catalog transaction owner へ統合する。
- 到達不能dead code: 旧surface返却branch(`+ControlPlane.swift:183-194`、検証で常にrethrowと証明)。
- docs 訂正2件: `maintainer-architecture.md:37`「Executable targets depend on XcodeMCPProxyKit only」は5 executable targets中2つで偽。`architecture.md:87` は DELETE の版ヘッダ例外と不一致。

## 反証済み・修正不要(won't-fix)

**以下は監査中に反証が成立した主張。再修正・再指摘しないこと。**

| 主張 | 判定 | 根拠 |
|---|---|---|
| `inferredUnambiguousOwnerProcessID` は ownership の第二 truth | 反証(弱化) | hint 付き要求は推測に到達せず hard reject。推測は hint-less 要求の test-pinned 正常系(`RuntimeCoordinatorTests.swift:9585, 9626`)。残余: 2 台目 Xcode のカタログ未ロード窓で false-unambiguous になりうる点のみ |
| エラー時に旧 surface を success 返却 | 反証 | 当該 branch は到達不能 dead code(F9 の削除対象)。25ms poll は並行勝者の完全 surface を待つ coalescing で stale 返却しない |
| `?? 0` の primary index 捏造 | 弱化 | cold 状態でのみ発火し restart 戦略選択にしか使われない。slot 0 は routing 無効時の規約デフォルト。同一 chain の 3 箇所重複(「current primary の owner 不在」)は smell として残る |
| `ProcessToolSurfaceStore.record()` の偽 routeID | 反証 | production 呼出しゼロ(テスト専用 seeding)。production 型に guard をバイパスする test-support API が居る衛生課題は残る |
| `proxyTabIdentifier` のハッシュ捏造 | 反証 | 純決定関数で両 branch が同一値。lookup arm の冗長は簡素化候補にすぎない |
| 「progress で timeout リセットは spec SHOULD」 | 反証 | 実際は MAY。正しい SHOULD は per-request timeout 設定可能性(F7 に反映) |

詳細: [verification/fallbacks.md](verification/fallbacks.md)、[verification/staleness-guards.md](verification/staleness-guards.md)、[verification/client-lifecycle.md](verification/client-lifecycle.md)

## 優先順位付き修正方針

### P0 — Security boundary

1. **Origin 検証を全 route に適用**: MCP Streamable HTTP transport の MUST。DNS rebinding の実害経路があるため、タスク A の design gate より先、または並行して独立修正する。

### P1 — 再発機構の停止(回復する invariant を併記)

2. **catalog transaction owner の導入**: 開始時に (generation, route lease, attempt) を封入し、validation・surface mutation・canonical projection を単一 isolation boundary または store CAS で不可分にする。canonical 書込 API は transaction proof を必須にする。→「stale な完了は書き戻さない」を型と isolation で保証。
3. **broker generation の役割分離**: owner index 変化を catalog 無効化から切断。→「無効化はカタログに影響する事象のみ」+ F2 の client-visible bug解消。cancellation reason の型分けを先に設計し、blanket `CancellationError` mapping は追加しない。
4. **attempt owner 型**: phase 遷移で timeout/RPC handle/waiter を自動失効。→「attempt の資源は attempt と共に死ぬ」を構造で保証。
5. **test observability契約**: guard通過順序を観測するhooksを既定形として固定しない。Task Aのdesign gateでowner-boundary stateをどう決定的に観測するかを決め、そのcontractへtestsを移す。現hooksとflake修正集中の因果は未証明なので、determinismとcoverageで評価する。

P1 は `rearchitect` スキルの design gate に乗せる規模。`git show 2c677e05:Docs/process-route-rearchitecture.md` の先行診断が出発点として有用。

### P2 — 契約整合(spec / 外部契約)

6. SDK / stdio adapter: typed session-expired 404でsingle-flightに新sessionをinitializeする(spec MUST)。元操作を1回だけreplayするproduct contractを採るなら、original attemptからreplayまで1 logical deadlineを共有し、delivery不明のside-effecting requestは自動再送しない。加えてtimeout時cancellation通知(SHOULD)、per-request timeout(SHOULD)、progress-after-return raceを修正。
7. protocol-version欠如時のnegotiated fallback実装、またはover-strictを意図としてdoc明記(要ユーザー判断)。
8. 観測性: SSE buffer drop / 未処理server通知 / discovery書込失敗の表面化(warning log + `startAndWriteDiscovery`のfailure報告)。
9. internal batch cleanup: `ForwardExecutor`のrefresh splitを単一message列へ正規化し、内部再入contract test後に`forceBatchArray`/`pendingBatches`を削除する。external入力からdeadという理由だけで先に消さない。

### P3 — 破壊的整理可の public surface 再設計

10. ProxyKit surfaceの決断: **breaking changes allowed**を前提に、`run()`をlauncher契約としてlaunch-plan族をpackage降格する案をprimaryにdesign gateへ出す。残すplan payloadはassociated value化し、Installerのsupported consumer storyが無ければexecutable側へ移す。`rewriteURLFlagToStdio`は直接削除、`configurationFilePath: String?`は`URL?`へ統一、非数値`--request-timeout`はrejectをprimaryとする。canonical designには削除/変更するpublic symbol・CLI flag・consumer impactを列挙する。
11. async `start()`の追加、ELGのlazy化or deinit、embedder向けhealth snapshot/event streamの公開。breaking changes allowedのため既存sync-only contractを維持するwrapperは既定で足さない。
12. SDK ergonomics: `XcodeMCPError`のLocalizedError準拠 + 「次アクション」軸での再分類、`MCPContent.text(_:)` raw合成factory、`MCPJSONValue` subscript、`intValue`削除。現行`listTools() -> [MCPTool]`を維持するなら同一logical deadline内で全pageを追走し、部分catalogとcursor cycleをfail fastする候補契約をdesign gateで確定。

## テストチェックリスト(fix が call-site 非依存であることの検証)

- catalog transaction: route置換(generation bumpなし)中のstale completionがrejectされる(TOCTOU regression)。全canonical書込entrypointがtransaction proofを要求する。`MCPForwardingService`のcacheable branchは到達性をcontract testで確定し、deadならAPIごと削除する。
- window/tab 変化が in-flight `tools/list` を失敗させない(F2 の契約化)。
- attempt owner: timeout 発火が「別 attempt の資源を殺さない」ことを、まだ症状化していない sibling 発行 site で検証。
- stdio adapter が proxy-server 再起動を透過回復する end-to-end テスト。
- cross-origin の `/debug/upstreams` / `/debug/reset` が拒否される。
- `callTool` 返却後に `onProgress` が発火しない。
- 未 start の `XcodeMCPProxyServer` 破棄で NIO thread が残らない。

## 資料一覧

| ファイル | 内容 |
|---|---|
| [evidence/git-history.md](evidence/git-history.md) | fix 履歴の分布・再発チェーン再構成(構造修正型 vs 局所 guard 型の分類) |
| [evidence/review-threads.md](evidence/review-threads.md) | PR #153–#172 のレビュー thread 分類(invariant クラス別) |
| [evidence/session-owner-map.md](evidence/session-owner-map.md) | Session/RuntimeCore の owner map・guard inventory(G1–G5)・fallback 経路一覧 |
| [evidence/kit-api.md](evidence/kit-api.md) | XcodeMCPKit public surface 全列挙と consumer story 摩擦点 |
| [evidence/proxykit-api.md](evidence/proxykit-api.md) | XcodeMCPProxyKit public surface census と到達可能性分類 |
| [evidence/mcp-contract.md](evidence/mcp-contract.md) | MCP spec 2025-06-18 契約テーブル(全 verdict 付き) |
| [evidence/module-boundaries.md](evidence/module-boundaries.md) | target 構成・package 宣言・test topology 監査 |
| [verification/*.md](verification/) | 上記への adversarial 検証(CONFIRMED/WEAKENED/REFUTED + 失敗トレース) |
| [design-contracts.md](design-contracts.md) | 監査findingから導いた候補契約集。承認済みの採否はcanonical designを参照 |
| [canonical-design.md](canonical-design.md) | 承認済みのowner、API、isolation、削除、移行、contract testの正本 |

注意: evidence/ は検証前の収集レポートであり、一部の主張は verification/ で反証・弱化されている。**単独で引用せず、必ず verification/ の verdict と突き合わせること。**
