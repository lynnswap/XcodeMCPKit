# Design Audit 2026-07

- 実施日: 2026-07-10
- 基準 commit: `a1c6218e`(main、クリーンツリー)
- 手法: 証拠収集 7 系統(git 履歴分類 / レビュー thread 分類 / 両ライブラリの public API surface / MCP spec 2025-06-18 一次照合 / Session 内部 owner map / module 境界)+ 全主要 finding への adversarial 検証(反証試行・失敗トレース構築)。反証が成立した主張は「反証済み」節に分離し、本文の finding は検証通過分のみ。
- **注意: 本文の file:line は基準 commit 時点のスナップショット。**修正着手時は現 HEAD で再確認すること。
- 付随資料: [evidence/](evidence/)(収集レポート 7 本)、[verification/](verification/)(検証レポート 8 本)、[handoff-prompt.md](handoff-prompt.md)(修正作業の引き継ぎプロンプト)

## 結論

1. **モジュール境界と public API の「外形」は健全。** 直近 20 PR のレビュー thread 28 件のうち module 境界への指摘は 0、両 Kit の README とコードのドリフトも 0。外部 consumer package をコンパイルして境界を検証する `PublicProductContractTests` は優れたプラクティス。
2. **構造問題は 1 箇所に極端に集中。** 全履歴 686 コミット中 fix 374 件の **81% が proxy runtime(process catalog / window-owner routing)**、レビュー thread の **89% が `Internal/Session`**。同日中に guard を追加して数時間後に撤回するサイクルが 3 件(b43b1ad6→81e361e1 ほか)。根は「**非同期完了の観測世界がまだ現在かという合成判定に owner がいない**」(F1)と「**broker generation の 3 役兼務**」(F2、client-visible バグあり)。
3. **API usability:** `XcodeMCPKit`(SDK)は小さく統制された良設計だが、「**セッション lifecycle の観測と回復**」という変動軸が丸ごと欠落(F7)。`XcodeMCPProxyKit` は **public surface の ~42% が「repo 自身は使わず、外部には実装不能」な launch-plan 層**(F5)。

2c677e05 で作られ翌日削除された `Docs/process-route-rearchitecture.md`(`git show 2c677e05:Docs/process-route-rearchitecture.md` で復元可能)は本監査とほぼ同じ診断を先に下している。診断は正しく、store 抽出で止まって遷移ロジックが coordinator に残ったことが churn の直接原因。

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

## 主要 Finding(全て adversarial 検証通過)

### F1 [CONFIRMED] カタログ完了の「観測世界はまだ現在か」判定に owner がいない

- 症状: stale-catalog 系 fix 25+ コミット、PR #170 だけで staleness 指摘 8 thread。
- 破られた invariant: 検証の結果、単一 invariant の 12 コピーではなく **3 つの独立 clock**(broker generation / route-lease 同一性 / activation attempt)で、各 clock には部分的 owner が存在する。owner 不在なのは **3 clock の合成判定**。`recordAvailableToolsCatalog`(`RuntimeCoordinator+ControlPlane.swift:506-671`)は 5 段直列チェック、retry timer は 6 条件 guard と、call site ごとに異なる部分集合・順序で組み立てられている。
- 検証で確定した具体的欠陥:
  - **gate 皆無のバイパス**: `setCachedToolsListResult`(`RuntimeCoordinator.swift:929-935`、呼出し元 `MCPForwardingService.swift:97`)は `onlyIfGeneration` なしで canonical catalog を書く。
  - **TOCTOU gap**: route 置換は generation を bump しない(`.syncCanonical` 経路、`RuntimeCoordinator.swift:1020-1028`)ため、route チェック(:533)と書込(:639)の間の置換で stale route のカタログが着地しうる。`ProcessToolSurfaceStore.recordCatalog` は内部検証なしの無条件書込。
  - **production-dead な二重チェック**: funnel の 2 回目 generation チェック(`RuntimeCoordinator.swift:961`)と失敗経路の 2 回目 lease チェック(`+ControlPlane.swift:276-283`)は、間に test hook しか挟まっておらず production では純粋な重複。
