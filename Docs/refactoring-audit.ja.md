# XcodeMCPKit リファクタリング監査と再設計案

作成日: 2026-06-12(HEAD: 862c659)

## 1. 調査方法と確度

- 12 系統の監査(Runtime / ControlPlane / Upstream / Session+DocumentationProvider / HTTPGateway / DocumentationSearch フロー追跡 / XcodeFeatures+XcodeSupport / Core+MCP / CLI・エントリポイント / 横断 / テスト / アーキテクチャマップ)を並列実行し、ユニーク指摘 **184 件** を収集。
- うち **66 件は反証レビュー済み(confirmed)**: 別エージェントが現物コード・git 履歴・Docs を読み、誤読・意図的設計・提案の副作用を潰した上で確定。**8 件は反証されて棄却**(§6 に列挙。「やってはいけないこと」として重要)。23 件は low。
- 残り 85 件はエージェントを使わず処理: 約 50 件は確定済み指摘の重複(横断監査と個別監査の二重報告)、残りの事実主張は `rg` / `git log` で直接確認した(`@_exported` の存在、`configPath` didSet のファイル I/O、`ProxyServer.run()` / `CLIParser.usage()` の呼び出しゼロ、MCPMethodDispatcher の timeout 矛盾、encode 失敗の TimeoutError 流用、`RequestTransform` の重複フィールド、Content-Length 経路が初回コミット由来であること等)。設計判断レベルの検証が残るのは §7 の 8 件のみ。
- churn 分析: 直近 60 コミット中、`RuntimeCoordinatorTests.swift` 27 回 / `HTTPHandlerTests.swift` 23 回 / `RuntimeCoordinator.swift` 16 回 / `DocumentationProvider.swift` 16 回 / `HTTPPostService+LocalHandling.swift` 11 回。直近 28 コミットはほぼすべて documentation provider 関連の `fix(proxy)`。

## 2. 全体診断

意図された層構造(ProxyCore → ProxyMCP → ProxySession → ProxyHTTPGateway)は存在し、低レベル部品(OrderedPipeReader、ProcessBackedUpstreamSession、純粋な dialog matcher など)は丁寧に書かれている。問題は層の中身で、**「不変条件に owner がいないため、補償パッチ(フラグ・再チェック・retry・同期化 semaphore)が積み上がる」** という単一の病理が全域に現れている。

churn を生んでいる構造欠陥は 3 つに集約される:

1. **DocumentationSearch のルーティング決定が 5 箇所に分散**し、gateway が provider の状態を「予測」してから誤予測をエラー型 fallback で補償している。直近 28 コミットの fix 連鎖はこの境界欠陥への対症パッチの積み重ねで、述語自体が 8ddcd27→f4e413c で行って戻る往復をしている。
2. **リクエスト実行パイプライン(lease → pending → id-mapping → send → resolve → cleanup)が 4 回再実装**され、lease/cancellation の整合が約 15 箇所の手動の対呼び出し規約で維持されている。
3. **基盤の重複**: deadline 計算が 3 つの時刻系で 5〜6 実装、JSON-RPC エラーマッピングが字句同一で 3 重複、型付きエンベロープ不在のため `[String: Any]` の id/method 手術が 12+ ファイルに散在。

加えて god object が 4 つ(`RuntimeCoordinator` 約 3,300 行/コラボレータ約 18 個、`HTTPPostService` 5 ファイル分割、`DocumentationProvider.swift` 1,172 行 7 責務、`XcodePermissionDialogAutoApprover.swift` 1,189 行 7 責務)、テストも同型の god file 2 つ(計約 15k 行、テストコードの 6 割)が本体の churn を 3 層で増幅している。

## 3. 根本原因クラスタ

### A. DocumentationSearch ルーティングの owner 不在(28 コミット連鎖の根本原因)

**現状**: 1 つの DocumentationSearch tools/call のルーティングを 5 つの owner が判断する。

1. composition root の config ゲート(`RuntimeCoordinator.swift:247-263` makeDefaultDocumentationProviderManager)
2. gateway の分類述語 `isDocumentationSearchRequest`(`HTTPPostService+LocalHandling.swift:543-562`。config 由来 bit のみ参照)
3. gateway のエラー型→fallback 写像 `shouldFallbackDocumentationSearchToUpstream`(`+LocalHandling.swift:533-541`)
4. `RuntimeCoordinator`: `documentationProviderActiveBox` + 応答本文の再 sniff + 同期 invalidation(`RuntimeCoordinator.swift:830-939`)
5. `DocumentationProviderManager`: activeProvider / selection task / invalidate+retry(`DocumentationProvider.swift:629-810`)

**確定した事実**:
- `documentationProviderActiveBox` は **書き込み専用の死に状態**(writer 4 箇所、唯一の reader `hasActiveDocumentationProvider` は f4e413c 以降到達不能分岐からしか呼ばれない)。`DisabledDocumentationProviderManager`(`DocumentationProvider.swift:46-66`)は一度もインスタンス化されたことがない(git 全履歴で確認済み)。
- `callDocumentationSearch` は **約 40 行の retry レッグを 2 回コピー**(`DocumentationProvider.swift:651-694` と `:695-731`)し、"not enabled" 判定を manager と coordinator が **同じ応答 Data を二重に parse** して実行(`RuntimeCoordinator.swift:858-867`)。
- provider のライフサイクルイベントが無関係な canonical tools catalog を `clearToolsCatalog: true` で破棄し、次の tools/list に上流 RPC を強制する(catalog は読み取り時に `DocumentationToolCatalog.applying` で都度合成する設計なのに)。
- 同一リクエストの deadline が **3 つの clock domain**(gateway: Date / coordinator: uptime-ns / manager: DispatchTime ── 注入 clock を迂回しテスト不能)と **相反する 2 つの「期限切れ」表現**(gateway は nil=期限切れ兼無期限、manager は 0=期限切れ・nil=無期限)で再計算される。
- `DocumentationProvider.swift` は 1,172 行に 7 責務同居: tools/list 書き換え(DocumentationToolCatalog)、AppKit/NSWorkspace+ps/pgrep の **同期ブロッキング** Xcode 発見(actor 上で `waitUntilExit`)、session factory、独自の JSON-RPC 相関(DocumentationProviderConnection)、NSLock+continuation 手書き待機、selection 状態機械、manager actor。

