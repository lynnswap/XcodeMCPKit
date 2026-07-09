# XcodeMCPKit / XcodeMCPKitTesting public API 監査証拠

## 1. Public surface 全列挙(確認済み事実)

ソース: `rg '^\s*public '` + 全ファイル読解。Package.swift は `.defaultIsolation(nil)`(= nonisolated デフォルト)+ `.swiftLanguageMode(.v6)` + `.strictMemorySafety()`(Package.swift:6-10)。macOS 15.4+(Package.swift:14-16)。

### XcodeMCPKit (5 ファイル、public 型は 8)

**`XcodeMCP`** — `public actor`(XcodeMCP.swift:183)、`isolated deinit` が Task 経由で session.close()(XcodeMCP.swift:254-259)。
- `init(configuration: XcodeMCPConfiguration = .init()) async throws`(196)— connect+initialize+`notifications/initialized` を完了してから返る。失敗時 transport close 済みで rethrow(doc 189-193)。
- `listTools() async throws -> [MCPTool]`(266)
- `callTool(_ name: String, arguments: [String: MCPJSONValue] = [:], onProgress: (@Sendable (MCPProgress) async -> Void)? = nil) async throws -> MCPToolResult`(289)
- `request(_ method: String, params: MCPJSONValue? = nil) async throws -> MCPJSONValue`(337)— result 欠落時 `.null` を返す(セッション実装 InitializedMCPClientSession.swift:318)
- `notify(_ method: String, params: MCPJSONValue? = nil) async throws`(353)
- `close() async`(366)— 冪等、pending は `XcodeMCPError.closed` で失敗(doc 361-365)

**`XcodeMCPConfiguration`** — `struct Equatable Sendable`(XcodeMCP.swift:9)。プロパティ: `transport`, `clientName`, `clientVersion`, `capabilities: [String: MCPJSONValue]`, `requestTimeout: Duration?`(103-121)。デフォルト: `.localBridge()`, "XcodeMCPKit", "dev", `[:]`, `.seconds(60)`(133-139)。
- 入れ子 `Transport`: struct + `package Storage` enum + static factory(`localBridge(_:)` 68, `streamableHTTP(endpoint:)` 73, `streamableHTTP(discoveryFile:)` 82, `streamableHTTPProxyDiscovery(environment:)` 95)。struct-with-factories 形式で将来 case 追加が非破壊 — 良設計。
- 入れ子 `Bridge`: **public enum**(11)`.defaultMCPBridge` / `.custom(command:arguments:environment:)`。consumer が exhaustive switch 可能 → 将来 case 追加は source-breaking(小リスク)。デフォルト実体は `/usr/bin/xcrun mcpbridge`(MCPBridgeInvocation.swift:16-25)。

**`MCPTool` / `MCPContent` / `MCPToolResult` / `MCPProgress`**(MCPDomainTypes.swift:8/64/111/181)— 全て `Codable Equatable Sendable`、typed プロパティ + `raw: MCPJSONValue` 保持のハイブリッド。encode は raw をベースに typed プロパティで上書き(340-393)。
- `MCPContent` は enum: `.text(String, raw:)` `.image(data:mimeType:raw:)` `.resource(uri:text:mimeType:raw:)` `.raw(_)`。**全 case が `raw:` 必須で default 不可**。
- `MCPProgress.progressToken: String`(183)。decode は progressToken 欠落で `invalidResponse` throw(227-233)。`MCPProgress(json:)` は stringValue 必須(324-337)— MCP spec 2025-06-18 では progressToken は string または integer 可(spec basic/utilities/progress)。クライアント自身は string token を生成する(InitializedMCPClientSession.swift:136)ので自己完結的には整合、ただし public Codable 型として integer token payload を decode すると throw する。

**`MCPJSONValue`** — enum 7 case(object/array/string/integer(Int64)/double/bool/null)、`Codable Equatable Sendable`(MCPJSONValue.swift:18-38)。6 literal conformance(129-169)。Bridging: `init(jsonObject: Any) throws`(91)、`init<T: Encodable>(encoding:) throws`(113)、`var jsonObject: Any`(124)。Accessor: `objectValue/arrayValue/stringValue/boolValue/integerValue/intValue/doubleValue/isNull`(173-223)。
- Equatable は合成(`static func ==` なし、rg で確認)→ `.integer(1) != .double(1.0)`。`doubleValue` は integer も Double 化する(209-218)が `==` はしない。
- **`intValue` は `integerValue` の完全な複製で両方 Int64**(197-205)。README は `intValue` に言及せず(README.md:105-106)。needless synonym + `intValue: Int64` という命名は誤解を招く。

