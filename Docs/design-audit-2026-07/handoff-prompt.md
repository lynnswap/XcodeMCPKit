# 引き継ぎプロンプト — Design Audit 2026-07 の修正

このファイルは、監査で特定した構造問題の修正に着手するエージェント/担当者への引き継ぎ。
別セッションにそのまま貼れる自己完結プロンプトとして書いてある。着手前に `Docs/design-audit-2026-07/README.md` と、必要に応じて `evidence/` `verification/` を読むこと。

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
- Apple/Swift API・MCP spec の事実は記憶で断定せず一次情報で確認(Xcode DocumentationSearch / ios-dev-docs / Apple Developer Docs、MCP は modelcontextprotocol.io の 2025-06-18)。
- 設計契約: [design-contracts.md](design-contracts.md)(修正で採用する契約パターンとアンチパターン)。各タスクの該当節を実装前に読むこと。
- **won't-fix リスト(README「反証済み」節)に載っている項目は再修正・再指摘しない。** 特に: 旧 surface 返却 branch を「バグ」として guard 追加しない(到達不能 dead code なので削除のみ)、`proxyTabIdentifier` 合成を「第二 truth」として直さない、`?? 0` を単独で「捏造」として直さない(current-primary owner 統合の一部としてのみ扱う)。

---

## タスク A(P1・最優先): proxy runtime 制御平面の再設計

**これは対症療法ではなく構造修正。局所 guard の追加・撤回サイクルを止めるのが目的。`rearchitect` スキルの手順(現状実測 → api-design 規範に沿った目標設計 → design gate 承認 → 移行)に従う。着手前に design-audit スキルではなく rearchitect を起動する。**

### 回復すべき invariant(3 つ、これが成果の評価軸)

1. **「stale な非同期カタログ完了は書き戻さない」を型で保証する。**(F1)
   - 現状: broker generation / route-lease / activation attempt の 3 clock を call site ごとに ad hoc 合成。`recordAvailableToolsCatalog` は 5 段直列、retry timer は 6 条件。
   - 具体的欠陥(現 HEAD で再確認):
     - gate 皆無の canonical 書込バイパス `setCachedToolsListResult`(`Sources/XcodeMCPProxyKit/Internal/Session/Runtime/RuntimeCoordinator.swift` 付近、呼出し元 `MCPForwardingService.swift`)。
     - route 置換が generation を bump しない(`.syncCanonical` 経路)ことによる route-check と store-write の間の TOCTOU gap。`ProcessToolSurfaceStore.recordCatalog` は無条件書込。
     - test hook しか挟まらない production-dead な二重 generation/lease チェック(guard 順序をテストが固定している症状)。
   - 目標形(仮説、design gate で確定): 単一の「catalog transaction」型。ロード開始時に (generation, route lease, attempt) を封入し、commit 点 1 箇所でのみ合成検証して書き込む。canonical 書込 API は staleness 証明を必須引数にし、非ゲート経路(`setCachedToolsListResult`)を廃止する。

2. **broker generation の役割を分離する。**(F2、client-visible バグ)
   - 現状: `CanonicalBrokerState.generation` が init-cache 無効化・catalog 無効化・window-owner 変化通知を 1 カウンタで兼務。window/tab 変化が in-flight `tools/list` を CancellationError で落とし、ErrorMapper に CancellationError ケースが無いため client に `-32000 "upstream timeout"` が返る。
   - canonical catalog は per-process tools/list の union で window index に依存しないことは検証済み。よって owner index 変化 → catalog 無効化の接続自体が不要。
   - 目標形: 役割別 epoch に分離。owner index 変化は owner-resolution 層の再計算のみとし catalog invalidation に接続しない。
   - **先行投入可(分離を待たず単独で価値あり)**: ErrorMapper に CancellationError ケースを追加し、誤った `-32000 "upstream timeout"` ラベルを解消する。これは小さい観測性修正なので P1 本体の前に単独 commit にしてよい。

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
- `MCPForwardingService` 経路の canonical 書込が staleness gate を通る(バイパスの regression)。
- window/tab 変化が in-flight `tools/list` を失敗させない(F2 の契約化)。
- attempt owner: timeout 発火が「別 attempt の資源を殺さない」ことを、**まだ症状化していない sibling 発行 site**(secondary fallback RPC 以外)で検証。
- test-hook 依存の置換: 内部 guard 通過順序を観測する既存テストを、owner 境界の状態を観測する形へ移す(flake 修正 PR が 20 本中 5 本という症状の根治)。