**直し方(根本)**:
- 欠けていた不変条件は「**DocumentationSearch の dispatch は ProxySession 内の単一 owner が、入口で一度だけ作られる単一 deadline を持って完結させる**」。
- `RuntimeCoordinator.callDocumentationSearch`(または専用 DocumentationSearchService)を唯一の決定点にし、戻り値を型付き outcome(`handled(Data)` / `fallbackToUpstream(reason)` / `failed(code, message)`)にする。provider 試行 → 失敗時の mcpbridge pool fallback まで内部で完結(pool への単発 tools/call 実行は `performControlPlaneRPC` として既存)。
- gateway は「tool 名による分類」だけを行い、述語 2・3 と active/inactive 分岐、エラー型 sniffing を削除。
- manager 内部は「最大 2 attempt のループ + 応答分類(ok / notEnabled / transportError / cancelled)1 箇所」に畳む。coordinator の再 sniff を削除。
- provider イベントでの canonical catalog 破棄をやめ、「mcpbridge の catalog は mcpbridge イベントだけが invalidate し、provider 状態は読み取り時に合成」を境界として固定。
- **注意(反証済み)**: provider を upstream pool に統合しない/ DocumentationProviderConnection を ProxyRouter で置換しない/ "not enabled" テキスト判定自体は mcpbridge の契約上必要(tools/list に広告されるが call は失敗する)なので削除でなく単一所有化(§6 参照)。

### B. initialize / canonical cache の split-brain

**現状**: initialize 結果が `InitializeManager.state.initResult`(`InitializeGate.swift:54`)と `CanonicalBrokerState.initializeResult`(`CanonicalBrokerState.swift:52`)の 2 箇所(+ SessionRegistry の per-session フラグ)に保持され、書き込み(`+Initialization.swift:108-112` で連続 2 呼び出し)もクリア(`startPrimaryEagerRetry` / `handleUpstreamExit` / `debugReset` / `shutdown` の 4 経路)も常に手動の対で必要。

- `ControlPlaneCoordinator.clientInitialize` と initialize waiter 一式は **本番デッドコード**(テスト `RuntimeCoordinatorTests.swift:2387-2429` のみが呼ぶ)。
- `CanonicalBrokerState` への書き込みが actor 内外 6+ 箇所に散在し、staleness 不変条件(「どの upstream 由来のキャッシュをいつ捨てるか」)が呼び出し側 3 箇所の条件式とレビュー規約で維持されている。
- `InitializeManager` は 25 のマイクロ遷移メソッドを公開し、正しい呼び出し順(prepare→sendInitialized→store→sync→finish の 5 連)がロック外の呼び出し側規約。リトライ判定は `shouldRetryEagerInitializePrimaryAfterWarmInitFailure` フラグ + ガード条件だけが違う 2 種類の consume で分散。
- `ControlPlaneCoordinator` は「共有ロード + deadline 付き waiter」を initialize / toolsCatalog / windows 用に 3 回手書き複製(約 450 行)。
- `invalidateControlPlaneSynchronously`(`RuntimeCoordinator.swift:1023-1044`)は async コンテキスト(callDocumentationSearch、upstream イベント Task)から `DispatchSemaphore.wait()` で actor 完了を待つ ── cooperative pool 枯渇時にデッドロックし得る既知アンチパターン。

**直し方(根本)**:
1. 死に経路の削除を先行: `clientInitialize` / InitializeLoadState / initialize waiter 一式、`seedToolsCatalog`、`restorePendingInitializes`、`pendingSessionIDs`(いずれも呼び出しゼロ確認済み)。
2. キャッシュ owner を 1 つに: `CanonicalBrokerState` を唯一の initialize キャッシュにし、`InitializeManager` は in-flight/pending 管理だけを持つ。クリアは 1 メソッドに集約。
3. `CanonicalBrokerState` に **generation(epoch)** を導入: 同期クリアで generation を進め、ロード完了時に開始時 generation が一致する場合のみ書き込む。これで actor 側 cleanup は fire-and-forget でよく、**semaphore.wait() を全廃**できる(maintainer-architecture.md の「同期クリア → 非同期 cleanup」契約は brokerState の同期クリアだけで満たされる)。
4. `setCachedToolsListResult` に `sourceUpstream: Int` を必須化し、staleness 判定を `controlPlane.upstreamBecameUnusable(index:)` のような単一イベントメソッドに移す。
5. InitializeManager 内のブール群を明示的な phase enum(idle → waitingForReadiness → initializeSent → notifyingInitialized → initialized)へ段階的に置換。2 種 consume フラグは「warm-init 失敗イベントを受けた回復 owner が backoff 付き再初期化をスケジュールする」形に。
6. toolsCatalog / windows の 2 系統(initialize 削除後)を汎用 SharedLoad 1 実装に統合。**注意(反証済み)**: load promotion と 2 段 deadline(waiter 個別 + RPC 全体)は意図的設計なので、統合時にセマンティクスを維持する。

### C. リクエスト実行パイプラインの 4 重実装と lease 手動規約

**現状**: 「lease 生成 → enqueueOnUpstreamSlot → registerRequestPending → activateRequestLease → assignUpstreamID → sendUpstream → resolve/cleanup」が 4 箇所にコピーされている:
`HTTPPostService+ForwardExecutor.swift:354-531`(makeTopLevelRequestFuture)/ `MCPForwardingService.swift:195-362`(callInternalTool)/ `HTTPPostService+RefreshSupport.swift:63-223`(forwardOnce)/ `RuntimeCoordinator+ControlPlane.swift:145-376`(performControlPlaneRPC。cancel+remove+abandon の cleanup 3 点セットを 4〜5 回インライン反復)。

