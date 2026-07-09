# Streamable HTTP 実装 vs MCP spec 2025-06-18 照合レポート (proxy = XcodeMCPProxyKit HTTP gateway, HEAD a1c6218e)

Spec 一次情報: modelcontextprotocol.io/specification/2025-06-18/basic/transports (以下 T-§) および /basic/lifecycle (L-§)。両ページ WebFetch で全文取得済み。引用は正規化した節名 + 番号。

## 実装の構造 (confirmed)

- ルーティング: `HTTPRoute.resolve` — GET `/mcp`|`/`|`/mcp/events`|`/events` → SSE, DELETE `/mcp`|`/` → deleteSession, POST `/mcp`|`/` → post, GET `/health`, GET `/debug/upstreams`, POST `/debug/reset` (Sources/XcodeMCPProxyKit/Internal/HTTPGateway/HTTP/HTTPRoute.swift:12-29)。単一 MCP endpoint (POST+GET 双方) の MUST は充足。
- ヘッダ検証: `HTTPRequestValidator` (Internal/HTTPGateway/HTTP/HTTPRequestValidator.swift:9-61)。
- セッション検証: `HTTPHandler.validateExistingSession` (Internal/HTTPGateway/HTTP/HTTPHandler.swift:647-716) / `validateDeletableSession` (:718-779)。
- POST 本文処理: `ClientMCPRequestExecutor.handle` (Internal/Session/ClientRequestExecution/Post/ClientMCPRequestExecutor.swift:100-361)。
- SSE 配信: `SSEHub` (Internal/Session/Session/SSEHub.swift), `JSONRPCResponseRouter.notify/bufferNotification` (Internal/RuntimeCore/Broker/JSONRPCResponseRouter.swift:267-282)。
- サーバ発リクエスト: `RuntimeCoordinator+UpstreamRouting.routeServerInitiatedPayloads` (:894-969) + `ServerRequestTracker` (Internal/RuntimeCore/Broker/ServerRequestTracker.swift)。
- クライアント側 transport: `StreamableHTTPMCPClient` (Sources/XcodeMCPKit/Internal/CoreRuntime/StreamableHTTPMCPClient.swift)。stdio 互換アダプタ `StdioAdapter` (Sources/XcodeMCPProxyKit/Stdio/StdioAdapter.swift) はこの client を利用。
- サポート版: `MCPProtocolVersion.isSupported(v) == (v == "2025-06-18")` のみ (Sources/XcodeMCPKit/Internal/CoreRuntime/MCPProtocolVersion.swift:3-9)。

## 契約テーブル