**`XcodeMCPError`** — `enum Error Equatable Sendable`、6 case: `closed` / `invalidRequest(String)` / `invalidResponse(String)` / `requestTimedOut(method:)` / `serverError(code:message:data:)` / `transportUnavailable(String)`(XcodeMCPError.swift:9-36)。**`LocalizedError` / `CustomStringConvertible` 非準拠**(rg で全 Sources 確認、準拠ゼロ)。

### XcodeMCPKitTesting (1 ファイル)

**`XcodeMCPTestRuntime`** — `public actor`(XcodeMCPTestRuntime.swift:10)。入れ子: `RecordedMessage`(12)、`ToolCall`(45)、`ProgressUpdate`(73)、`ServerError`(101、デフォルト code -32000)。typealias: `ToolHandler`(119)、`RequestHandler`(124)。
- `init(tools: = [defaultDocumentationSearchTool], initializeResult: = defaultInitializeResult)`(145)
- `makeClient(configuration:) async throws -> XcodeMCP`(158)— package init `XcodeMCP(configuration:transport:)` に fake transport を注入(163)。**`configuration.transport` は無視される**(silent)。
- `setTools` / `setToolResult(_:forToolNamed:)` / `setToolHandler` / `setRequestHandler(_:forMethod:)` / `setProgressUpdates(_:forToolNamed:)`(167-209)
- `recordedMessages()` / `recordedCloseCount()`(212-219)、`emitServerRequest(method:id:params:)`(226)
- static `defaultInitializeResult`(405、protocolVersion "2025-06-18" = MCPProtocolVersion.current と一致、MCPProtocolVersion.swift:4)、`defaultDocumentationSearchTool`(415)
- fake transport `XcodeMCPTestTransport` は package(429)。プロダクションと同じ `InitializedMCPClientSession` data flow を通す設計 — fake が下位層に置かれており健全。

## 2. 設計評価(Guidelines / Apple analog 照合)

**良い点(確認済み)**:
- lifecycle 契約が明確: throwing async init = connect+initialize(XcodeMCP.swift:189-193)、close 冪等(361-365)、deinit safety net(254-259)。README「Create one XcodeMCP per MCP session」(Sources/XcodeMCPKit/README.md:150-156)と一貫。
- 命名は概ね guideline 準拠: `xcode.callTool("X", arguments:)` は自然に読める。`request(_:params:)`/`notify(_:params:)` の escape hatch は doc コメントで責務境界(framing/id/timeout はクライアント所有)を明記(XcodeMCP.swift:322-336, 344-352)。
- raw 保持ハイブリッド型(typed + `raw`)は動的 tool catalog という前提に合致し、encode 時に raw を保全(MCPDomainTypes.swift:340-393)。
- progress 配送は token ごとに直列化(前の delivery を await、InitializedMCPClientSession.swift:328-338)。
- capabilities の roots/sampling/elicitation 除去は README(146-148)と doc comment(XcodeMCP.swift:111-116)で明記(silent drop だが文書化済み)。

**問題点(確認済み事実、以下 3 節に集約)**。

## 3. README ドリフト検査

Sources/XcodeMCPKit/README.md の全コード例(Quickstart 33-61、streamableHTTP 66-94、escape hatch 114-131、Testing 163-186)と Sources/XcodeMCPKitTesting/README.md(10-54)を実シグネチャと照合した。**ドリフトなし — 全例が現行シグネチャでコンパイル可能と判断**(trailing closure → optional `onProgress` は合法、dictionary literal → MCPJSONValue は contextual type で解決、`setRequestHandler({...}, forMethod:)` は sync closure が async typealias を満たす)。ルート README にはクライアントコード例なし(rg で確認)。