- 終端処理(`markCompleted` × complete/fail/requeue/abandon のちょうど 1 回)が **gateway 側 約 15 箇所の手動対呼び出し**。混在 batch は 3 つの入れ子 lease を作る。
- refresh の lease 完了所有が分裂し、`usedDirectForwarding` という NIOLockedValueBox<Bool> の **サイドチャネル**で「workflow が forwarder を呼んだか」を呼び出し元へ伝えている(`+RefreshSupport.swift:290, 323-342`)。
- per-request 状態が 4〜5 ストア(ProxyRouter / UpstreamRouter / LeaseManager / HTTPPostCancellationHandle / ControlPlaneRPCHandle)に並存し、全エラー経路で協調 teardown が必要。
- `ProxyRouter` には実バグ級の指摘 2 件: (1) 重複 request id で旧 promise が fail されずに上書きされ、timeout は idKey のみ捕捉のため**新リクエストを誤殺**し得る(`ProxyRouter.swift:57-81`)。(2) `popBatch` の相関が「id 集合一致 → responseIDKeys なしの最初の batch → FIFO」と**推測 fallback** を持つ(`:203-221`。374e79d で responseIDKeys が後付けされた経緯そのものが症状)。

**直し方(根本)**:
1. ProxySession に scoped 実行 API を 1 つ(例 `withRequestLease(descriptor:) { ... }` / `executeUpstreamRPC(request:deadline:)`)。スコープの抜け方(正常/エラー/キャンセル)から終端をちょうど 1 回行うことを型で保証し、gateway から complete/fail 直接呼び出しを排除。4 フローをこの 1 本に載せ替える(accountTimeout 等の差分は引数 1 つの policy に)。
2. `RefreshForwardAttemptResult` を terminal 状態が導出可能な形にし、`usedDirectForwarding` box を削除(検証側の refined 案: forwardOnce から terminal の complete/fail だけを除去し、retry 間の requeue は残す)。
3. LeaseManager と UpstreamRouter を leaseID 主キーの単一 RequestRecord registry に統合(ProxyRouter と UpstreamSlotScheduler は対象外 ── 検証側 refined)。
4. ProxyRouter: timeout の identity を token にし、重複 id は旧 promise を明示 fail。`popBatch` は responseIDKeys 必須化で fallback 2 分岐を削除。

### D. gateway の batch 3 重分割と parse-once 違反

**現状**: `HTTPPostService.handle()`(`HTTPPostService.swift:75-305`)は 1 つの POST を逐次 3 回分割する: `filterDisabledToolCalls`(:107-214)→ `filterLocalToolCalls`(直前に自分で serialize した Data を即再 parse、:216-321)→ `refreshRequestRouting`(:617-698、再帰的に `self.handle()` を呼ぶ)。再結合は 4 つの merge ヘルパー + 二段 merge。

- 通常のホットパス(単一 forward)でも同一バイト列を **5 回 full JSON parse**(maintainer-architecture.md:52-53 の「一度だけ parse」規約に違反)。
- `forceBatchArray` ブールが約 30 シグネチャを貫通し、単一/配列の形状 3 項演算が 7 箇所に重複。
- initialize ゲートが 4 箇所で別々のエラー形状を再構築。
- 同じ method が batch 形状によって 2 つの異なる local 経路で処理される(単発 → LocalMCPResponder、batch 内 → makeToolsListBatchResponseData。XcodeListWindows は単発のみ local)。
- `HTTPPostService` は 5 ファイル分割だが 5 責務ではなく、extension 同士が相互に private 型を共有して呼び合う実質単一クラス。

**直し方(根本)**:
- 入口で 1 回だけ `[BatchItem]`(slot index / RPCID / method / toolName / raw object)へ分解し、**分類(disabled → tools/list → documentation → refresh → forward の現行優先順を固定)→ 実行 → slot へ書き戻して 1 回で組み立て** の単一パイプラインへ。3 分割関数・4 merge ヘルパー・再帰 handle()・forceBatchArray 貫通・形状 3 項演算 7 箇所が消える。
- 型付きエンベロープ(§F)を前提に、local 配信は「(method, toolName) → handler」の単一テーブルで単発/batch 共通化。
- initialize ゲートは handle() 冒頭の 1 箇所に(検証側 refined: まず共通ビルダー抽出 → ゲート統合の段階実施)。
- **注意(反証済み)**: batch 項目の直列実行は維持する(並列化提案は反証された)。

### E. sync-over-async とテスト検知分岐

**現状**(すべて確認済み):
- `String(describing: type(of: eventLoop)).contains("EmbeddedEventLoop")` で**本番ルーティングがテストインフラの型名文字列に分岐**(`+LocalHandling.swift:570-572` と `LocalMCPResponder.swift:363-365` の 2 複製)。true だと `filterLocalToolCalls` 全体をスキップし、LocalMCPResponder は semaphore ブロッキングの同期解決パスを重複実装(:367-391)。
- `invalidateControlPlaneSynchronously` / `shutdownAndWait` の DispatchSemaphore(§B)。
- actor 上の同期 subprocess: `LiveXcodeTargetDiscovery`(ps/pgrep を `waitUntilExit`、cold な初回 DocumentationSearch のリクエストパス上)、auto-approver の 250ms 毎 pgrep + 同期 AX 走査。