| # | protocol fact | spec citation | repo behavior (file:line) | verdict |
|---|---|---|---|---|
| a1 | サーバは initialize 時に `Mcp-Session-Id` を応答ヘッダで発行してよい (MAY)。ID は visible ASCII、暗号学的に安全 SHOULD | T-§Session Management 1 | initialize (有効な id を持つ request のみ) で `UUID().uuidString` を新規発行、クライアント提供のセッションヘッダは無視 (HTTPHandler.swift:557-572)。応答に `Mcp-Session-Id` 付与 (MCPResponseEmitter.swift:19-21, 38-40) | compliant |
| a2 | セッション必須サーバは init 以外のヘッダ無しリクエストに 400 SHOULD | T-§SM 2 | 欠如→400 "session id required" (HTTPHandler.swift:652-664; POST/GET/DELETE 共通) | compliant |
| a3 | 終了済み/未知セッション ID には 404 MUST | T-§SM 3 | 未知→404 "session not found" (HTTPHandler.swift:665-675, 736-746)。DELETE 後は registry から削除→以後 404 (HTTPControlService.swift:94-97) | compliant |
| b1 | ヘッダ `MCP-Protocol-Version` 欠如時、サーバは negotiated version に依拠するか 2025-03-26 を仮定 SHOULD。400 MUST は「invalid or unsupported」の場合のみ | T-§Protocol Version Header | ヘッダ欠如→無条件 400 "protocol version required" (HTTPHandler.swift:689-701)。negotiated version は session registry に保持済み (SessionRegistry.swift:120-123) なのに使わない | **over-strict**(spec の後方互換 SHOULD に反する。ヘッダを送らない旧 SDK クライアントを 400 で遮断) |
| b2 | クライアントが送る版は negotiated のもの SHOULD (MUST ではない) | T-§PVH | ヘッダ値が negotiated と不一致なら 400 "protocol version mismatch" (HTTPHandler.swift:702-714) | over-strict (SHOULD を 400 で強制。現状 supported=単一版なので実害は b1 に包含) |
| b3 | invalid/unsupported 版に 400 MUST | T-§PVH | `MCP.ProtocolVersion.isSupported` (== "2025-06-18" のみ) で 400 (HTTPHandler.swift:702-714; MCPProtocolVersion.swift:6-8) | compliant |
| c1 | POST: クライアントは Accept に application/json と text/event-stream 両方を列挙 MUST (クライアント側義務) | T-§Sending 2 | 両方含まないと 406 (HTTPRequestValidator.swift:38-45; HTTPHandler.swift:492-505)。ただし `acceptsJSON` は `*/*` を許容、`acceptsEventStream` は許容しない非対称 (HTTPRequestValidator.swift:21-31) → `Accept: */*` は 406 | over-strict 気味 (クライアント MUST の強制自体は正当。`*/*` 拒否は curl 等の素朴なクライアントを壊す) |
| c2 | GET: Accept に text/event-stream MUST (クライアント側義務) | T-§Listening 2 | 含まないと 406 (HTTPHandler.swift:429-439)。`*/*` も 406 | 同上 |
| c3 | POST Content-Type | T-§Sending (暗黙; body は JSON-RPC) | application/json 以外は 415 (HTTPRequestValidator.swift:46-48; HTTPHandler.swift:506-515) | compliant |
| d | 2025-06-18 で batch 廃止: body は単一 message MUST | T-§Sending 3 | 配列 body→400 "JSON-RPC batching is not supported" (HTTPHandler.swift:543-554)。ただし executor 内部には forceBatchArray / pendingBatches / 単一要素配列許容 (ClientMCPRequestExecutor+LocalHandling.swift:84-91, JSONRPCResponseRouter.swift:97-125) の batch 機構が残存し、内部再入 (ForwardExecutor.swift:193) 経由のみ到達 | compliant (HTTP 面)。内部 batch 機構は HTTP 外部入力からは dead — 複雑性負債 |
| e1 | サーバは SSE イベントに `id:` を付けてよい MAY; 付けるなら session 内 unique MUST | T-§Resumability 1 | `SSECodec.encodeDataEvent` は `data:` 行のみで `id:` フィールドを一切生成しない (Sources/XcodeMCPKit/Internal/CoreRuntime/SSECodec.swift:8-25) | compliant (MAY 不採用) |
| e2 | Last-Event-ID による再開はサーバ MAY | T-§Resumability 2 | `Last-Event-ID` は Sources 全体で出現ゼロ (rg 確認)。GET はヘッダを読まず黙って新規ストリーム扱い | compliant (silently ignored; 再送なし) |
| e3 | 同一 message を複数 stream に broadcast してはならない MUST | T-§Multiple Connections 2 | `SSEHub.broadcast` は round-robin で 1 チャネルのみに送信 (SSEHub.swift:117-131)。buffer の drain も既存クライアント無しの時のみ・新チャネル 1 本へ (HTTPControlService.swift:79-86) | compliant |
| e4 | GET stream 上のメッセージは並行中のクライアント request と無関係 SHOULD; 関連メッセージは当該 POST の SSE stream に載せるのが spec の想定 | T-§Sending 6 / T-§Listening 4 | POST 応答は常に単一 JSON (`postPreference` が常に false を返す: HTTPRequestValidator.swift:49-50)。upstream 発のサーバ→クライアント request/notification はすべて GET stream (or buffer) 行き (JSONRPCResponseRouter.swift:267-273 → NotificationHub → SSEHub) | **under-enforced/設計上の divergence** (SHOULD 逸脱。GET stream 未接続クライアントはサーバ要求を受け取れず、buffer 50 件超で無警告 drop: JSONRPCResponseRouter.swift:275-282。upstream は ServerRequestTracker の 300s timeout まで待つ: ServerRequestTracker.swift:27-33) |
| e5 | GET stream に JSON-RPC *response* を流すのは resume 時以外 MUST NOT | T-§Listening 4 | 未対応付け応答は broadcast せず drop + debug log (RuntimeCoordinator+UpstreamRouting.swift:816-824)、late response も drop (:167-180) | compliant |
| f | DELETE によるセッション終了はクライアント SHOULD; サーバは 405 で拒否 MAY | T-§SM 5 | DELETE 実装済み→200 空応答 (HTTPHandler.swift:480-490)。未初期化セッションは版ヘッダ無しでも削除可 (:747-751)。クライアント側も close() で DELETE 送信 (StreamableHTTPMCPClient.swift:154-177) | compliant |
| g1 | initialize が最初の interaction MUST; client は init 応答前に (ping 以外の) request を送らない SHOULD | L-§Initialization | セッションの negotiated version 未確定なら POST/GET を 400 "session is not initialized" (HTTPHandler.swift:676-688)。bridge 未 init 時の request は JSON-RPC error -32000 "expected initialize request" (HTTP 200)、notification は 422 (ResponseUtilities: makeExpectedInitializeResolution 130-152) | ほぼ compliant だが ping の例外なし (over-strict の微小 edge)。upstream 再起動で brokerState の initialize が消えた場合、既存セッションに -32000 を返し続ける点は spec の回復経路 (404→再 init) と不整合 — 後述 finding |
| g2 | version negotiation: サーバは requested を支持しないなら自分の支持版で応答 MUST | L-§Version Negotiation | クライアントの initialize params は upstream に転送されず、proxy 固有の handshake (protocolVersion=2025-06-18) を送り (InitializeHandshakeJSON.swift:20-29; RuntimeCoordinator+Initialization.swift:825-835)、cached result を全クライアントに返す (InitializeManager.swift:294-302)。古い版を要求したクライアントにも 2025-06-18 の result が返る | compliant (counter-offer 形式)。ただしクライアント capabilities は upstream へ伝播しない (proxy が capability 交渉の facade) |
| g3 | client は init 成功後 `notifications/initialized` を送る MUST; サーバは受信前に request を送らない SHOULD | L-§Initialization | proxy 自身が upstream へ initialized を送る (RuntimeCoordinator+Initialization.swift:553-605)。クライアントからの initialized は bridge 初期化済みなら swallow して 202 (ForwardExecutor.swift:450-457) | compliant (proxy が lifecycle owner を代行) |
| h | notification/response を受理したら 202 Accepted + no body MUST; 受理できないなら HTTP error status MUST | T-§Sending 4 | 受理時: `.empty(status:.accepted)` 多数 (ClientMCPRequestExecutor.swift:775, ForwardExecutor.swift:452 ほか) + Content-Length:0 (MCPResponseEmitter.swift:76-85) — compliant。不受理時: id 無し initialize→JSON-RPC error -32600 を **HTTP 200** で返す (LocalMCPResponder.swift:71-79 → sendMCPError → sendJSON status .ok: MCPResponseEmitter.swift:22)、malformed message も同様 HTTP 200 (ClientMCPRequestExecutor.swift:162-176) | 受理系 compliant / 不受理系 **under-enforced** (「HTTP error status MUST」違反の edge) |
| i | サーバ→クライアント request の応答は client が POST で返し、サーバは対応 stream 経由で upstream に返す | T-§Sending 3 (response POST) | client POST の response は `forwardServerRequestResponse` → route 照合 → upstream へ ID 書換転送、202 (ClientMCPRequestExecutor.swift:177-183, 749-794; UpstreamRouting.swift:438-504)。route 不明 (`missingRoute`) でも 202 で黙認 (ClientMCPRequestExecutor.swift:773-775 + debug log UpstreamRouting.swift:471-479) | compliant (missingRoute の 202 は「受理できない入力に HTTP error MUST」に対し under-enforced だが、timeout 後の遅延応答が正常系にあるため黙認は妥当と説明可能) |
| sec | Origin 検証 MUST (all incoming connections)、localhost bind SHOULD | T-§Security Warning 1-2 | Origin 検証は sse/delete/post のみで、`/health` `/debug/upstreams` `/debug/reset` は免除 (HTTPHandler.swift:280-287)。検証自体は loopback origin 許容 + host/port 照合 (:289-343)。debug endpoints は listenHost が loopback の時のみ有効 (HTTPHandler+Responses.swift:241-248) | **under-enforced**: debug endpoints が「all incoming connections」の MUST から漏れる。DNS rebinding で `/debug/upstreams?includeSensitive=1` (HTTPHandler.swift:207-211, 271-278) の読出し・`/debug/reset` の実行が可能 |

