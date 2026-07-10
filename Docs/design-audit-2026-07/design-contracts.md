# 修正設計の候補契約

**Design status: NOT APPROVED.** このファイルは監査finding(READMEのF1〜F9)から導いた制約と候補patternであり、canonical designではない。Task A/B/Cのinterface、isolation、atomicity、deadline、移行、削除対象、contract testは各design gateで確定する。本文は実装開始の承認を意味しない。

**Compatibility decision: BREAKING CHANGES ALLOWED.** source/CLI compatibility維持を目的とするwrapper、redirect、deprecated mirror APIは既定で追加しない。design gateでは残すconsumer storyと単一標準形を先に決め、削除/型変更するsymbol・flag・wire impactを明示する。

## §1. エラーモデル(→ タスク B-1 / C-3、監査 F7)

- **観測事実と replay policy を分離**: throw site は `.sessionExpired`、`.transientHTTP(status)`、`.deliveryUnknown`、typed cancellation reason など観測できた事実だけを型にし、復旧誘導の prose は別チャネルで運ぶ。自動再実行可否は error 単体の property にせず、session owner が `(error fact, operation semantics, delivery certainty, request-scoped replay count, remaining deadline)` から決める。`localizedDescription` 等の文字列から kind を復元しない。
- **session-expired 404 を独立 case に**: `Mcp-Session-Id` を実際に付けた POST/GET への404だけを transport が typed `.sessionExpired` とする。session IDなしの initialize や endpoint 自体の404は同じ case にしない。session owner は旧 transport/session identity をキーに recovery を single-flight 化し、fresh transport + session IDなし initialize + `notifications/initialized` を行う。元操作の replay は本SDKが選ぶ product contractで、最大1回。2回目の `.sessionExpired` は caller に surface する。spec MUST は「新しい session を initialize」までであり、元操作の透過 replay までを MUST と表現しない。
- **到達不明を独立 case に**: 「送達されたが応答が無い=実行されたかもしれない」を明示し、side-effecting request は自動 resend しない。server が処理前に拒否したと型で証明できる場合だけ replay 可。delivery unknown の復旧誘導は「状態を再観測 → 効いていなければ明示 retry」とする。
- **1 logical deadline**: public request 境界で absolute deadline を1つ発行し、初回送信、404検知、single-flight lock待機、fresh initialize、`notifications/initialized`、1回replay、transient retry、pagination の全工程へ remaining budget を渡す。回復で budget を再開始しない。handshake 固有上限が必要なら `min(request deadline remaining, handshake cap)` とする。
- **cancellation reason は発生 owner で型にする**: caller cancel / shutdown / load supersession / internal invalidation を blanket `CancellationError` に潰して mapper で推測しない。consumer-visible interruption だけを typed reason に変換し、ErrorMapper はその型を exhaustively map する。内部 stale completion の discard は consumer error にしない。
- **outcome vs failure の分離**: 正常な観測結果(「見つからなかった」「変化なし」等の否定形を含む)は戻り値、failure だけが throw。error case の氾濫と「正常系の throw」を両方防ぐ切り分け基準。
- **LocalizedError witness の罠**: `errorDescription` は **`String?` で宣言**しないと protocol witness が入らず、`localizedDescription` が opaque な NSError 文言に silent 劣化する。準拠宣言だけでなく `localizedDescription` の内容を assert する unit test を置く。
- **version 不整合の case 分割**: wire 非互換(再インストール必須)と挙動 drift(再初期化推奨)は consumer の次アクションが違うので別 case にし、区別理由を doc comment に書く。
- **staleness エラーに provenance**: 有効範囲・スナップショット時刻・正確な復旧手順を error に埋める(「@1..@43 に対し @57 を要求。最終取得は〈時刻〉。〈復旧手順〉」の形)。
- **診断ライダーと decode の層別**: 成功応答に載せる additive な診断キーは「nil なら欠落」規則で後方互換にし、本体 payload への重複 encode 禁止を contract test で pin する。decode は outcome=厳格 / 診断=寛容 — 寛容側は「結果は確定済み・純粋に情報的・forward-compat が必要」の 3 条件が揃う場所に限定(semantic field への適用は fail-fast 違反)。

## §2. lifecycle / discovery(→ タスク B-1 / B-3、監査 F6/F7)

- **3 層 liveness ladder**: discovery record(ファイル)は「ヒント」であり、その状態は `probablyAlive` のように**名前に不確実性を刻む**。真の判定は接続(短 timeout)、確定は handshake。stale record は読む側が掃除する。→ stale discovery file の誤分類(F7)の再設計はこの層構造を前提に。
- **facts, not verdicts**: 死活・健全性は「消えた/おそらく終了(確度付き)」と観測事実を報告し、断定しない。原因確定は consumer の仕事。検出器は I/O-free の純状態機械にし、probe の所有は runtime 1 箇所に置く(合成 snapshot 列で unit-testable になる)。
- **session lifecycle の single source of truth**: session owner が transport identity、session ID、recovery、close reason を所有する。public contract は少なくとも current snapshot と ordered state sequence を候補とし、`ready / recovering / unavailable / closed` の意味、explicit close の終端性、recovery failure 後の再試行可否、buffer/drop、subscriber model を design gate で確定する。consumer に optional client 等の mirror state を持たせない。
- **SSE 404 を silent terminal にしない**: GET stream の session-expired 404も同じ session invalidation signal へ接続する。ただし Codex `openai/codex@1f0566d3` は GET 404をtyped化するものの、request recoveryと同じ経路での復旧までは示していないため、参考実装とは扱わない。