**直し方(根本)**: local handling を future/promise ベースの単一経路に統一し、型名 sniff・`waitForAsyncResult`・EmbeddedTestResolutionError を削除。テストは NIOAsyncTestingEventLoop / MultiThreadedEventLoopGroup で本番経路を実行。プロセス列挙は **libproc(proc_listpids + proc_pidpath)** に置換(マイクロ秒オーダーの同期呼び出しになるため protocol を sync のまま維持でき、churn 最小 ── 検証側 refined)。semaphore は §B の epoch 化で全廃。

### F. 基盤の重複(Deadline / JSON-RPC / 型なし JSON)

**現状**:
- deadline/timeout 変換が 5〜6 実装・3 時刻系(§A)。`MCPMethodDispatcher` には initialize timeout の入口が 2 つあり、`requestTimeout == 0` の解釈が矛盾する(確認済み: `timeoutForInitialize` は 0 を 60s に強制、`timeoutForMethod("initialize")` は nil=無制限を返す)。
- error→(code,message) 写像が字句同一で 3 重複: `RuntimeCoordinator.mapControlPlaneError`(:1046-1062)/ `LocalMCPResponder.mapMCPError`(:333-349)/ `HTTPPostService.mapDocumentationSearchError`(`+ResponseUtilities.swift:442-458`)。エンベロープ encode も 6+ 箇所。
- `encodeJSONRPCResultBuffer` は encode 失敗時に `throw TimeoutError()`(`RuntimeCoordinator.swift:950-952`、確認済み)── **エンコード不能も invalid response もクライアントには全部 "upstream timeout"** に見える。
- 型付きエンベロープ不在: `JSONSerialization` 参照 125 箇所、`isValidJSONObject` ガード 36 箇所、`[String: Any]` の id/method 手術が 5 モジュール 12+ ファイル(StdioAdapter 内に private mini-RequestInspector まである)。
- TOML config が 4〜5 経路で都度ディスク読み込み。**`ProxyConfig.configPath` の didSet が値型プロパティ代入のたびにファイル I/O + ログ**(`ProxyConfig.swift:29-36`、確認済み)。

**直し方(根本)**:
1. ProxyCore に単一の `Deadline` 値型(uptime-ns、ClockClient 注入、`remaining() -> TimeAmount?`(nil は「無期限」のみ)+ `hasExpired`)。HTTP 入口で 1 回生成し、gateway → coordinator → manager → connection に値で受け渡す。enforcement は最内層のみ。
2. ProxyMCP に typed envelope(items + wasBatchArray + per-item の method/toolName/id。raw 保持で byte-faithful passthrough を保証)と単一の JSON-RPC response encoder。
3. エラー写像は **`RuntimeCoordinator.mapControlPlaneError` を正本に一本化**(ProxyMCP へは移さない ── 写像対象のエラー型が ProxySession 在住で、ArchitectureTests が ProxyMCP→ProxySession import を禁止しているため。検証側 refined)。`TimeoutError` 流用をやめ、EncodingFailure / InvalidUpstreamResponse / UpstreamUnavailable を区別する語彙に。
4. TOML は composition root で 1 回 decode して不変値として配布。didSet の I/O を削除。

### G. モジュール境界の形骸化

**現状**(主要なものは検証済み):
- **ProxySession が AppKit / ApplicationServices を直接 import**: `DocumentationProvider.swift:1`(NSWorkspace)と `UpstreamReadinessGate.swift:129-241`(XcodeReadinessProbe の AX ウィンドウ列挙)。maintainer-architecture.md は「Xcode window inspection は ProxyXcodeSupport 所有」と明記。Xcode プロセス発見は 3 モジュールに 3 実装。
- composition root(XcodeMCPProxy、「composition root only」と文書化)に xcrun フラグ文法の知識(`ProxyServer.swift:300-386`。`+Readiness.swift:132-165` と同一アルゴリズムの重複)と TOML 再 parse(:388-400)。
- `@_exported import ProxyCore` / `ProxyStdioTransport`(`XcodeMCPProxyExports.swift:1-2`、確認済み)が ArchitectureTests の import 行スキャンを骨抜きにしている。
- CLI 引数が 3 つの独立文法(InvocationScanner のフラグ表 → env を文字列フラグに合成 → CLIParser が再トークン化)を通る。env 既定値も 2 層で重複。
- `ExistingProxyServerClient`(375 行の lsof/ps/kill + Thread.sleep ポーリング)が ProxyCore に在住、消費者は ProxyCLI のみ。
- 220 行の Xcode chat client-version 解決(UserDefaults 走査)が `RuntimeCoordinator+Initialization.swift:386-607` に同居し、全関数が static + instance wrapper の 2 重定義。initialize params 既定値が DocumentationProviderManager と重複。
- 1 行の `XcodeMCPKit` ライブラリ target は import 実績ゼロ(確認済み)。

**直し方(根本)**: Xcode プロセス/ウィンドウ探査(libproc 化した discovery + AX probe)を ProxyXcodeSupport の 1 実装に集約しクロージャ/protocol 注入で ProxySession へ(seam は既存)。ArchitectureTests に「ProxySession で AppKit/ApplicationServices import 禁止」を追加。chat-version 解決は純関数として ProxyCore 側へ移し instance wrapper 12 個を削除。`@_exported` を削除して実 import を宣言し、ArchitectureTests を実態と一致させる。CLI はコマンドごとに 1 回 parse する宣言テーブルへ。ExistingProxyServerClient は ProxyCLI へ移動。XcodeMCPKit target は外部消費者がいなければ削除。

### H. 命名の二重化と死蔵コード