## クライアント側 (XcodeMCPKit transport / stdio adapter) の spec 照合

- POST: `Accept: application/json, text/event-stream` + `Content-Type: application/json` (StreamableHTTPMCPClient.swift:21, 183-198) — compliant (T-§Sending 2)。
- `MCP-Protocol-Version` は initialize 完了後の全リクエストに付与 (:191-194, 483-485)、initialize 自体には付けない — compliant。
- セッション ID は initialize 応答ヘッダから記録 (:211-222) — compliant。
- **404 受信時に新 InitializeRequest でセッション再開 MUST (T-§SM 4) が未実装**: send() は 4xx を error として throw → transport は `transportUnavailable` に写像 (StreamableHTTPXcodeMCPTransport.swift:128-135)、GET stream は 404/405/406/410/501 を terminal として黙って停止 (StreamableHTTPMCPClient.swift:405-412)。StdioAdapter は "upstream HTTP 404" の -32000 error を stdio に流すだけ (StdioAdapter.swift:205-218, 380-388)。proxy-server 再起動後、稼働中の stdio adapter は spec の回復経路を持たない — クライアント側 MUST 違反。
- GET 再接続時に `Last-Event-ID` を送らない (makeEventStreamRequest :315-327) — T-§Resumability 2 の client SHOULD 不履行 (server 側も未対応なので実害はないが、他サーバに対して使う場合は loss)。