- primary fix: 単一の「catalog transaction」型 — ロード開始時に (generation, route lease, attempt) を封入し、commit 点 1 箇所でのみ合成検証して書き込む。canonical 書込 API は staleness 証明を必須引数にし、`setCachedToolsListResult` の非ゲート経路を廃止。
- 対症療法(採らない): n 箇所目の call site への generation チェック追加。4abbc84e / 51cfe2f9 / 382bf4be がこの形で、同日撤回(81e361e1, 9f726a6b)を生んだ。
- 詳細: [verification/staleness-guards.md](verification/staleness-guards.md)

### F2 [CONFIRMED・client-visible] broker generation の 3 役兼務 — window 変化が無関係な tools/list を落とす

- 失敗トレース(検証済み): client の `tools/list` ロード中(startGeneration=G)に Xcode の tab/window が変化 → owner index 更新 → `invalidateControlPlane(clearToolsCatalog: true)`(`RuntimeCoordinator+XcodeProcessRouting.swift:849-855`)→ generation G→G+1 → in-flight waiter 全員に CancellationError → **ErrorMapper に CancellationError ケースが無く default に落ち、client は `-32000 "upstream timeout"` を受信**(`+ControlPlane.swift:33-52`)。upstream は健全でカタログ内容も不変。
- 破られた invariant: 「catalog の無効化はカタログに影響する事象に限る」。canonical catalog は per-process tools/list の union で window index に依存しないことを検証済み。
- owner: `CanonicalBrokerState.generation` が init-cache 無効化・catalog 無効化・owner 変化通知を 1 カウンタで兼務(`CanonicalBrokerState.swift:126-156`)。
- primary fix: 役割別 epoch へ分離し、owner index 変化を catalog invalidation から切断。あわせて ErrorMapper に CancellationError ケースを追加(誤ラベルの解消は分離前でも価値がある)。
- 詳細: [verification/generation-tripleduty.md](verification/generation-tripleduty.md)

### F3 [CONFIRMED] attempt スコープの資源寿命が「登録の慣習」で守られている

レビュー thread 最大勢力(~20 thread)。「attempt N が予約した timeout/RPC handle が attempt N+1 に漏れる」が PR #160/#161/#162/#166 で反復。PR #161 の修正は「全 RPC handle を attempt に登録」— 登録は各発行 site の義務のままで、次の発行 site で再発する。primary fix は attempt を owner 型にし、phase 遷移時に付随資源(timeout, RPC handle, waiter)を自動失効させること。

### F4 [CONFIRMED] RuntimeCoordinator の偽の分解と test-hook idiom

- 本体+6 extension で ~7,600 行。`final class ... Sendable`(actor でない)が 13+ のロック付き store を束ね、store 間整合は呼出し順序で維持。fix コミット数: 本体 73 / +ControlPlane 56 / +XcodeProcessRouting 45。
- `RuntimeCoordinatorTestHooks`(`RuntimeCoordinator.swift:38-56`、10 closures)が production パス ~25 箇所から呼ばれ、`#if DEBUG` は repo 全体で 0 件。hook 名 `processToolCatalogSurfaceUpdatePassedInitialGenerationCheck` が示す通りテストが内部 guard の通過順序に固定されており、「20 PR 中 5 PR が純粋な flake 修正」という症状の owner。sibling 型にも同 idiom が伝播済み。
- `ControlPlane.DebugMirror` は毎回 primary から全量再構築される read-model で production 挙動に影響しない(WEAKENED)。ただし鮮度は手動 `syncDebug` の慣習依存で、テスト同期プリミティブとしての flake 源になりうる。

### F5 [CONFIRMED] XcodeMCPProxyKit: public surface の ~42% が「二つの半端な story」

- launch-plan 族(~80/192 decls)は repo 自身の executable からは未使用(3 つとも `run()` のみ呼ぶ 12〜21 行の thin shell)。README が売る custom-launcher story は public API では完遂不能: `Launcher` は package、`ExistingServerController` は internal、`isAddressAlreadyInUse` は package、logging bootstrap も package。外部 launcher にとって `forceRestart` は読み取り専用データ、`PortInUseError` はメッセージ整形器(トレース済み)。
- 3 つの `LaunchPlan` の payload optional が repo 自身の launcher に can't-happen guard を 3 個強制、README は `plan.configuration!` を例示(`Sources/XcodeMCPProxyKit/README.md:139`)。`LaunchAction` の associated value 化で型ごと消える。
- `XcodeMCPProxyInstaller`(40 decls、surface の ~21%)の production consumer は 12 行の main のみ。
- primary fix: 契約をどちらかに決める — (推奨) `run()` を launcher 契約とし plan 族を package 降格、または plan 族を契約とし force-restart / port 検出 / logging を public 化。
- 詳細: [verification/launchplan.md](verification/launchplan.md)