**現状**(削除候補はすべて呼び出しゼロを rg / git 履歴で確認済み):
- **5 つの中核型が 2〜3 重名**: ファイル名=旧名、型名=新名(`SessionStore.swift`→SessionRegistry、`InitializeGate.swift`→InitializeManager、`RequestLeaseRegistry.swift`→LeaseManager、`ResponseCorrelationStore.swift`→UpstreamRouter、`UpstreamSelectionPolicy.swift`→UpstreamHealthManager)+ `RuntimeCoordinatorCollaborators.swift` の typealias 5 本 + 旧名 accessor 2 本。commit 3c5ca62 の rename が未完遂。
- 死蔵: `ToolsListFilter.swift`(後継 RefreshCodeIssuesToolsListRewriter に置換済み)、`DisabledDocumentationProviderManager`、`seedToolsCatalog`、`restorePendingInitializes`、`pendingSessionIDs`、`clientInitialize` 一式、`ProxyServer.run()`、`CLIParser.usage()`(廃止済み単一バイナリ文法を説明)、scheduler の capacity モデル(write-only)、`startImmediately`、`sendResponseData`、`requestIDs(from:)`、`callInternalTool` wrapper、`sharedXcodeListWindowsResult` の捨てられる maxAge、pinning 残骸(`chooseUpstreamIndex(sessionID:shouldPin:)` は両引数無視なのに約 15 テストが pinning 挙動を期待して呼ぶ=**カバレッジの錯覚**、空 no-op の `testSetInitializeRoutingState`、常時 nil の TestSnapshot フィールド)。

**直し方**: 一括削除 commit + rename 完遂 commit(機械的・無挙動変更)。pinning 残骸の削除時は、該当テストを現行セマンティクスに対する検証へ書き直す。

### I. upstream / runtime の状態機械が暗黙

**現状**:
- `UpstreamSelectionPolicy.swift` の実体は `UpstreamHealthManager`: init lifecycle + health/quarantine + probe 簿記 + tools/list カウンタ + round-robin を約 25 のロック包みミューテータで公開する状態ストアで、**lifecycle の意思決定(restart/retry/timeout/probe 発火)は RuntimeCoordinator の extension 群が遠隔操作**している。
- readiness/init-retry 状態が 4 owner(readiness actor / RuntimeCoordinator の lock box 2 個 / health manager / InitializeManager)に分散し、actor-hop の順序非決定を generation カウンタで補償。
- `UpstreamSendResult` が `.accepted` / `.overloaded` の 2 値で、**shutdown・start 失敗・終了・claim 喪失がすべて .overloaded に erasure** され、誤った health 遷移と専用の overload-recovery ladder を生んでいる(全引用行確認済み)。
- scheduler が自ロック内で health manager のロックを取る closure を実行(ABBA は現状ないが規約頼み)。
- extension 分割は責務と無関係(warm-init が +Health、init-retry が +UpstreamRouting、UserDefaults 走査が +Initialization)。

**直し方(根本)**:
1. `UpstreamSendResult` に原因を持たせる: `accepted / backpressure / unavailable(reason)`。health 遷移は backpressure のみ degraded 扱い。
2. UpstreamHealthManager 内を InitPhase enum + UpstreamHealthState の明示遷移(`apply(event:) -> [Effect]`)へ。**単一ロック所有は維持**(選択判断が init/health/probe を原子的に読むため。actor 化はしない ── 検証側 refined、文書化された「同期クリア」契約とも整合)。
3. readiness は actor をやめ lock ベースの final class にして登録/リセットの順序不変条件を回復し、generation 補償を削除(検証側 refined)。
4. scheduler の `canUseUpstream`/`selectUpstream` を純クエリ化し、probe 起動は data として返して lock 外で実行。
5. **注意(反証済み)**: RuntimeCoordinator を UpstreamLifecycle / ControlPlaneClient に全面分割する案は「routing↔health が本質的に双方向結合」のため棄却。スコープは上記の局所的 owner 化に留める。chat-version 抽出(§G)と死蔵削除(§H)だけでも本体は大幅に縮む。

### J. テスト構造が churn を増幅

**現状**:
- god file 2 つで全テストコードの約 6 割: `RuntimeCoordinatorTests.swift` 7,445 行(142 テスト、最低 8 ユニット混在、`@Suite(.serialized)`)、`HTTPHandlerTests.swift` 7,618 行(97 テスト)。
- `TestRuntimeCoordinator`(約 800 行)が **RuntimeCoordinating 約 40 メソッドの幅ゆえに本番ルーティング意味論を再実装**し、3 世代の responder API を併存。production 修正のたびに fake も追従。
- white-box 結合: Mirror reflection で private 3 層を掘る、quarantine 閾値 3 をテスト側にハードコード(`markRequestTimedOut` 3 連打が 5 箇所)、`*ForTests` ミューテータ、初期化ハンドシェイク 10〜15 行の儀式が約 50〜59 回コピー、絶対 send-index への厳密一致 assert。
- wall-clock 依存: `staysTrue(200-250ms)` 13+ 箇所、生 `Task.sleep` 16 箇所、promotion 競争を 120ms sleep で誘発。decision-policy(UpstreamHealthManager / ControlPlaneCoordinator / DocumentationSearch routing / RefreshCodeIssuesWorkflow の純ヘルパー)に**直接単体テストがゼロ**。
- target 名が rename に追従していない(`ProxyHTTPTransportTests` が ProxyHTTPGateway をテスト、`ProxyRuntimeTests` が ProxySession をテスト、`ProxyIntegrationTests` は実態 unit テスト)。`XcodeMCPTestSupport` が Sources/ の通常 target として本番ビルドグラフに入っている。

**直し方**: unit-under-test 単位でファイル分割し、共有ハーネス(HTTP サーバ 1 / scripted upstream fake 1 / JSON ビルダー 1 式)を XcodeMCPTestSupport(Tests/ 配下へ移動)に集約。決定的 clock(TestClock は既存)を本体の未注入 delay(promotion 100ms、readiness backoff、prewarm)へ通し、staysTrue/sleep を置換。`RuntimeCoordinating` の分割(§C/§D 後)に合わせて fake を縮退。ControlPlaneCoordinatorTests / UpstreamHealthManagerTests / DocumentationSearch routing の table-driven テストを新設。

## 4. 段階的リファクタリング計画

