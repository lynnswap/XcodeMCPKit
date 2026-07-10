# 引き継ぎプロンプト — Design Audit 2026-07 の修正

このファイルは、監査で特定した構造問題の修正に着手するエージェント/担当者への引き継ぎ。
別セッションにそのまま貼れる自己完結プロンプトとして書いてある。着手前に `Docs/design-audit-2026-07/README.md` と、必要に応じて `evidence/` `verification/` を読むこと。

**Design status: NOT APPROVED.** このhandoffは監査由来の要求と候補契約であり、canonical designではない。タスクA/B/Cのinterface、owner、isolation、deadline、互換・削除方針、contract testはそれぞれdesign gateを通してから実装する。

---

## 前提・制約(共通)

- repo: `/Users/kn/Dev/XcodeMCPKit`(Swift 6.3 package、macOS 15.4+、GitHub owner `lynnswap`)
- 監査基準 commit は `a1c6218e`。**監査の file:line はこの時点のスナップショット。着手時に現 HEAD で必ず再確認する**(行番号がずれている前提で扱う)。
- 検証コマンド(README「Maintainers」より):
  - `swift test -Xswiftc -strict-concurrency=minimal`(既定の高速スイート。public product compile contract と proxy contract を含む)
  - `XCODE_MCP_RUN_PROCESS_TESTS=1 swift test --no-parallel --filter XcodeMCPProcessRuntimeTests -Xswiftc -strict-concurrency=minimal`
  - `XCODE_MCP_RUN_PROCESS_TESTS=1 swift test --no-parallel --filter ProxyStdioAdapterTests -Xswiftc -strict-concurrency=minimal`
  - `scripts/check.sh`(フル)