### F6 [CONFIRMED] XcodeMCPProxyServer の lifecycle と観測性

- `start()`/`startAndWriteDiscovery()` は同期で内部 NIO `.wait()`。repo 自身の Launcher が async 関数からこれを呼び cooperative thread をブロック。
- ELG が init で生成され deinit なし — 構築して start しなかったインスタンスは NIO thread を leak(トレース済み)。
- embedder への観測点ゼロ: health/debug は自 HTTP endpoint 経由のみ、logger 注入不可、**discovery file 書込失敗は warning に握りつぶされ `startAndWriteDiscovery()` は成功を返す**(adapter が endpoint を見つけられない事態を embedder が検知不能)。
- 詳細: [verification/server-lifecycle-hooks.md](verification/server-lifecycle-hooks.md)

### F7 [CONFIRMED] XcodeMCPKit: 「lifecycle の観測と回復」軸の欠落

| 欠落 | 規範レベル | 要点 |
|---|---|---|
| HTTP 404 → 新 initialize で再セッション | **spec MUST 違反** | transport は 404 を `transportUnavailable` に写像、SSE GET は 404 を terminal 扱い。**proxy-server 再起動後、稼働中の stdio adapter は恒久的に回復不能**(トレース済み) |
| timeout 時の `notifications/cancelled` 送出 | spec SHOULD 逸脱 | timeout で throw するが通知しない。task cancel 時の非送出は spec 上 MAY(usability gap) |
| per-request timeout 設定 | spec SHOULD | per-client 設定のみ。progress でのリセットは spec 上 MAY(SHOULD 主張は反証済み) |
| 接続状態の観測 | — | `isClosed` も状態 stream も切断 callback もなし。切断理由文字列は次リクエスト以後失われる |
| progress callback が `callTool` 返却後に発火しうる | — | delivery Task を remove するのみで cancel/await しない(トレース済み) |

エラーモデル: `XcodeMCPError` は `LocalizedError` 非準拠(repo 自身の ToolVerifier が `String(describing:)` で回避)、stale discovery file が `invalidRequest` に誤分類(実際は「proxy 未起動」環境問題)。ergonomics: `MCPJSONValue` subscript 不在・`intValue`/`integerValue` 完全重複、`MCPContent` 全 case の `raw:` 必須による二重記述、`listTools()` の `nextCursor` 無視、TestRuntime の `configuration.transport` silent 無視。詳細: [verification/kit-usability.md](verification/kit-usability.md)、[verification/client-lifecycle.md](verification/client-lifecycle.md)

### F8 [CONFIRMED] HTTP gateway の spec 照合(2025-06-18 一次情報照合済み)

- **Origin 検証が `/health`・`/debug/*` で免除**(`HTTPHandler.swift:280-287`)— spec は「all incoming connections で MUST」。loopback bind は DNS rebinding の標的で、悪意ページから `GET /debug/upstreams?includeSensitive=1`(redaction 解除)と `POST /debug/reset` が Origin 無検証で到達可能。**P2 最優先のセキュリティ修正。**
- `MCP-Protocol-Version` 欠如の無条件 400 は over-strict(spec は negotiated version 依拠を明示的に許容、400 MUST は invalid/unsupported 限定)。negotiated version は SessionRegistry に保持済み。`Docs/architecture.md:87` が契約として明文化しているため、意図的なら doc に「spec より厳格」と明記、そうでないなら fallback 実装。
- id 無し initialize / malformed message への HTTP 200 + JSON-RPC error は「受理できない notification には HTTP error status MUST」の縁に抵触。
- server→client request の SSE 迂回: POST 応答が常に単一 JSON のため GET stream/buffer 行き。**buffer 50 件超は無警告 drop**、応答待ち upstream は 300s timeout まで待つ。
- 詳細: [verification/http-spec.md](verification/http-spec.md)、[evidence/mcp-contract.md](evidence/mcp-contract.md)