ただし README 例自体が API の摩擦を露呈している: MCPToolResult 構築で同じテキストを typed と raw に二重記述(Sources/XcodeMCPKit/README.md:170-174、Sources/XcodeMCPKitTesting/README.md:18-24)。

## 4. Consumer story での摩擦点

### Story (a): Mac app — listTools + DocumentationSearch + progress UI

```swift
@MainActor @Observable final class DocSearchModel {
    private var client: XcodeMCP?
    var progressText = ""; var resultText = ""

    func search(_ query: String) async {
        guard let client else { return }                    // F2
        do {
            let result = try await client.callTool(
                "DocumentationSearch",
                arguments: ["query": .string(query)]        // F1
            ) { [weak self] p in
                let text = p.message ?? ""
                await MainActor.run { self?.progressText = text }  // F3
            }
            if result.isError { /* 手動チェック必須 */ }     // F5
            resultText = result.content.compactMap {
                if case .text(let t, _) = $0 { return t }; return nil
            }.joined(separator: "\n")                       // F4
        } catch let e as XcodeMCPError {
            resultText = describe(e)                        // F6: 自前 switch が必要
        } catch { resultText = String(describing: error) }
    }
}
```

- **F1**: literal conformance は literal にしか効かない。String 変数は `.string(query)` 必須。最頻出パスが冗長。unlabeled 変換 init(`MCPJSONValue(query)`)も subscript も無い(MCPJSONValue.swift 全読で確認)。
- **F2**: 接続状態の観測手段が無い。`isClosed` 相当の公開プロパティ・切断通知が無く、consumer が optional 管理で状態を二重管理する。transport 切断理由(process exit status 等)は内部イベントに存在する(XcodeMCPTransport.swift:55-64)が、次のリクエスト失敗の `transportUnavailable` 文字列としてしか届かない(InitializedMCPClientSession.swift:297-303)。NWConnection の `stateUpdateHandler` 相当が欠落。
- **F3**: `onProgress` は `@Sendable` closure — MainActor UI 更新には毎回 hop が必要。`@MainActor` overload も AsyncSequence 代替も無い。単一 call に紐づく progress としては callback 設計自体は妥当(spec 上 token 単位)だが、**最終 result 返却後に progress callback が遅れて発火し得る**: delivery Task は dict から remove されるだけで cancel/await されない(InitializedMCPClientSession.swift:145-150 の defer + 328-338)。UI が「完了後に進捗が更新される」race を踏む。
- **F4**: `MCPToolResult` にテキスト連結 convenience が無い(例: `var text: String`)。全 consumer が同じ compactMap+case パターンを書く。
- **F5**: `isError` はプロパティで throw されない(文書化済み: MCPDomainTypes.swift:120-124)。忘れると「成功」として扱う footgun。opt-in の throwing 版が無い。
- **F6**: `XcodeMCPError` が `LocalizedError` 非準拠 → `error.localizedDescription` は汎用文言。UI 提示には consumer が全 6 case を switch する必要。さらに **discovery file が stale/missing の場合 `invalidRequest` として届く**(StreamableHTTPXcodeMCPTransport.swift:64-67 → XcodeMCP.swift:404-405 でそのままマップ)— 「リクエストが不正」ではなく「proxy が起動していない」環境問題であり、カテゴリが誤誘導。`transportUnavailable(String)` も「mcpbridge 未導入(セットアップ問題)」と「セッション中の切断(リトライ問題)」を 1 つの文字列 case に混載。
- **F7 (cancellation)**: 呼び出し側 Task の cancel はローカルで continuation を `CancellationError` で失敗させるだけ(InitializedMCPClientSession.swift:172-174)。**MCP `notifications/cancelled` は送信されない**(rg で全 Sources に不存在を確認)— サーバー側でツールは走り続ける。長時間ツール(ビルド等)を UI からキャンセルする手段が無い。
- **F8 (timeout)**: `requestTimeout` は固定 60s デフォルトで、**progress 受信でリセットされない**(withRequestTimeout は固定 sleep、InitializedMCPClientSession.swift:263-284)。MCP spec 2025-06-18 lifecycle は progress 受信でのタイムアウトリセットを SHOULD としている(spec 記憶ベース、要一次確認)。per-call の timeout override も無い — 長短混在のツールでは client を分けるか全体無効化しかない。
- **F9**: initialize result(serverInfo / server capabilities)は protocolVersion 検証後に破棄され(InitializedMCPClientSession.swift:224-253)、consumer から一切参照できない。

