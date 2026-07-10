# 修正設計で適用する契約パターン

handoff の各タスクで採用を推奨する設計契約と、採らない形(アンチパターン)。監査 finding(README の F1〜F9)を修正するときの目標形として参照する。

## §1. エラーモデル(→ タスク B-2 / C-3、監査 F7)

- **typed kind + 次アクションの 2 チャネル分離**: 機械分岐用の閉じた分類(permanent / transient / stale / unknown =「retry する価値があるか」)を error 型の case として持ち、復旧誘導(recoverySuggestion 相当の prose)は別チャネルで運ぶ。consumer は kind で dispatch し、prose は表示のみ。retry 可否は error 型自身が宣言する(呼び出し側の文字列判定を排除)。**分類は throw site で型に付与する** — `localizedDescription` 等の文字列マッチで導出しない。
- **到達不明を独立 case に**: 「送達されたが応答が無い=実行されたかもしれない」を『失敗』と別の case にし、side-effecting 要求は自動 resend しない。復旧誘導は「状態を再観測 → 効いていなければ retry」。read-only 呼び出しは上位で retry 可 — 分類器が副作用性を知っている必要がある。
- **outcome vs failure の分離**: 正常な観測結果(「見つからなかった」「変化なし」等の否定形を含む)は戻り値、failure だけが throw。error case の氾濫と「正常系の throw」を両方防ぐ切り分け基準。
- **LocalizedError witness の罠**: `errorDescription` は **`String?` で宣言**しないと protocol witness が入らず、`localizedDescription` が opaque な NSError 文言に silent 劣化する。準拠宣言だけでなく `localizedDescription` の内容を assert する unit test を置く。
- **version 不整合の case 分割**: wire 非互換(再インストール必須)と挙動 drift(再初期化推奨)は consumer の次アクションが違うので別 case にし、区別理由を doc comment に書く。
- **staleness エラーに provenance**: 有効範囲・スナップショット時刻・正確な復旧手順を error に埋める(「@1..@43 に対し @57 を要求。最終取得は〈時刻〉。〈復旧手順〉」の形)。
- **診断ライダーと decode の層別**: 成功応答に載せる additive な診断キーは「nil なら欠落」規則で後方互換にし、本体 payload への重複 encode 禁止を contract test で pin する。decode は outcome=厳格 / 診断=寛容 — 寛容側は「結果は確定済み・純粋に情報的・forward-compat が必要」の 3 条件が揃う場所に限定(semantic field への適用は fail-fast 違反)。

## §2. lifecycle / discovery(→ タスク B-4、監査 F6/F7)

- **3 層 liveness ladder**: discovery record(ファイル)は「ヒント」であり、その状態は `probablyAlive` のように**名前に不確実性を刻む**。真の判定は接続(短 timeout)、確定は handshake。stale record は読む側が掃除する。→ stale discovery file の誤分類(F7)の再設計はこの層構造を前提に。
- **handshake payload に identity + version**: {pid, uptime, protocol version, app version, identity} を返し、接続境界 1 箇所で skew を検知する。「空 version = unknown は restart しない」という anti-crash-loop 規則を持ち、比較関数は pure function に抽出して単体テストする。
- **doctor / `--check` は同一経路の途中下車**: 環境検証は実処理と同一の解決コードを通ってから直前で exit する形にする。probe 用の別ロジックは第二の source of truth になるので作らない。失敗は理由+具体的補修コマンド付き。
- **facts, not verdicts**: 死活・健全性は「消えた/おそらく終了(確度付き)」と観測事実を報告し、断定しない。原因確定は consumer の仕事。検出器は I/O-free の純状態機械にし、probe の所有は runtime 1 箇所に置く(合成 snapshot 列で unit-testable になる)。
- **宣言した契約軸には検査点を置く**: protocol version 等の互換軸を宣言したら、CI(全 PR の静的 parity check)と runtime(handshake での比較)の両方に enforcement を置く。宣言だけの契約軸は形骸化する。

## §3. staleness / cache(→ タスク A、監査 F1/F2)

- **stale 処理の単一経路**: 検知 → 該当 cache/owner の invalidate → actionable error(復旧手順入り)→ 再確立。guard を積んで延命しない。
- **at-most-once 分類器を 1 箇所に**: 失敗を「配達前と証明できる → 再送・再確立して良い」「配達後または不明 → surface のみ(自動再送禁止)」に分ける classifier を 1 箇所に置く。catalog transaction の commit 判定と同型の分類原理。
- **cache 意味論は明示契約に**: staleness を caller の行動が左右する cache は、隠さず policy として可視化する(設定/フラグ、または addressing の文法に名前を出す)。強制 refresh は cache を**置換**する(バイパスだと古い snapshot が後続で復活する)。invalidation の owner は 1 箇所。
- **wait/poll は第一級パラメータ**: default は 0(fail fast)。retry 可否は error 型の性質(typed property)で判定し、ループ側の一律 retry にしない。非 0 default は隠れ retry。
- **揮発する外部事実には validity scope を宣言**: 「この値は現在の操作でのみ有効・跨いで cache しない」を owner の doc に明文化し、推測 fallback に落ちた場合は必ず表面化する(advisory)。
- **staleness は「検知するか、明示的に disclaim するか」の二択**: 検知もせず宣言もしない中間解は silent 誤動作(古い値での実行)を生む。検知は code に、規範は doc に、の順。

## §4. surface / process(→ タスク C/D、監査 F5/F9)

- **typo redirect**: public surface の名前を消す/動かすときは、旧名アクセスを入口で捕捉して正準名+利用者の入力を再構成した例を返す(暫定層と明示し、次 major で削除)。
- **wire shape の snapshot test を契約書に**: 外部が pin する schema(応答 envelope、discovery file)は決定的バイト列の snapshot test で固定し、「変更するなら snapshot と documented schema を両方更新」の手順を test doc に明記する。
- **CI 層化**: 依存ゼロの静的契約チェック(全 PR・最安 runner)→ pure unit → macOS unit(実機/実 Xcode 不要を維持)→ built binary の起動 smoke(link/rpath 回帰)→ live E2E は env gate。既存の env-gated live suite に smoke 層を足す。

## アンチパターン(採らない形)

| 形 | なぜ採らないか |
|---|---|
| 文字列 substring によるエラー分類 | prose が事実上の wire 契約になり、文言変更で分類が silent に劣化する。kind は throw site で型に付与する |
| staleness の中間解(検知も disclaim もしない) | 古い値での silent 誤動作。二択(§3)に倒す |
| 変動軸の部分吸収 | 分類だけ吸収して dispatch / capability 宣言を残すと、variant 追加が全域編集のまま。variant 追加テストはサブ軸ごと(新種別 / 新フラグ / 新 backend)に行う |
| 未対応の組合せの扱い混在 | 同じ「未対応」が場所により throw / redirect / silent ignore に割れると consumer は予測不能。1 契約に統一し、silent ignore は禁止 |
| 同一 wire shape の encoder 二重化 | 契約の owner が 2 箇所に割れ、整合が snapshot test と規約頼みになる |
| 単一 slot への複数 advisory の lossy merge | typed field が複数要素で信頼できなくなる。複数があり得るなら array |
| 宣言だけの契約軸 | 検査点(CI/runtime)の無い互換宣言は drift を検知できない |