## Docs/architecture.md「Streamable HTTP Contract」(lines 84-89) vs code vs spec

- L85 POST の Content-Type / Accept 要件: code と一致 (HTTPRequestValidator.swift:38-48)。
- L86 「server generates MCP-Session-Id on initialize; caller-provided ids ignored」: code と一致 (HTTPHandler.swift:570-572)。
- L87 「POST/GET/DELETE require both MCP-Session-Id and MCP-Protocol-Version: 2025-06-18」: POST/GET は一致。DELETE は未初期化セッションに限り版ヘッダ不要 (HTTPHandler.swift:747-751) — **doc vs code の微小 drift**。さらにこの行自体が spec の「ヘッダ欠如は 2025-03-26 仮定 SHOULD」と矛盾する **doc vs spec drift** (over-strict 方針を契約として明文化している)。
- L88-89 400/404/DELETE 動作: code と一致。
- Doc の欠落 (契約に書かれていない実挙動): batch 400、GET の Accept 406、Origin 検証、`POST 応答は常に JSON (SSE を開かない)` という重要な選択 (HTTPRequestValidator.swift:49-50 のコメントにのみ存在)、`/mcp/events`・`/` エイリアス、202 semantics、SSE buffer 50 件 drop。

## Fact vs speculation の区別

- 上記の file:line 引用はすべて実コード読解で confirmed。
- Speculation (明示): (1) 「ヘッダを送らない旧 MCP SDK クライアントが実在する」は一般知識であり、本 repo 内の証拠はない。(2) mcpbridge が実際に elicitation/sampling 等のサーバ→クライアント request を発行するかは未確認 (ServerRequestTracker と routeServerInitiatedPayloads の存在から proxy はその前提で設計されている、までが confirmed)。(3) DNS rebinding の実攻撃可能性は Origin 検証欠落 + loopback bind という条件の組合せからの推論で、PoC 未実施。

# CANDIDATE FINDINGS