### 出発点資料

- `git show 2c677e05:Docs/process-route-rearchitecture.md`(監査とほぼ同じ診断を下した、一度作られ削除された設計ノート)。
- `Docs/design-audit-2026-07/evidence/session-owner-map.md`(owner map・guard inventory G1–G5・fallback 経路)。
- `Docs/design-audit-2026-07/verification/staleness-guards.md` `generation-tripleduty.md`(load-bearing / duplicated の切り分けと失敗トレース)。
- [design-contracts.md §3](design-contracts.md)(at-most-once 分類器を 1 箇所に置く形、stale 処理の単一経路、cache 意味論の明示契約化、揮発状態の validity scope 宣言、**staleness は「検知するか明示的に disclaim するか」の二択** — 中間解を作らない)。

---

## タスク B(P2): 契約整合(spec / セキュリティ)

タスク A と独立に進められる。各項目は MCP spec 2025-06-18 を一次確認してから着手。

1. **[セキュリティ最優先] Origin 検証を全 route に適用**(F8)。現状 `/health`・`/debug/*` が免除(`HTTPHandler.swift` の `routeRequiresOriginValidation`)。spec は「all incoming connections で MUST」。loopback bind + `GET /debug/upstreams?includeSensitive=1` / `POST /debug/reset` が DNS rebinding で到達可能。Origin 検証を route 分岐の外(handleRequest 冒頭)に移す。免除が必要な route があれば理由を doc 化。
2. **SDK 側の lifecycle 回復**(F7):
   - HTTP 404 → 新 InitializeRequest で再セッション(spec MUST)。owner はセッション状態を持つ層(`InitializedMCPClientSession` or `StdioAdapter`)。proxy-server 再起動後の stdio adapter 恒久回復不能を解消。
   - timeout 時の `notifications/cancelled` 送出(spec SHOULD)。
   - `callTool`/`request` に per-request timeout override(spec は per-request 設定可能性を SHOULD)。
   - progress-after-return race: 最終 result complete 前に該当 token の delivery チェーンを await するか、完了時に cancel してポスト完了配送を契約上禁止。
   - 設計契約: [design-contracts.md §1](design-contracts.md)(到達不明を独立 case にし side-effecting は auto-resend しない、typed kind + 次アクション情報の 2 チャネル分離、LocalizedError witness 罠のテスト観点)。
3. **protocol-version 欠如の扱い**(F8)。現状の無条件 400 は over-strict。**要ユーザー判断**: (a) negotiated version への fallback を実装(spec 準拠寄り)、(b) over-strict を意図として維持し `Docs/architecture.md:87` に「spec より厳格」と明記。曖昧なまま実装しない。
4. **観測性の表面化**(F6/F8): SSE buffer の 50 件 drop を warning ログ化、未処理 server 通知を debug ログ化、discovery file 書込失敗を `startAndWriteDiscovery` の戻り値/例外で embedder に届ける。
   - 設計契約: [design-contracts.md §2](design-contracts.md)(3 層 liveness ladder =「discovery 記録はヒント、接続が判定、handshake が確定」、handshake payload に identity+version、facts-not-verdicts の死活 advisory、doctor `--check` は実処理と同一経路の途中下車)。stale discovery の誤分類(F7)の再設計はこの層構造を前提に。

### タスク B のテスト観点