各フェーズは独立に `swift test` green で出荷可能。順序は「リスク低減 ÷ 工数」の降順。フェーズ内の見出しは 1 PR 単位の目安。

### Phase 0: 挙動固定(以降の全フェーズの保険)
1. DocumentationSearch ルーティングの現行挙動を固定する table-driven テスト(provider あり/なし、cold、batch 混在、fallback、cancellation)を、可能な範囲で既存 E2E から抽出・整理。
2. ControlPlaneCoordinator 直接テスト新設(fake loader + TestClock。waiter dedup / deadline / cancel / prewarm / invalidation)。
3. UpstreamHealthManager(現 UpstreamSelectionPolicy.swift)の閾値・quarantine・回復の直接テスト新設。
- 効果: 以降のフェーズの安全網。god テストへの追記をここで止める。

### Phase 1: 削除とリネーム(無挙動変更・即日可能)
1. 死蔵コード一括削除(§H のリスト全部 + `documentationProviderActiveBox` 一式 + `allowInactiveProvider` + `hasActiveDocumentationProvider`)。pinning 系テストは現行セマンティクスへ書き直し。
2. rename 完遂: typealias 5 本と旧名 accessor を削除、5 ファイルを型名に改名。
3. テスト target 名の整合(ProxyHTTPTransportTests → ProxyHTTPGatewayTests 等)と XcodeMCPTestSupport の Tests/ 配下への移動。
- 効果: 以降の全フェーズの対象コードが物理的に減る。ナビゲーションコスト恒久減。リスク: ほぼゼロ(全削除対象は呼び出しゼロ確認済み)。

### Phase 2: DocumentationSearch 単一 owner 化(止血 ── 最優先の挙動変更)
1. `Deadline` 値型を ProxyCore に導入し、documentation 経路(gateway → coordinator → manager → connection)に通す。2 つの「期限切れ」表現と DispatchTime 直呼びを排除(manager がテスト可能になる)。
2. manager 内 retry を「最大 2 attempt ループ + 分類 1 箇所」へ。coordinator の応答再 sniff を削除し、型付き outcome(`handled` / `fallbackToUpstream` / `failed`)を返す契約に変更。
3. gateway の `shouldFallbackDocumentationSearchToUpstream` と provider 状態予測を削除し、tool 名分類だけ残す。fallback は owner 内部で `performControlPlaneRPC` 経由に。
4. provider イベントでの canonical catalog 破棄(`clearToolsCatalog: true`)を停止。
5. `LiveXcodeTargetDiscovery` の ps/pgrep を libproc に置換(actor 上のブロッキング解消)。
- 効果: 28 コミット級の fix 連鎖を構造的に再発不能にする。リスク: 中。Phase 0-1 のテストとルーティング matrix が安全網。

### Phase 3: initialize/control-plane の所有権統一と semaphore 全廃
1. `CanonicalBrokerState` に generation を導入し、`invalidateControlPlaneSynchronously` の semaphore を削除(async 呼び出し元は await、イベント経路は同期クリア + fire-and-forget)。`shutdownAndWait` も async 化。
2. initialize キャッシュを CanonicalBrokerState に一本化。InitializeManager は in-flight/pending のみに縮退し、phase enum 化(段階実施)。
3. `setCachedToolsListResult` の source 必須化と invalidation の単一イベントメソッド化。
4. toolsCatalog / windows の waiter 機構を汎用 SharedLoad 1 実装へ(promotion セマンティクス維持)。
- 効果: 「キャッシュを 2 箇所同時に消し忘れる」class のバグが構造的に消える。デッドロックリスク除去。

### Phase 4: gateway パイプライン一本化
1. ProxyMCP に typed envelope を導入し、`handle()` 入口で 1 回 parse した `[BatchItem]` を全層に通す(parse-once 規約の実装化)。
2. 分類 → 実行 → 組み立ての単一パイプライン化。3 分割関数・4 merge・再帰 handle()・forceBatchArray 貫通を削除。local 配信の単発/batch 統一。initialize ゲート 1 箇所化。
3. EmbeddedEventLoop 型名 sniff と semaphore 同期パスを削除し、テストを NIOAsyncTestingEventLoop / MTELG へ移行。
4. scoped lease API(`withRequestLease`)を導入し、4 重 forward パイプラインを 1 本へ。`usedDirectForwarding` 削除。ProxyRouter の重複 id / popBatch fallback 修正。
- 効果: HTTPPostService の 5 ファイル 2,674 行が概ね半減見込み。lease 漏れ/二重終端が型で不能に。リスク: 高(最大の挙動面)。HTTPHandlerTests の儀式統一(§J)を先に済ませると差分が読める。

### Phase 5: モジュール境界の回復
1. Xcode プロセス/ウィンドウ探査を ProxyXcodeSupport の 1 実装に統合し、ProxySession から AppKit/ApplicationServices を排除 + ArchitectureTests に禁止ルール追加。
2. chat-version 解決を純関数化して移動、instance wrapper 12 個削除、initialize params 既定値の一本化。
3. TOML 1 回読み込み(didSet I/O 削除)、CLI 宣言テーブル化(3 文法 → 1)、env 解決 1 箇所化。
4. `@_exported` 削除と実 import 宣言、ExistingProxyServerClient を ProxyCLI へ、composition root の xcrun ロジックを ProxyXcodeSupport へ、XcodeMCPKit target 削除(外部消費者なしの場合)。
- 効果: 文書と実態の一致。ArchitectureTests が再び意味を持つ。

### Phase 6: upstream 状態機械の明示化
1. `UpstreamSendResult` の原因付き 3 値化と health 遷移の修正。
2. UpstreamHealthManager の InitPhase enum + `apply(event:) -> [Effect]` 化(単一ロック維持)。
3. readiness の lock-based class 化と generation 補償の削除。
4. scheduler の純クエリ化(probe は data で返す)。
- 効果: 「どの障害で何が起きるか」が 1 ファイルの遷移表になる。