## [high] MCP-Protocol-Version ヘッダ欠如を無条件 400 で拒否 (spec は negotiated 版依拠 or 2025-03-26 仮定 SHOULD) (http-gateway)
EVIDENCE: HTTPHandler.swift:689-701 がヘッダ欠如で 400 "protocol version required"。spec T-§Protocol Version Header は 400 MUST を invalid/unsupported に限定し、欠如時は「negotiated during initialization に依拠」または 2025-03-26 仮定 SHOULD。negotiated 版は SessionRegistry.swift:120-123 に保持済みで参照可能。Docs/architecture.md:87 はこの over-strict 挙動を契約として明文化 (doc vs spec drift)。加えて HTTPHandler.swift:702-714 は supported-but-different 版も 400 (spec は SHOULD)。
DIRECTION: 仮説: validateExistingSession でヘッダ欠如時は session の negotiatedProtocolVersion に fallback し、明示的に不一致/未サポートの場合のみ 400 とする。Docs/architecture.md:87 も同時更新。

## [high] Origin 検証が /health と /debug/* endpoints で免除され spec の MUST (all incoming connections) から漏れる (http-gateway)
EVIDENCE: HTTPHandler.swift:280-287 routeRequiresOriginValidation が health/debugSnapshot/debugReset/notFound で false。spec T-§Security Warning 1「Servers MUST validate the Origin header on all incoming connections」。debug snapshot は includeSensitive=1 で機微 payload を含み得る (HTTPHandler.swift:207-211, 271-278)。debug endpoints は loopback bind 時のみ有効 (HTTPHandler+Responses.swift:241-248) だが、loopback こそ DNS rebinding の標的。
DIRECTION: 仮説: Origin 検証を route 分岐の外 (handleRequest 冒頭) に移し全 route に適用する。免除が必要な route があるなら理由を doc 化。

## [medium] POST 応答が常に単一 JSON のため、進行中リクエスト関連のサーバ→クライアント要求が GET stream/buffer に迂回し、無警告 drop で upstream が 300s 待ちになる (proxy-session)
EVIDENCE: HTTPRequestValidator.swift:49-50 (postPreference 常時 false、コメントのみで doc 未記載)。サーバ発 request は routeServerInitiatedPayloads (UpstreamRouting.swift:894-969) → JSONRPCResponseRouter.notify (JSONRPCResponseRouter.swift:267-273) → GET SSE or buffer。buffer は 50 件超で黙って removeFirst (JSONRPCResponseRouter.swift:275-282、ログ無し)。応答待ち upstream は ServerRequestTracker routeTimeout 300s (ServerRequestTracker.swift:27-33) まで待つ。spec T-§Sending 6 は関連メッセージを POST SSE stream に載せる想定 (SHOULD)、T-§Listening 4 は GET stream 上のメッセージは無関係 SHOULD。
DIRECTION: 仮説: (a) 少なくとも buffer overflow drop を warning ログで表面化 (fail fast 方針)、(b) 中期的には POST の prefersEventStream 対応を実装するか、非対応を Docs/architecture.md の契約に明記。

## [medium] クライアント側 transport が 404 時の再 initialize (spec クライアント MUST) を実装していない (kit-api)
EVIDENCE: spec T-§Session Management 4「When a client receives HTTP 404 ... it MUST start a new session by sending a new InitializeRequest」。StreamableHTTPMCPClient.send は 4xx を throw (StreamableHTTPMCPClient.swift:74-76)、transport は transportUnavailable に写像 (StreamableHTTPXcodeMCPTransport.swift:128-135)、GET stream は 404 を terminal として停止 (StreamableHTTPMCPClient.swift:405-412)。StdioAdapter は "upstream HTTP 404" を -32000 で吐くのみ (StdioAdapter.swift:205-218)。proxy-server 再起動後に stdio adapter が回復不能。
DIRECTION: 仮説: セッション所有層 (InitializedMCPClientSession or StdioAdapter) に 404 検知→再 initialize→保留リクエスト再送 or 明示 fail の回復経路を追加。owner はセッション状態を持つ層。