### F9 整理・衛生(確認済み、低リスク)

- `Sources/XcodeMCPProxyRuntime/` は空ディレクトリ(2026-06-28 に 2 時間 13 分だけ存在した target の残骸)。削除可。
- `PublicProductContractTests.swift:588-592` は存在しないモジュール名(`XcodeMCPCore` 等)の import 失敗を検査しており trivially green。実 invariant を検査する形に書き直し。
- `rewriteURLFlagToStdio` は production 呼出しゼロの dead public API で doc と usage が自己矛盾。
- 到達不能 dead code: 旧 surface 返却 branch(`+ControlPlane.swift:183-194`、検証で常に rethrow と証明)。HTTP から到達不能な batch 機構(`forceBatchArray`/`pendingBatches`)。
- docs 訂正 2 件: `maintainer-architecture.md:37`「Executable targets depend on XcodeMCPProxyKit only」は 6 executable 中 2 つで偽。`architecture.md:87` は DELETE の版ヘッダ例外と不一致。
- `--request-timeout` 非数値の silent 無視(fail-fast 違反)、`configurationFilePath: String?` vs `Discovery.fileURL: URL?` の型不整合。

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

### P1 — 再発機構の停止(回復する invariant を併記)

1. **catalog transaction owner の導入**: 開始時に (generation, route lease, attempt) を封入、commit 1 箇所で合成検証。canonical 書込 API は staleness 証明を必須にし `setCachedToolsListResult` バイパスと TOCTOU gap を閉じる。→「stale な完了は書き戻さない」を型で保証。
2. **broker generation の役割分離**: owner index 変化を catalog 無効化から切断。→「無効化はカタログに影響する事象のみ」+ F2 の client-visible バグ解消。ErrorMapper への CancellationError ケース追加は分離前でも先行投入可。
3. **attempt owner 型**: phase 遷移で timeout/RPC handle/waiter を自動失効。→「attempt の資源は attempt と共に死ぬ」を構造で保証。

P1 は `rearchitect` スキルの design gate に乗せる規模。`git show 2c677e05:Docs/process-route-rearchitecture.md` の先行診断が出発点として有用。

### P2 — 契約整合(spec / 外部契約)

4. Origin 検証を全 route に適用(spec MUST、DNS rebinding 実害経路あり)。
5. SDK: 404 → 再 initialize(spec MUST)、timeout 時 cancellation 通知(SHOULD)、per-request timeout(SHOULD)、progress-after-return race 修正。
6. protocol-version 欠如時の negotiated fallback 実装、または over-strict を意図として doc 明記(要ユーザー判断)。
7. 観測性: SSE buffer drop / 未処理 server 通知 / discovery 書込失敗の表面化(warning ログ + `startAndWriteDiscovery` の失敗報告)。

### P3 — 互換方針の範囲での整理(0.x のうちに)

8. ProxyKit surface の決断: `run()` を契約に launch-plan 族を package 降格(推奨)/ LaunchPlan payload の associated value 化 / Installer を executable 側へ。
9. async `start()` の追加(または sync start の deprecate)、ELG の lazy 化 or deinit、embedder 向け health snapshot / event stream の公開。
10. SDK ergonomics: `XcodeMCPError` の LocalizedError 準拠 + 「次アクション」軸での再分類、`MCPContent.text(_:)` raw 合成 factory、`MCPJSONValue` subscript、`intValue` deprecate、`listTools` の cursor 追走 or fail fast。
11. F9 の衛生一式 + test-hook idiom の置換(内部 guard 順序ではなく owner 境界の状態を観測する package seam へ)。

## テストチェックリスト(fix が call-site 非依存であることの検証)

- catalog transaction: route 置換(generation bump なし)中の stale completion が reject される(TOCTOU regression)。`MCPForwardingService` 経路の書込が gate を通る(バイパス regression)。
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
| [design-contracts.md](design-contracts.md) | 修正設計で適用する契約パターン集(2026-07-10 追補)— F7/lifecycle/P1 向けの推奨契約とアンチパターン |

注意: evidence/ は検証前の収集レポートであり、一部の主張は verification/ で反証・弱化されている。**単独で引用せず、必ず verification/ の verdict と突き合わせること。**