独自handshake payload、doctor / `--check`、新しいCI parity job、built-binary smokeを含むCI層再編は監査findingから直接要求されないscope expansionなので、現handoffの実装要件には含めない。必要なら別proposalとしてconsumer storyから設計する。

## §3. staleness / cache(→ タスク A、監査 F1/F2)

- **internal stale completion と consumer-visible stale state を分ける**: 旧 generation / lease / attempt に属する内部非同期完了は owner が atomically reject/discard し、新しい状態を invalidate せず、無関係な consumer error にもしない。consumer が保持する stale handle/session を実際に使った場合だけ、該当 owner を invalidate して actionable typed error と再確立手順を返す。
- **catalog commit を atomic owner operation に**: `(generation, route lease, attempt)` の proof確認、process surface mutation、canonical projection を同じ isolation boundary で直列化するか、store が proof を consume する CAS にする。隣接checkや「commit関数を1箇所にした」だけでは atomicity の証明にならない。
- **at-most-once policy を session owner に**: 「配達前と証明できる」「配達後」「不明」の fact と operation semantics を組み合わせる。再送可否を error type だけに持たせず、request-scoped replay count と remaining deadline も同じ判定へ渡す。
- **cache 意味論は明示契約に**: staleness を caller の行動が左右する cache は、隠さず policy として可視化する(設定/フラグ、または addressing の文法に名前を出す)。強制 refresh は cache を**置換**する(バイパスだと古い snapshot が後続で復活する)。invalidation の owner は 1 箇所。
- **wait/poll は第一級パラメータ**: default は0(fail fast)。retryは typed fact、operation semantics、delivery certainty、remaining deadline を組み合わせ、ループ側の一律retryにしない。非0 defaultは隠れretry。
- **揮発する外部事実には validity scope を宣言**: 「この値は現在の操作でのみ有効・跨いで cache しない」を owner の doc に明文化し、推測 fallback に落ちた場合は必ず表面化する(advisory)。
- **staleness は「検知するか、明示的に disclaim するか」の二択**: 検知もせず宣言もしない中間解は silent 誤動作(古い値での実行)を生む。検知は code に、規範は doc に、の順。

## §4. surface / process(→ タスク C/D、監査 F5/F9)

- **直接削除・型変更が標準形**: breaking changes allowedのため、旧名redirect、deprecated mirror API、adapterは追加しない。残すconsumer storyを満たす最小surfaceへ直接移行する。新しいexternal constraintが後から確認された場合だけdesign gateを再開し、compatibility layerのowner・削除条件を設計する。
- **`listTools()` は完全 catalog を返す候補契約**: 現行 `listTools() -> [MCPTool]` を維持するなら、`nextCursor == nil` まで1 logical deadline内で追走し、途中error/deadlineで部分配列を返さない。既出cursorの再出現(`A → B → A` を含む)はcycleとしてfail fast。raw `request("tools/list", params:)` はページ単位のescape hatchとして残す。この選択は design gate で確定する。Codex `openai/codex@1f0566d3` も上位consumerが `next_cursor` を捨てるため、paginationの参考実装にはしない。
- **wire shape の snapshot test を契約書に**: 外部が pin する schema(応答 envelope、discovery file)は決定的バイト列の snapshot test で固定し、「変更するなら snapshot と documented schema を両方更新」の手順を test doc に明記する。

## アンチパターン(採らない形)

| 形 | なぜ採らないか |
|---|---|
| 文字列 substring によるエラー分類 | prose が事実上の wire 契約になり、文言変更で分類が silent に劣化する。fact は throw site で型に付与する |
| error 型だけで retry 可否を決める | operation の副作用性、delivery certainty、replay count、deadline が欠落する。session owner が全入力を合成する |
| staleness の中間解(検知も disclaim もしない) | 古い値での silent 誤動作。二択(§3)に倒す |
| 変動軸の部分吸収 | 分類だけ吸収して dispatch / capability 宣言を残すと、variant 追加が全域編集のまま。variant 追加テストはサブ軸ごと(新種別 / 新フラグ / 新 backend)に行う |
| 未対応の組合せの扱い混在 | 同じ「未対応」が場所により throw / redirect / silent ignore に割れると consumer は予測不能。1 契約に統一し、silent ignore は禁止 |
| 同一 wire shape の encoder 二重化 | 契約の owner が 2 箇所に割れ、整合が snapshot test と規約頼みになる |
| 単一 slot への複数 advisory の lossy merge | typed field が複数要素で信頼できなくなる。複数があり得るなら array |
| 宣言だけの契約軸 | 検査点(CI/runtime)の無い互換宣言は drift を検知できない |