## [low] 受理できない notification (id 無し initialize / malformed message) に HTTP 200 + JSON-RPC error を返す (spec は HTTP error status MUST) (http-gateway)
EVIDENCE: spec T-§Sending 4「If the server cannot accept the input, it MUST return an HTTP error status code」。id 無し initialize → LocalMCPResponder.swift:71-79 の .mcpError → HTTPResponseWriter.sendMCPError → MCPResponseEmitter.sendJSON status .ok (MCPResponseEmitter.swift:22)。malformed → ClientMCPRequestExecutor.swift:162-176 も同経路で 200。一方 bridge 未 init 時の notification は 422 (ResponseUtilities makeExpectedInitializeResolution 136-141) で正しく HTTP error。
DIRECTION: 仮説: Resolution.mcpError に HTTP status を持たせるか、notification 由来 (id 無し) の不受理を .plain(badRequest) に統一。

## [low] upstream 再起動で cached initialize が消えると既存セッションに -32000 "expected initialize request" を返し続け、spec の回復シグナル (404) と不整合 (proxy-session)
EVIDENCE: ClientMCPRequestExecutor.swift:189-201 が sessionManager.isInitialized()==false で makeExpectedInitializeResolution (JSON-RPC -32000 @HTTP200 / notification は 422)。invalidateControlPlane(clearInitialize:true) は upstream_exit で発生 (UpstreamRouting.swift:308-324)。セッション自体は生存し 404 にならないため、spec-準拠クライアント (T-§SM 4 の 404→再init しか知らない) は回復手段を持たない。eager retry (UpstreamRouting.swift:329-334) が成功すれば一時的だが、その間の in-band error は非標準。
DIRECTION: 仮説: bridge 再初期化を透過リカバリ (リクエストを readiness gate で待たせる) に寄せるか、回復不能と判断した時点でセッションを terminate して 404 を返す。現状の in-band -32000 は暫定策と位置づける。

## [low] Accept ヘッダ判定の非対称 (*/* を JSON では許容、event-stream では拒否) が素朴なクライアントを 406 で壊す (http-gateway)
EVIDENCE: HTTPRequestValidator.swift:27-31 acceptsJSON は "*/*" を許容、:21-25 acceptsEventStream は "text/event-stream" 文字列一致のみ。POST `Accept: */*` → 406 (HTTPHandler.swift:492-505)。spec のクライアント MUST (T-§Sending 2) の強制ではあるが、HTTP content negotiation 上 */* は両型を含む。
DIRECTION: 仮説: acceptsEventStream にも */* (と text/*) を許容させ判定を対称化。

## [low] HTTP 経路では到達不能な batch 機構 (forceBatchArray/pendingBatches/単一要素配列許容) が executor 全域に残存 (module-boundary)
EVIDENCE: HTTPHandler.swift:543-554 で配列 body は 400 のため、ClientMCPRequestExecutor+LocalHandling.swift:84-91 (array.count==1 許容)、JSONRPCResponseRouter.swift:97-125 registerBatchPending、多数の forceBatchArray 分岐は外部入力からは dead。内部再入 (ForwardExecutor.swift:193 の refresh split) のみが配列 payload を生成。2025-06-18 で batch は仕様から削除済み (T-§Sending 3)。
DIRECTION: 仮説: refresh split の内部 payload 形式を単一 message 列に正規化し、batch 分岐を段階的に削除して executor を単純化 (削除優先方針)。

## [low] Docs/architecture.md の Streamable HTTP Contract が実装の主要契約 (POST は SSE を開かない、batch 400、SSE buffer 50 drop、DELETE の版ヘッダ例外) を欠落 (docs)
EVIDENCE: Docs/architecture.md:84-89 は 5 項目のみ。DELETE の未初期化セッション例外 (HTTPHandler.swift:747-751) と L87 の記述が不一致。postPreference 常時 false の契約上重要な選択は HTTPRequestValidator.swift:49-50 のコメントにしか存在しない。
DIRECTION: 仮説: 契約セクションに「POST 応答は常に application/json」「batch 400」「GET SSE の buffer 上限と drop 方針」「Origin 検証範囲」を追記し、コードとの照合点を明確化。