### Story (b): XcodeMCPTestRuntime を使うテスト

```swift
let runtime = XcodeMCPTestRuntime()
await runtime.setToolResult(
    MCPToolResult(content: [.text("ok", raw: ["type": "text", "text": "ok"])]),  // T1
    forToolNamed: "DocumentationSearch")
let client = try await runtime.makeClient()
_ = try await client.callTool("DocumentationSearch", arguments: ["query": "NavigationStack"])
let messages = await runtime.recordedMessages()
let call = try #require(messages.first { $0.method == "tools/call" })            // T2
let args = try #require(call.params?.objectValue?["arguments"]?.objectValue)     // T2
#expect(args["query"] == .string("NavigationStack"))
```

- **T1**: `.text("ok", raw: ...)` の raw 二重記述が必須(MCPContent の全 case に raw ラベル必須、デフォルト不可)。`MCPContent.text("ok")` 相当の raw 合成 factory / `MCPToolResult(text:)` convenience が欠落。README 例も二重記述している(前掲)。
- **T2**: `ToolCall` 型は public に存在する(XcodeMCPTestRuntime.swift:45)のに、decode 結果は内部 `result(for:)` でしか使われず(302)、`recordedToolCalls()` 相当が無い。テストは生 JSON を手掘りする。`recordedMessages()` には initialize + notifications/initialized の handshake 2 通が先頭に混ざるため index ベース assert は脆い(242-251 で全メッセージ記録)。
- **T3**: `makeClient(configuration:)` に `.streamableHTTP(...)` 等を渡しても silent に無視される(158-164)。
- **T4**: progress を N 回受けてから result、の assert は F3 の delivery race によりフレーク要因になり得る(構造から確認、実測はしていない)。

## 5. 非公開だが consumer が必要としそうな機構(file:line 付き)

| 機構 | 内部実装 | 公開状況 |
|---|---|---|
| Custom transport 注入 | `package protocol XcodeMCPTransport`(XcodeMCPTransport.swift:8-13) | 非公開。in-process proxy 直結等は不可能。テストのみ XcodeMCPKitTesting 経由 |
| 切断理由 / 状態遷移 | `.closed(String?)` イベント、exit status・protocol violation 文字列(XcodeMCPTransport.swift:53-64) | 次リクエストのエラー文字列としてのみ露出 |
| SSE GET + 指数 backoff 再接続 | StreamableHTTPMCPClient.swift:98-152 | 完全内部。セッションレベルの reconnect は無く、transport 死亡後は XcodeMCP 作り直しのみ(公開 API 無し) |
| server→client 通知 | handleMessage は id 付きメッセージと `notifications/progress` のみ処理、**それ以外の通知(`notifications/tools/list_changed` 含む)は無音で drop、ログも無し**(InitializedMCPClientSession.swift:306-343; `list_changed` は rg で全 Sources に不存在) | 非公開・観測不能。silent drop はログ欠落としても不備(fail-fast 方針との不整合) |
| server→client リクエスト | 一律 -32601 応答(InitializedMCPClientSession.swift:352-359) | v1 で意図的非公開と文書化済み(XcodeMCP.swift:161-164)。テストは emitServerRequest で検証可能 |
| リクエストキャンセルの上流伝播 | 無し(`notifications/cancelled` 不存在) | 欠落 |
| tools/list pagination | `listTools` は `result["tools"]` のみ読み、`nextCursor` を無視(XcodeMCP.swift:266-272; rg で cursor 処理不存在) | spec 2025-06-18 は tools/list の cursor pagination を規定。mcpbridge が paginate しない前提なら実害なしだが silent truncation の潜在 |
| initialize result の serverInfo/capabilities | 検証後破棄(InitializedMCPClientSession.swift:224-253) | 非公開 |

## 推測(未確認)と明示