### Phase 7: XcodeFeatures / XcodeSupport の整理
1. `runProxyRefresh` の fallback 7 連コピーを `Result<Data, FallbackReason>` + 出口 1 箇所へ。
2. refresh の認識ロジックを feature 側の failable init に集約(gateway の 2 コピー削除)。4 closure を per-request の transport bundle struct に(closure seam 自体は ArchitectureTests が強制する設計なので維持)。
3. auto-approver: 1,189 行を既存 seam で 4 ファイルに分割(Snapshot / Matcher / LiveAXClient / Approver)、7 段ヒューリスティックを evidence + 順序付き rule table に、eligibility ポリシーの 2 重定義を共有定数に、per-tick pgrep を libproc + NSWorkspace 通知に。
4. debug step/state/outcome の enum 化。
- 効果: セキュリティ感応な自動クリックの判定が監査可能になる。

### Phase 8: テスト再編(各フェーズと並走可)
- god file の unit 分割、共有ハーネス統合、handshake fixture 化(約 1,500〜2,000 行削減見込み)、wall-clock 排除、`.serialized` の限定、`RuntimeCoordinating` 縮退に伴う fake 縮小。

## 5. 目標アーキテクチャ(要点)

- **状態の正本を 1 箇所に**: provider 可用性 = DocumentationProviderManager のみ / initialize 結果 = CanonicalBrokerState のみ / リクエスト lifecycle = RequestRecord registry のみ / config = 起動時 1 回の不変値。
- **決定を 1 箇所に**: DocumentationSearch ルーティング = ProxySession の単一 entry point / batch 分解・組み立て = gateway の単一パイプライン / エラー写像 = 1 関数 / deadline = 1 型。
- **境界を機械的に強制**: ArchitectureTests を @_exported 非依存にし、AppKit 禁止ルールを追加。
- **新しい層は作らない**: 本計画の大半は「削除・統合・所有権移動」であり、新規抽象は `Deadline` 値型、typed envelope、scoped lease API、SharedLoad の 4 つだけ。いずれも既存重複 5〜6 実装の置換。

## 6. やってはいけないこと(反証済み提案)

監査で出たが反証レビューで**棄却**された案。将来同じ発想が出たときの参照用:

1. **DocumentationProvider を upstream pool(ManagedUpstreamSlot)に統合する** ── per-Xcode-PID ピン留め・機能 probe・候補ランキング・意味論的 invalidation は固定数 pool 機構に owner がなく、統合はかえって複雑化する。別スタックのまま owner を 1 つにするのが正解。
2. **DocumentationProviderConnection の相関機構を ProxyRouter で置換する** ── 要件が異なり「既存があるから再利用」は成立しない。
3. **"not enabled" の応答テキスト判定を廃止する** ── mcpbridge は tool を無効でも tools/list に広告するため、テキスト判定が唯一の検出手段(テストで挙動固定済み)。廃止でなく実行箇所の一本化が正解。
4. **load promotion 機構を「補償パッチ」として削除する** ── N:1 waiter 共有設計の意図的な一部。SharedLoad への統合時もセマンティクス維持。
5. **per-waiter deadline と per-RPC timer の 2 段 deadline を単層化する** ── 意図的設計(prewarm と dedup のため)。
6. **batch 項目の直列処理を並列化する** ── 共有 deadline 下の直列処理は意図された挙動。
7. **sendUpstream の Task-per-send を「fire-and-forget で危険」と直す** ── アーキテクチャの誤読。
8. **ControlPlaneRPCHandle を「4 重クリーンアップの温床」として全面再設計する** ── 主張の根拠となった履歴解釈が誤り。performControlPlaneRPC 側の cleanup 反復削減(§C)に留める。

## 7. 検証残件(設計判断が必要な 8 件)

機械的検証では白黒つかず、**該当フェーズの実装着手時に検証するのが最も安い**項目。事前に個別エージェントを立てる必要はない:

1. **StdioFramer の Content-Length 読み経路の削除可否**(§F)── 初回コミット由来の防御的実装で、fix 対応の追加ではない。削除前に mcpbridge の実 stdout を 1 回実測する(Phase 4 以降の任意時点)。
2. **StdioFramer の再パース効率**(append ごとの全バッファ再走査疑い)── 性能計測してから判断。正しさの問題ではない。
3. **RuntimeCoordinating の protocol 分割粒度**(消費者別 2〜3 protocol 案)── Phase 4 の scoped lease API 導入後に必要な表面が確定してから。
4. **RefreshCodeIssuesCoordinator の二重同期層**(actor + per-waiter lock-box)の解消 ── Phase 7 で。
5. **ProxyServer の RuntimeHolder 削除**(bind 前に Runtime 生成)── Phase 5 で。
6. **CLI 3 文法の単一 parse 統合**の互換性 ── 既存の quirk が挙動契約になっていないか、Phase 5 で確認。
7. **ProxyCore→ProxyMCP 依存の解消**(TOML を Decodable 化し shaping を ProxySession へ)── Phase 5 で。
8. **ControlPlaneCoordinator の SharedLoad 汎用化**が promotion セマンティクスを保てるか ── Phase 3 で Phase 0 のテストを通して確認。

## 8. 付録: 確定指摘の severity 別件数

| 領域 | high | medium | 主な対象 |
|---|---|---|---|
| doc-routing / session-docs | 7 | 9 | DocumentationProvider.swift, +LocalHandling |
| runtime | 4 | 6 | RuntimeCoordinator 一族 |
| control-plane | 4 | 4 | ControlPlaneCoordinator, InitializeGate |
| http-gateway | 4 | 5 | HTTPPostService 5 ファイル |
| upstream | 4 | 4 | HealthManager, ReadinessGate, Scheduler |
| xcode-features/support | 5 | 6 | RefreshWorkflow, AutoApprover |
| 横断・基盤・CLI・テスト | (未検証 85 件の大半。本文に手動裏取り済みのもののみ採用) | | |