- cross-origin の `/debug/upstreams` / `/debug/reset` が拒否される。
- stdio adapter が proxy-server 再起動を透過回復する end-to-end テスト。
- `callTool` 返却後に `onProgress` が発火しない。

---

## タスク C(P3): 互換方針の範囲での整理(0.x のうちに)

破壊的変更を伴うため 0.x のうちが安価。個別に独立して進められる。

1. **ProxyKit public surface の決断**(F5、**要ユーザー判断**): (推奨) `run()` を launcher 契約とし launch-plan 族(~80 decls)を package 降格 / または plan 族を契約とし force-restart・port 検出・logging bootstrap を public 化。現状は「二つの半端な story」。決めた後:
   - `LaunchPlan` の payload optional を `LaunchAction` の associated value 化(can't-happen guard 3 個と README の `plan.configuration!` を消す)。
   - `XcodeMCPProxyInstaller`(40 decls)を install executable 側か非 product target へ。
2. **XcodeMCPProxyServer lifecycle**(F6): async `start()` の追加(または sync start の deprecate)、ELG の lazy 化 or deinit、embedder 向け health snapshot / event stream の公開。
3. **SDK ergonomics**(F7): `XcodeMCPError` の `LocalizedError` 準拠 + 「consumer が取るべき次アクション」軸での再分類(setup 不備 / proxy 未起動 / セッション断 / timeout / server error)、stale discovery を `invalidRequest` から適切な case へ。`MCPContent.text(_:)` の raw 合成 factory と `MCPToolResult` のテキスト連結 accessor、`MCPJSONValue` の subscript と unlabeled 変換 init、`intValue` deprecate、`listTools` の `nextCursor` 追走 or fail fast、TestRuntime の `configuration.transport` 無視の明示化と `recordedToolCalls()` 公開。
   - 設計契約: [design-contracts.md §1](design-contracts.md)(outcome-vs-failure 分離 =「見つからなかった」を error にしない基準、staleness エラーへの provenance 埋め込み、version 不整合の case 分割)と**アンチパターン節**(文字列 substring 分類は採らない — kind は throw site で型に)。surface の名前を消す/動かす場合は §4 の typo redirect(暫定層と明示)。

---

## タスク D(F9): 衛生・整理(低リスク、いつでも)

- `Sources/XcodeMCPProxyRuntime/`(空ディレクトリ)を削除。
- `PublicProductContractTests.swift:588-592` の存在しないモジュール名(`XcodeMCPCore`/`XcodeMCPProcessRuntime`)import 検査を、実 invariant(package 宣言の product client からの到達不能性)検査に書き直し。
- `rewriteURLFlagToStdio`(dead public API)の削除 or `--stdio` の doc 化と canonical flag の統一。
- 到達不能 dead code の削除: 旧 surface 返却 branch(`+ControlPlane.swift` の当該箇所、常に rethrow)、HTTP から到達不能な batch 機構(`forceBatchArray`/`pendingBatches`)。
- docs 訂正: `maintainer-architecture.md:37`(executable 依存の記述が 2 executable で偽)、`architecture.md:87`(DELETE の版ヘッダ例外)、Streamable HTTP Contract 節に実装の主要契約(POST は SSE を開かない / batch 400 / SSE buffer drop / Origin 検証範囲)を追記。
- `--request-timeout` 非数値の silent 無視を reject に、`configurationFilePath` を `URL?` に統一。

---

## 進め方の推奨

1. まず **タスク A の design gate**(rearchitect スキル)。ここが再発の根なので最優先。F2 の ErrorMapper 修正だけは A 本体前に先行投入してよい。
2. タスク A と並行で **タスク B-1(Origin セキュリティ)** と **タスク D(衛生)** は独立に進められる。
3. タスク C は破壊的変更の合意(特に C-1, C-3)が要るので、ユーザー判断待ちの項目を先に確認する。
4. 各タスクは task branch に commit して SHA で受け渡す。P1 を local working tree に未コミットで積み上げない。