- Git: `lynnswap` owner なので push/PR は明示依頼時のみ。着手前に `git status --short` と元 HEAD の SHA を記録。成果が複数になる作業は task branch に commit して SHA で受け渡す(未コミット差分を積み上げない)。
- 互換方針: **BREAKING CHANGES ALLOWED**(2026-07-10ユーザー決定)。source/CLI compatibility layerやdeprecated redirectは既定で追加しない。残すcontractを先に決め、不要surfaceは直接削除・型変更する。wire/package/product境界を変える場合も、consumer impactと移行後の単一標準形はcanonical designへ明記する。
- Apple/Swift API・MCP spec の事実は記憶で断定せず一次情報で確認(Xcode DocumentationSearch / ios-dev-docs / Apple Developer Docs、MCP は [2025-06-18 Transports](https://modelcontextprotocol.io/specification/2025-06-18/basic/transports) / [Lifecycle](https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle) / [Cancellation](https://modelcontextprotocol.io/specification/2025-06-18/basic/utilities/cancellation))。
- 候補契約: [design-contracts.md](design-contracts.md)(statusはNOT APPROVED)。各タスクの該当節をdesign gateで評価し、採否をcanonical designへ記録する。
- **won't-fix リスト(README「反証済み」節)に載っている項目は再修正・再指摘しない。** 特に: 旧 surface 返却 branch を「バグ」として guard 追加しない(到達不能 dead code なので削除のみ)、`proxyTabIdentifier` 合成を「第二 truth」として直さない、`?? 0` を単独で「捏造」として直さない(current-primary owner 統合の一部としてのみ扱う)。

---

## タスク 0(P0): Origin security boundary

タスク A の design gate より先、または並行して独立修正する。`/health`・`/debug/*` を含む全 incoming route で Origin policy を同じ境界から適用する。現状は `HTTPHandler.swift` の `routeRequiresOriginValidation` がこれらを免除し、loopback bind でも悪意ある browser page から `GET /debug/upstreams?includeSensitive=1` / `POST /debug/reset` へ到達しうる。spec の MUST、既存 non-browser consumer、Origin 欠如時のpolicyを一次情報とcontract testで固定し、routeごとの例外を残さない。

テストは少なくとも cross-origin の `/health`・`/debug/upstreams`・`/debug/reset`・未知route拒否、allowed Origin、採用したmissing-Origin policyを同じtable-driven suiteで検証する。

---

## タスク A(P1・構造修正): proxy runtime 制御平面の再設計

**これは対症療法ではなく構造修正。局所 guard の追加・撤回サイクルを止めるのが目的。`rearchitect` スキルの手順(現状実測 → api-design 規範に沿った目標設計 → design gate 承認 → 移行)に従う。着手前に design-audit スキルではなく rearchitect を起動する。**

**Design status: NOT APPROVED.** まず canonical Task A design doc を作る。既定scopeは単一 `XcodeMCPProxyKit` target内部の再設計で、public Swift API、CLI、wire shape、package/product/target境界は変えない。変更が必要と判明した場合だけ consumer story・変更理由・移行/削除方針をdesign gateへ追加する。owner map、API-first transition sketch、atomicity/isolation、dependency direction、test seam、削除する旧責務を文書化し、承認前に実装へ入らない。

### 回復すべき invariant(3 つ、これが成果の評価軸)

1. **「stale な非同期カタログ完了は書き戻さない」を型で保証する。**(F1)
   - 現状: broker generation / route-lease / activation attempt の 3 clock を call site ごとに ad hoc 合成。`recordAvailableToolsCatalog` は 5 段直列、retry timer は 6 条件。
   - 具体的欠陥(現 HEAD で再確認):
     - route 置換が generation を bump しない(`.syncCanonical` 経路)ことによる route-check と store-write の間の TOCTOU gap。`ProcessToolSurfaceStore.recordCatalog` は無条件書込。
     - 隣接する二重 generation/lease check は、間へ別threadのmutationが割り込めるためproductionでもraceを検出しうるが、checkとmutationを直列化せずTOCTOUを閉じない。
     - `setCachedToolsListResult` は非ゲート canonical 書込API。ただし通常のinitialized `tools/list` はlocal処理され、uninitialized requestはrouting前にrejectされるため、唯一のSource caller `MCPForwardingService` へのproduction到達性は未確認。confirmed bypassとして扱わない。
   - 目標形(仮説、design gateで確定): 単一のcatalog transaction owner。ロード開始時に(generation, route lease, attempt)を封入し、validation・process surface mutation・canonical projectionを同じisolation boundaryで直列化するか、storeがproofをconsumeするCASにする。commit関数を1箇所にするだけでは不十分。`setCachedToolsListResult` は到達性を確定し、deadならAPI/cacheable branchごと削除、到達可能ならtransaction commitへ統合する。

2. **broker generation の役割を分離する。**(F2、client-visible バグ)
   - 現状: `CanonicalBrokerState.generation` が init-cache 無効化・catalog 無効化・window-owner 変化通知を 1 カウンタで兼務。window/tab 変化が in-flight `tools/list` を CancellationError で落とし、ErrorMapper に CancellationError ケースが無いため client に `-32000 "upstream timeout"` が返る。
   - canonical catalog は per-process tools/list の union で window index に依存しないことは検証済み。よって owner index 変化 → catalog 無効化の接続自体が不要。
   - 目標形: 役割別 epoch に分離。owner index 変化は owner-resolution 層の再計算のみとし catalog invalidation に接続しない。
   - `CancellationError` を ErrorMapper で一律mappingしない。caller cancellation / shutdown / load supersession / internal invalidationが同じ型へ潰れており、mapperでは原因を復元できない。まずwindow-owner変化からcatalog invalidationへの誤接続を切る。consumer-visibleな中断が残る場合は、発生ownerがtyped interruption reasonへ変換し、ErrorMapperはその型だけをexhaustively mapする。独立したpre-gate patchは行わない。

3. **attempt スコープの資源寿命を attempt owner に束ねる。**(F3)
   - 現状: timeout / RPC handle / waiter の登録が各発行 site の義務。`ProcessRouteReadinessStore` に状態はあるが遷移は coordinator extension。
   - 目標形: attempt を owner 型にし、phase 遷移時に付随資源を自動失効させる。

### 付随して解ける構造問題(タスク A の設計に織り込む)

- exposure(4 policy 派生値)の owner 不在 → 単一 ExposureAuthority に。`ExposureSnapshot.epoch` は現状 production 未消費なので、authority 化で活かすか削除する。
- upstream slot pool の手動 3 連 `appendUpstreams` → append/replace/retire を単一 registry API に。
- window owner 解決(index + eligibility 外部注入 + conflict 意味論 3 関数分散)を単一 service に。
- RuntimeCoordinator は「状態+それを守る操作」を持つ owner object 群に分解し、coordinator は thin な配線のみ残す(共有 context 参照で同じ状態空間に触れる形は分解ではない)。

### タスク A のテスト観点(fix が call-site 非依存であることの検証を必ず含める)

- route 置換(generation bump なし)の最中に stale completion が reject される(現 TOCTOU の regression テスト)。
- catalog書込entrypointをinventoryし、design後はtransaction proofなしのproduction entrypointが存在しない。`MCPForwardingService` の`setCachedToolsListResult`到達性もcontract testで確定し、到達不能ならAPI/cacheable branchが削除されている。
- window/tab 変化が in-flight `tools/list` を失敗させない(F2 の契約化)。
- attempt owner: timeout 発火が「別 attempt の資源を殺さない」ことを、**まだ症状化していない sibling 発行 site**(secondary fallback RPC 以外)で検証。
- test-hook依存の置換: 内部guard通過順序を観測する既存テストを、owner境界の状態を観測する形へ移す。flake修正の集中とは相関するがhooksが原因とは未証明なので、置換効果はdeterminismとcontract coverageで評価する。

### 出発点資料

- `git show 2c677e05:Docs/process-route-rearchitecture.md`(一度作られ削除された先行仮説)。Findings 1/3のmutation/admission分離は現HEADでも裏づくが、Finding 5のcanonical-catalog second-truth主張は弱化済みで、同docのtarget modelも未承認。canonical designとして流用せず、反証済み部分を除いたinputとしてだけ使う。
- `Docs/design-audit-2026-07/evidence/session-owner-map.md`(owner map・guard inventory G1–G5・fallback 経路)。
- `Docs/design-audit-2026-07/verification/staleness-guards.md` `generation-tripleduty.md`(load-bearing / duplicated の切り分けと失敗トレース)。
- [design-contracts.md §3](design-contracts.md)(internal stale completionとconsumer-visible stale stateの分離、atomic catalog commit、cache意味論、validity scope、**stalenessは「検知するか明示的にdisclaimするか」の二択**)。

---

## タスク B(P2): lifecycle / protocol 契約整合

タスクAと独立に進められる。各項目はMCP spec 2025-06-18を一次確認してから着手。B全体の設計statusは**NOT APPROVED**: B-1はowner/state machine/deadline/replay/public state contract、B-2はprotocol policyのユーザー判断、B-3はpublic failure/observability contractをdesign gateで確定する。

1. **SDK / stdio adapterのlifecycle回復**(F7):
   - `Mcp-Session-Id`を実際に付けた要求への404だけをtransportがtyped `.sessionExpired`として報告する。session IDなしinitialize/endpoint 404はsession recoveryに分類しない。spec MUSTは新sessionのinitializeであり、元要求のreplayはproduct contractとして別に定義する。
   - ownerを`InitializedMCPClientSession or StdioAdapter`の二択で残さない。direct SDKとstdio adapterが共有する単一session-lifecycle authorityがtransport recipe、initialize context、session/transport identity、recovery、close reasonを所有する。exact target/accessはdesign gateで確定する。
   - recoveryは失敗したtransport/session identityをキーにsingle-flight化し、fresh transport + session IDなしInitializeRequest + `notifications/initialized`を実行。各logical requestのreplayは最大1回、2回目の`.sessionExpired`はsurface。SSE GETの404もsilent terminalにせず同じsession invalidation signalへ接続する。
   - public request境界でabsolute deadlineを1つ発行し、初回送信、404検知、single-flight待機、fresh initialize、notification、1回replayの全工程へremaining budgetを渡す。recoveryでtimeout budgetを再開始しない。delivery不明のside-effecting requestは自動再送しない。
   - timeout 時の `notifications/cancelled` 送出(spec SHOULD)。
   - `callTool`/`request` に per-request timeout override(spec は per-request 設定可能性を SHOULD)。
   - progress-after-return race: 最終 result complete 前に該当 token の delivery チェーンを await するか、完了時に cancel してポスト完了配送を契約上禁止。
   - session authorityをconnection stateのsingle source of truthにする。public snapshot/ordered state sequenceを候補とし、`ready / recovering / unavailable / closed`、typed terminal reason、explicit closeの終端性、recovery failure後の再試行可否、subscriber buffer/dropをdesign gateで固定する。
   - 設計契約: [design-contracts.md §1–2](design-contracts.md)。Codex analogは`openai/codex@1f0566d3`のtyped 404・single-flight・one-shotだけを参考にする。同実装はrecovery全体でdeadlineを共有せず、上位`listTools`も`next_cursor`を捨てるため、その2点の先例にはしない。
2. **protocol-version 欠如の扱い**(F8)。現状の無条件400はover-strict。**要ユーザー判断**: (a) negotiated versionへのfallbackを実装(spec準拠寄り)、(b) over-strictを意図として維持し`Docs/architecture.md:87`に「specより厳格」と明記。曖昧なまま実装しない。
3. **観測性の表面化**(F6/F8): SSE bufferの50件dropをwarningログ化、未処理server通知をdebugログ化、discovery file書込失敗を`startAndWriteDiscovery`の戻り値/例外でembedderに届ける。stale discoveryの誤分類は「recordはhint、接続が判定、標準initialize handshakeが確定」という3層を前提にする。独自handshake payload、doctor/`--check`、新規CI jobは現findingのscope外。
4. **internal batch cleanup**(F8): HTTPではbatchを400 rejectする一方、`ForwardExecutor.swift:193`のrefresh splitがarray payloadを生成する。先に内部payloadを単一message列へ正規化し、refresh splitとresponse routingのcontract testを追加する。その後にだけ`forceBatchArray`/`pendingBatches`/単一要素array分岐を削除する。

### タスク B のテスト観点

- direct SDKとstdio adapterの両方でproxy-server再起動から回復する。
- concurrent request群がsingle initializeを共有し、各requestは最大1回だけreplayされる。
- replayも404ならloopせずsurfaceし、初回attemptからのtotal deadlineを超えない。
- SSE GET 404がsession invalidationを開始し、delivery unknownのside-effecting requestを自動replayしない。
- `callTool` 返却後に `onProgress` が発火しない。

---

## タスク C(P3): 破壊的整理可の public surface 再設計

breaking changes allowed。compatibility wrapperを足さず、残すconsumer storyとcontractをdesign gateで確定してから不要surfaceを直接削除する。個別taskは独立して進められるが、削除/変更symbol・CLI flag・wire impactをcanonical designに列挙する。

1. **ProxyKit public surfaceの決断**(F5、design gate): 狭義launch-plan族は72/191 public keyword lines(~38%)。`run()`をlauncher契約としplan族をpackage降格する案をprimaryにする。plan族を契約として残す反証がある場合だけforce-restart・port検出・logging bootstrapのpublic化案と比較する。決めた後:
   - `LaunchPlan` の payload optional を `LaunchAction` の associated value 化(can't-happen guard 3 個と README の `plan.configuration!` を消す)。
   - `XcodeMCPProxyInstaller`(40 public keyword lines)のsupported consumer storyを確定し、embeddingを契約にしないならinstall executable側かnon-product targetへ。
2. **XcodeMCPProxyServer lifecycle**(F6): async `start()`をprimary contractにする。sync startのconsumer storyが不要ならdeprecated wrapperを残さず削除する。ELGのlazy化or deinit、embedder向けhealth snapshot/event streamも同じlifecycle design gateで確定する。
3. **SDK ergonomics**(F7): `XcodeMCPError`の`LocalizedError`準拠 + 「consumerが取るべき次アクション」軸での再分類(setup不備 / proxy未起動 / session断 / timeout / server error)、stale discoveryを`invalidRequest`から適切なcaseへ。`MCPContent.text(_:)`のraw合成factoryと`MCPToolResult`のtext連結accessor、`MCPJSONValue`のsubscriptとunlabeled変換init、重複する`intValue`の削除、TestRuntimeの`configuration.transport`無視の明示化と`recordedToolCalls()`公開。
   - 現行 `listTools() -> [MCPTool]` を維持するなら、`nextCursor == nil`まで同一logical deadline内で全ページ追走し、途中error/deadlineで部分catalogを返さない。既出cursorの再出現(`A → B → A`含む)はcycleとしてfail fast。raw `request("tools/list", params:)`はpage単位escape hatchのまま。この契約はdesign gateで確定する。
   - 設計契約: [design-contracts.md §1/§4](design-contracts.md)とアンチパターン節。redirect/deprecated adapterを足さず直接削除し、変更後の単一標準形をdocs/contract testへ固定する。
4. **ProxyKit public cleanup**(F5/F9): `rewriteURLFlagToStdio`を削除しcanonical flagを1つにする。`configurationFilePath: String?`は`URL?`へ統一する。非数値`--request-timeout`はrejectし、CLI contract testを更新する。外部consumerの有無は削除可否のgateにしないが、変更symbol/flagと新しい標準形はrelease note用に列挙する。

---

## タスク D(F9): internal衛生・docs整理(低リスク、いつでも)

- `PublicProductContractTests.swift:588-592` の存在しないモジュール名(`XcodeMCPCore`/`XcodeMCPProcessRuntime`)import 検査を、実 invariant(package 宣言の product client からの到達不能性)検査に書き直し。
- `setCachedToolsListResult`と`MCPForwardingService`のcacheable branchのproduction到達性をcontract testで確定し、deadなら両方削除、到達可能ならTask Aのtransaction ownerへ統合する。
- 到達不能な旧surface返却branch(`+ControlPlane.swift`の当該箇所、常にrethrow)を削除。
- docs訂正: `maintainer-architecture.md:37`(5 executable targets中2つで依存記述が偽)、`architecture.md:87`(DELETEの版header例外)、Streamable HTTP Contract節に実装の主要契約(POSTはSSEを開かない / batch 400 / SSE buffer drop / Origin検証範囲)を追記。

---

## 進め方の推奨

1. まず **タスク0(P0 Origin security)** を独立fixとして着手する。タスクAのdesign gateは並行してよい。
2. 次に **タスクAのcanonical design docとdesign gate**。blanket `CancellationError` mappingを先行投入しない。タスクB/Dは依存しない範囲で並行可能。
3. タスクCはbreaking changes allowedとしてdesign gateへ進める。compatibility承認待ちは不要だが、残すconsumer storyと削除/変更surfaceをcanonical designで確定してから実装する。
4. 各タスクは task branch に commit して SHA で受け渡す。P1 を local working tree に未コミットで積み上げない。