- 「mcpbridge は tools/list を paginate しない」は未確認の推測。paginate する場合 listTools は先頭ページのみ silent に返す。
- MCP spec の「progress 受信で timeout リセット SHOULD」「progressToken は string|integer」「notifications/cancelled の存在」はモデル知識に基づく spec 参照であり、リポ内の spec コピーでは未照合。lead 側で spec 一次情報の確認を推奨。
- F3/T4 の progress-after-completion race は静的読解による構造的確認であり、実行観測はしていない。
- JSONDecoder が `1.0` を `Int64` として decode し `.integer(1)` になる可能性(MCPJSONValue.init(from:) の decode 順、MCPJSONValue.swift:41-58)は Foundation 実装依存で未検証。合成 Equatable(`.integer(1) != .double(1.0)`)と組み合わさると roundtrip 比較が不安定になり得る。

# CANDIDATE FINDINGS

## [medium] XcodeMCPError が UI 提示・分岐に不向き: LocalizedError 非準拠 + stale discovery が invalidRequest に誤分類 + transportUnavailable がセットアップ失敗と切断を混載 (kit-api)
EVIDENCE: XcodeMCPError.swift:9-36 に LocalizedError/CustomStringConvertible 準拠なし(rg で全 Sources 確認)。StreamableHTTPXcodeMCPTransport.swift:64-67 が discovery file 欠落/stale を MCPBridgeRuntimeError.invalidRequest で throw し、XcodeMCP.swift:404-405 がそのまま XcodeMCPError.invalidRequest にマップ。transportUnavailable は文字列 1 本(XcodeMCPError.swift:35)。
DIRECTION: 仮説: エラー分類の owner を「consumer が取るべき次アクション」軸で再設計(セットアップ不備/proxy 未起動/セッション断/タイムアウト/サーバーエラー)し、LocalizedError 準拠を追加。stale discovery は専用 case か transportUnavailable 系へ移す。

## [medium] 接続状態・切断の観測手段と reconnect story が皆無(切断理由は次リクエストのエラー文字列でしか届かない) (kit-api)
EVIDENCE: XcodeMCPTransport.swift:53-64 で exit status・protocol violation を .closed(String?) として生成するが、InitializedMCPClientSession.swift:297-303 で isClosed 化+pending 失敗に消費されるのみ。XcodeMCP に isClosed/状態 stream/切断 handler の公開 API なし(XcodeMCP.swift:183-368)。SSE 再接続は transport 内部のみ(StreamableHTTPMCPClient.swift:98-152)。
DIRECTION: 仮説: NWConnection.stateUpdateHandler 相当の最小観測点(state AsyncSequence または onClose callback)を actor XcodeMCP に追加。セッション再接続は v1 スコープ外でも、死亡検知だけは公開する。

## [medium] キャンセルがサーバーへ伝播しない: Task cancel はローカル abandon のみで notifications/cancelled を送らない (kit-api)
EVIDENCE: InitializedMCPClientSession.swift:172-174 の onCancel は pendingRequests.fail(CancellationError()) のみ。'notifications/cancelled' は rg で Sources 全体に不存在。長時間ツール実行はサーバー側で継続する。
DIRECTION: 仮説: request() の onCancel で MCP cancellation notification を best-effort 送信する(spec 2025-06-18 の cancellation utility を一次確認のうえ)。

## [medium] requestTimeout が progress 受信でリセットされず per-call override も無い — 長時間ツール(60s 超)がデフォルトで必ず timeout (kit-api)
EVIDENCE: withRequestTimeout は固定 duration の sleep レース(InitializedMCPClientSession.swift:263-284)。progress handler 経路(306-343)と timeout に接続なし。デフォルト .seconds(60)(XcodeMCP.swift:138)。callTool/request に timeout 引数なし(XcodeMCP.swift:289-342)。
DIRECTION: 仮説: progress 受信で deadline を延長(spec の SHOULD を一次確認)し、callTool/request に per-call timeout override を追加。

