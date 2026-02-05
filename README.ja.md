# XcodeMCPProxy

[English](README.md)

Xcode MCP (mcpbridge) の MCPプロキシ。  
Xcode のダイアログが、プロキシ起動時に一度だけ表示されるよう設計しています。

## クイックスタート

1. プロキシを起動
   ```bash
   scripts/run_proxy.sh
   ```
2. クライアントを `http://127.0.0.1:8765/mcp` に向ける（例は後述）
3. Xcode の許可ダイアログが出たら **Allow**

Codex を STDIO で使う場合は、`xcode-mcp-stdio-proxy` を起動してください（HTTP/SSE プロキシは自動起動します）。

## 特徴

- `mcpbridge` は **単一プロセスで運用**
- 複数クライアントは `Mcp-Session-Id` で分離
- JSON-RPC over HTTP + SSE（Streamable MCP）

## 使い方

### Run Script

```bash
scripts/run_proxy.sh
```

環境変数:

- `HOST` (既定: `127.0.0.1`)
- `PORT` (既定: `8765`)
- `LISTEN` (host/port を上書き)
- `XCODE_PID` (任意)
- `LAZY_INIT` (`--lazy-init` を付与)
- `STDIO` (STDIO モードで起動)
- `STDIO_NO_PROXY` (STDIO モード時に HTTP/SSE プロキシを起動しない)

### Manual Start

```bash
swift run xcode-mcp-proxy --listen 127.0.0.1:8765
```

Xcode MCP セッションは起動時に初期化し、Xcode の許可ダイアログが起動時に出るようにしています。`--lazy-init` で初期化を遅延させることもできます。

Xcode の対象を固定する場合:

```bash
swift run xcode-mcp-proxy --xcode-pid 12345
```

### STDIO Adapter (Codex)

```bash
swift run xcode-mcp-stdio-proxy
```

STDIO アダプタは HTTP/SSE プロキシを自動で起動します。既に起動済みの場合は `--no-spawn-proxy` を使ってください。  
`scripts/run_proxy.sh` で STDIO モードにする場合は `STDIO=1` を指定します（既定で HTTP/SSE プロキシも起動します）。

## デフォルト値

- Listen address: `127.0.0.1:8765`
- command: `xcrun`
- args: `mcpbridge`
- request timeout: `300` seconds（`0` で無制限）
- max body size: `1048576` bytes
- initialization: eager at startup

環境変数:

- `MCP_XCODE_PID`（`--xcode-pid` の代替）
- `MCP_XCODE_SESSION_ID`（Xcode MCP セッション ID を固定）
- `MCP_LOG_LEVEL`（ログレベル: trace|debug|info|notice|warning|error|critical）

ログは stderr に出力されます。

## オプション

| オプション | 説明 |
|-----------|------|
| `--listen host:port` | 待ち受けアドレス |
| `--host host` | 待ち受けホスト |
| `--port port` | 待ち受けポート |
| `--upstream-command cmd` | `mcpbridge` コマンド |
| `--upstream-args a,b,c` | `mcpbridge` 引数（カンマ区切り） |
| `--upstream-arg value` | `mcpbridge` 引数を1つ追加 |
| `--xcode-pid pid` | 対象 Xcode の PID |
| `--session-id id` | Xcode MCP セッション ID |
| `--max-body-bytes n` | 最大ボディサイズ |
| `--request-timeout seconds` | リクエストタイムアウト（`0` で無制限） |
| `--lazy-init` | 初回リクエストまで初期化を遅延 |

## クライアント設定

**Claude Code** (`~/.claude/settings.json`):

```json
{ "mcpServers": { "xcode": { "url": "http://127.0.0.1:8765/mcp" } } }
```

**Codex** (`~/.codex/config.toml`):

```toml
[mcp_servers.xcode]
url = "http://127.0.0.1:8765/mcp"
```

**Codex (STDIO)**:

```bash
codex mcp add xcode -- xcode-mcp-stdio-proxy
```

STDIO アダプタは起動時に HTTP/SSE プロキシを自動で立ち上げます。HTTP/SSE を別途起動済みの場合は `--no-spawn-proxy` を使ってください。

## エンドポイント

- `POST /mcp` (JSON-RPC。JSON か SSE で応答し `Mcp-Session-Id` を返します)
- `GET /mcp` (SSE。`Mcp-Session-Id` と `Accept: text/event-stream` が必要)
- `GET /events`, `GET /mcp/events` (SSE の別名)
- `DELETE /mcp` (セッション終了)
- `GET /health`

## セッションと複数クライアント

- クライアントごとに **異なる `Mcp-Session-Id`** を使ってください。
- `initialize` を `Mcp-Session-Id` なしで送ると、サーバーが生成してレスポンスヘッダで返します。
- SSE を使う場合は `GET /mcp` に `Mcp-Session-Id` を付与してください。

## トラブルシューティング

- `mcpbridge` が実行できない  
  Apple ドキュメントより引用:

  > In Terminal, use the xcrun mcpbridge command to configure the agentic coding tool to use Xcode Tools.

  参考: [Giving external agentic coding tools access to Xcode](https://developer.apple.com/documentation/Xcode/giving-agentic-coding-tools-access-to-xcode#Configure-external-coding-tools-to-use-the-MCP-server)

  ```bash
  claude mcp add --transport stdio xcode -- xcrun mcpbridge
  codex mcp add xcode -- xcrun mcpbridge
  ```

- `MCP client ... timed out`  
  プロキシが起動しているか確認し、必要なら `startup_timeout_sec` を増やしてください。

- Codex の `tools/call` が 60 秒でタイムアウトする  
  `~/.codex/config.toml` の `tool_timeout_sec` を増やしてください（Codex クライアント側の待ち時間設定で、プロキシの `--request-timeout` とは別です）。
  ```toml
  [mcp_servers.xcode]
  url = "http://127.0.0.1:8765/mcp"
  tool_timeout_sec = 300
  ```

- STDIO アダプタが起動時にエラーになる  
  `xcode-mcp-stdio-proxy --no-spawn-proxy` で起動し、HTTP/SSE プロキシを別途立ち上げてください。

- Xcode のダイアログが出ない  
  `--lazy-init` を指定していないか確認してください（指定している場合は最初のリクエストまでダイアログが出ません）。

- `session not found`  
  `Mcp-Session-Id` が一致しているか確認してください。

## ライセンス

[LICENSE](LICENSE)