低優先(low)23 件と未検証残件の全文は監査生データに残っている。再検証や個別の deep-dive が必要になったら指示してほしい。

## 9. 実施状況(2026-06-13 更新)

ブランチ `refactor/structural-cleanup` にて Phase 1〜3 完了、Phase 4〜7 の確定済み項目を実施済み(全コミットで `swift test` + process テスト green)。

実施済み: 死蔵コード削除・rename 完遂・テスト target 整合(Phase 1)/ DocumentationSearch 単一 owner 化・Deadline 型・libproc 化(Phase 2)/ generation 導入による semaphore 全廃・initialize キャッシュ一本化・source 必須化(Phase 3)/ ProxyRouter の相関厳密化(重複 id・popBatch 推測排除)・エラー写像一本化・initialize ゲート一本化・metadata 二重パース解消(Phase 4 部分)/ handshake params 抽出・config 1 回読込・@_exported 排除と境界実体化・XcodeMCPKit target 削除・ExistingProxyServerClient 移動・xcrun 文法統合(Phase 5 部分)/ UpstreamSendResult 原因付き 3 値化(Phase 6 部分)/ refresh fallback 7 連コピー統合・lease 終端単一 owner 化・認識ロジック feature 集約・pgrep 全廃・auto-approver 4 ファイル分割(Phase 7 部分)。

第 2 ラウンド(同ブランチ continued)で追加実施: ProxyRouter 相関の厳密化(重複 id の token 照合・popBatch 推測排除)/ UpstreamSendResult の原因付き 3 値化 / エラー写像・initialize ゲート・upstream-unavailable 応答の単一ビルダー化 / refresh の lease 終端単一 owner 化(usedDirectForwarding 削除)・fallback 7 連コピー統合・認識ロジック feature 集約・outcome の enum 化 / handshake params・xcrun 文法・TOML 読込・env 解決の単一所有化 / @_exported 排除と ProxyCLI 境界実体化(ArchitectureTests は属性付き import も検査)/ XcodeMCPKit target 削除・ExistingProxyServerClient 移動 / pgrep・ps の subprocess 全廃(共有 ProcessEnumeration)/ auto-approver 4 ファイル分割 + matcher の evidence+順序ルール化 / **AppKit・ApplicationServices の ProxySession 完全排除**(ProcessRunner・OrderedPipeReader・UpstreamReadinessGate・XcodeTargetDiscovering を ProxyCore へ、XcodeReadinessProbe・LiveXcodeTargetDiscovery・live gate factory を ProxyXcodeSupport へ移し、composition root から注入。Architecture ルールで再発防止)/ shutdownAndWait をテストサポートへ移動(本番の DispatchSemaphore は EmbeddedEventLoop 互換パスの 1 箇所のみに)/ ControlPlaneCoordinator の waiter 除去 4 関数 → 2 関数(toolsCatalog/windows の完全汎用化は、ポリシー差が実在する 2 インスタンスのための投機的抽象になるため見送り)/ flaky だった refresh coordinator テストの決定化 / dry-run 出力を解決済み config 由来に変更。

第 3 ラウンドで追加実施: **batch 分類の単一パス化**(`routeToolCalls` — disabled / tools-list / documentation / forward を 1 ループで分類。filterDisabledToolCalls→filterLocalToolCalls の 2 パスと中間 serialize→reparse を削除し、無加工リクエストは原文バイトのまま forward = parse-once 規約の回復。本体をパラメータ渡しでなく関数内パースにすることで、派生グループが disconnected region となり strict concurrency 下で Task へ転送可能 — これが歴史的な再パースの正体だった)/ **EmbeddedEventLoop 型名 sniff の全廃**(同期解決は呼び出し側の制約なので `usesSynchronousLocalResolution` の明示 opt-in に変更。Embedded テストヘルパー 2 箇所だけが true を渡し、Sources/ から EmbeddedEventLoop への言及が消えた)。

第 4 ラウンドで追加実施: **refresh 再帰の除去**(`executeRefreshRoute` — 分類済みの pure refresh 呼び出しに対する handle() 再入はゲート再実行がすべて no-op のため、lease/cancellation の振り付けを直接実行に置換。remainder の単一再入は refresh 抽出済みのため構造的に深さ 1 で有界、コメントで明文化)/ **god テストファイル 2 つの分割**(RuntimeCoordinatorTests 7,279 行 → 4,639 + DocumentationProviderTests 1,168 + UpstreamReadinessTests 495 + 共有 TestSupport 1,011。HTTPHandlerTests 7,575 行 → 2,244 + RefreshCodeIssuesHTTPTests 2,593 + DocumentationSearchRoutingTests 1,158 + DisabledToolHTTPTests 488 + TestSupport 1,157。いずれも同一 @Suite の extension 分割のため .serialized 実行意味論は完全保存)。

意図的に見送り(判断記録):
1. **slot ベースの応答組み立て**(merge ヘルパー群と forceBatchArray の全面置換)— 単一分類パスと再帰除去が着地した時点で、元指摘の構造問題(3 重分割・無制限再帰・多段 merge)は実質解消。残る merge は「並列 fallback 波」という本質的に並行な合流のみで、slot 化は応答の並び順を変えるため exact-wire テスト群と衝突する。並び順変更込みの全面リライトはリスクが利得を上回ると判断。
2. **handshake 儀式 約 59 箇所の fixture 化** — 各儀式はヘッダ・Accept・session id・payload が微妙に異なり機械変換が安全にできない。既存ヘルパー(initializeHTTPChannel / postJSON)は TestSupport に公開済みで、新規テストはそれを使えばよい。既存テストの一括書き換えは挙動検証価値ゼロの大量 churn のため見送り。