## [medium] MCPJSONValue のエルゴノミクス不足: 変数からの変換 init 無し・subscript 無し・Decodable 復路無し・intValue/integerValue 重複 (kit-api)
EVIDENCE: literal conformance のみで String/Int 変数は .string(x) 必須(MCPJSONValue.swift:129-169)。subscript 定義なし(全 321 行確認)。Encodable→MCPJSONValue は init(encoding:)(113)があるが逆方向 decode helper なし。intValue は integerValue の完全複製で両方 Int64(197-205)、README は intValue 非掲載(Sources/XcodeMCPKit/README.md:105-106)。
DIRECTION: 仮説: subscript(String)/subscript(Int)、unlabeled 変換 init 群、decode<T: Decodable>() を追加し、intValue は deprecate。合成 Equatable の integer/double 非等価も要検討。

## [low] MCPContent 全 case で raw: 必須のためテキスト content 構築が二重記述になる(README 例自体が症状を露呈) (kit-api)
EVIDENCE: MCPContent の case 定義(MCPDomainTypes.swift:68-81)に raw デフォルト不可。README が同一文字列を typed と raw に二重記述(Sources/XcodeMCPKit/README.md:170-174、Sources/XcodeMCPKitTesting/README.md:18-24)。MCPToolResult にテキスト連結 accessor も無し(111-174)。
DIRECTION: 仮説: raw を合成する factory(MCPContent.text("…") / MCPToolResult(text:))と result.text 連結 accessor を追加。

## [low] progress callback が callTool 返却後に遅延発火し得る(delivery Task を cancel/await せず dict から remove するのみ) (kit-api)
EVIDENCE: request() の defer は progressHandlers/progressDeliveryTasks を remove するだけ(InitializedMCPClientSession.swift:145-150)。delivery は直列 Task チェーン(328-338)で完了前に result continuation が resume され得る。実行観測は未実施(構造からの確認)。
DIRECTION: 仮説: 最終 result の complete 前に該当 token の delivery チェーンを await するか、完了時に cancel してポスト完了配送を契約上禁止する。

## [low] progress 以外の server 通知(notifications/tools/list_changed 等)を無音 drop、ログも無し (kit-api)
EVIDENCE: handleMessage は id 付き応答と notifications/progress のみ処理し、他はフォールスルー(InitializedMCPClientSession.swift:306-343)。list_changed 文字列は Sources に不存在(rg 確認)。契約違反検知点のログ欠落。
DIRECTION: 仮説: 最低限、未処理通知を debug ログで表面化。tools/list_changed の公開はドキュメント化された非対応(XcodeMCP.swift:156-164)と整合させて判断。

## [low] listTools が tools/list の pagination(nextCursor)を無視 — paginate されると先頭ページのみ silent 返却 (kit-api)
EVIDENCE: XcodeMCP.swift:266-272 は result["tools"] のみ読む。cursor 処理は XcodeMCPKit に不存在(rg 確認)。mcpbridge が paginate しないかは未確認(推測)。
DIRECTION: 仮説: nextCursor が来たら追走ループするか、少なくとも invalidResponse で fail fast させ silent truncation を防ぐ。

## [low] initialize result(serverInfo/server capabilities)が検証後に破棄され consumer から参照不能 (kit-api)
EVIDENCE: InitializedMCPClientSession.swift:224-253 で protocolVersion のみ検証し result を保存しない。XcodeMCP に公開 accessor なし。
DIRECTION: 仮説: XcodeMCP に serverInfo/capabilities の読み取り専用公開を追加。

## [low] Testing: recordedToolCalls() 欠落で tools/call の assert が生 JSON 手掘りになり、makeClient が configuration.transport を silent 無視 (testing-api)
EVIDENCE: ToolCall は public(XcodeMCPTestRuntime.swift:45)だが decode は内部専用(302, 326-347)。recordedMessages() は handshake 2 通を含む全記録(242-251)。makeClient は transport を差し替え configuration.transport を無視(158-164)。
DIRECTION: 仮説: recordedToolCalls() を公開し、makeClient は transport 指定付き configuration を受けたら precondition か文書化で明示する。

## [low] README ドリフトなし(全例コンパイル可能と判断)— ただし例が API 摩擦(raw 二重記述)をそのまま写している (docs)
EVIDENCE: Sources/XcodeMCPKit/README.md:33-186 および Sources/XcodeMCPKitTesting/README.md:10-54 の全コード例を実シグネチャ(XcodeMCP.swift:196-366, MCPJSONValue.swift:91-169, XcodeMCPTestRuntime.swift:145-209)と照合し不一致なし。
