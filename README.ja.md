# XcodeMCPKit

[English](README.md)

XcodeMCPKit は、Xcode MCP のためのローカルプロキシです。MCP クライアントに安定した endpoint を提供し、`mcpbridge` の承認フローを自動化します。

## 要件

- macOS 15.0+
- Swift 6.2+

## インストール

### GitHub Releases からインストール

```bash
curl -fsSL https://github.com/lynnswap/XcodeMCPKit/releases/download/v0.11.0/install.sh | sh
```

インストール先を変える場合:

```bash
curl -fsSL https://github.com/lynnswap/XcodeMCPKit/releases/download/v0.11.0/install.sh | BINDIR="$HOME/bin" sh
```

### ソースからインストール

proxy server と STDIO adapter の両方をインストールします:

```bash
swift run -c release xcode-mcp-proxy-install
```

インストール先を変える場合:

```bash
swift run -c release xcode-mcp-proxy-install --prefix "$HOME/.local"
swift run -c release xcode-mcp-proxy-install --bindir "$HOME/bin"
```

`PATH` に追加:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

## MCP クライアント設定

### 1. プロキシサーバーを起動

```bash
xcode-mcp-proxy-server --auto-approve
```

Accessibility 権限を付けられない場合:

```bash
xcode-mcp-proxy-server
```

### 2. クライアントに登録

`xcrun mcpbridge` を proxy endpoint に置き換えます。

#### Codex

```bash
codex mcp remove xcode

# 推奨: Streamable HTTP
codex mcp add xcode --url http://localhost:8765/mcp

# 互換モード: STDIO
codex mcp add xcode -- xcode-mcp-proxy
```

#### Claude Code

```bash
claude mcp remove xcode

# 推奨: Streamable HTTP
claude mcp add --transport http xcode http://localhost:8765/mcp

# 互換モード: STDIO
claude mcp add --transport stdio xcode -- xcode-mcp-proxy
```

## 設定

CLI 全体:

```bash
xcode-mcp-proxy-server --help
xcode-mcp-proxy --help
```

### よく使う server option

| Option | 説明 |
|--------|------|
| `--listen host:port` | listen address。既定値は `localhost:8765`。 |
| `--host host` / `--port port` | `--listen` を使わない場合の listen host / port。 |
| `--upstream-processes n` | upstream `mcpbridge` process 数。既定値は `1`、最大 `10`。 |
| `--request-timeout seconds` | request timeout。`0` で initialize 以外の timeout を無効化します。initialize には固定の handshake timeout があります。 |
| `--config path` | TOML config path。 |
| `--auto-approve` | Xcode の許可ダイアログを自動承認します。Accessibility 権限が必要です。 |
| `--refresh-code-issues-mode proxy|upstream` | `XcodeRefreshCodeIssuesInFile` を proxy diagnostics で提供するか（`proxy`、既定値）、Xcode live diagnostics に pass-through するか（`upstream`）。 |
| `--force-restart` | listen port 上の既存 `xcode-mcp-proxy-server` を終了して新しく起動します。 |

### 環境変数

| 変数 | 説明 |
|------|------|
| `LISTEN` | listen address。例: `127.0.0.1:8765`。 |
| `HOST` / `PORT` | `LISTEN` 未指定時の listen host / port。 |
| `MCP_XCODE_PID` | upstream `mcpbridge` へそのまま渡します。proxy 自身は解釈しません。 |
| `MCP_XCODE_SESSION_ID` | 任意の明示的な upstream Xcode MCP session ID。 |
| `MCP_XCODE_CONFIG` | TOML config path。`--config` が優先されます。 |
| `MCP_XCODE_REFRESH_CODE_ISSUES_MODE` | `proxy` または `upstream`。 |
| `MCP_LOG_LEVEL` | `trace`, `debug`, `info`, `notice`, `warning`, `error`, `critical`。 |
| `XCODE_MCP_PROXY_ENDPOINT` | STDIO adapter の upstream URL。`--url` が優先されます。 |
| `XCODE_MCP_PROXY_DISCOVERY_FILE` | 隔離された local/live test run 向けの discovery file override。 |
| `XCODE_MCP_PROXY_CACHE_ROOT` | `XCODE_MCP_PROXY_DISCOVERY_FILE` 未指定時に discovery path を導出する cache root。 |

### TOML Config

```toml
[upstream_handshake]
clientName = "XcodeMCPKit"

[tools]
disabled = ["RunAllTests", "RunSomeTests"]
```

| Key | 型 | 既定値 |
|-----|----|--------|
| `upstream_handshake.clientName` | string | `"XcodeMCPKit"` |
| `upstream_handshake.clientVersion` | string | `"dev"` |
| `upstream_handshake.capabilities` | table | `{}` |
| `tools.disabled` | array of strings | `[]` |

- `clientVersion` 省略時: Xcode の `IDEChat*Version` defaults entry から解決します。
- disabled tool: `tools/list` から削除し、直接の `tools/call` は拒否します。
- config 変更後は `xcode-mcp-proxy-server` を再起動してください。

## 移行

### v0.11.0

Codex / Claude Code から利用している場合は、移行作業はありません。
以下のどちらかに当てはまる場合だけ対応してください。

- Streamable HTTP endpoint を直接呼んでいる場合:
  `initialize` 後は server が発行した `MCP-Session-Id` と
  `MCP-Protocol-Version: 2025-06-18` を送り、`POST /mcp` には
  `Accept: application/json, text/event-stream` を付けてください。
  JSON-RPC batch request は送らないでください。
- SwiftPM library product に依存している場合:
  `v0.10.2` に固定するか、executable product に移行してください。

## トラブルシューティング

- [Troubleshooting](Docs/troubleshooting.md)

## Maintainers

Local checks:

```bash
swift test -Xswiftc -strict-concurrency=minimal
XCODE_MCP_RUN_PROCESS_TESTS=1 swift test --no-parallel --filter ProxyProcessTests -Xswiftc -strict-concurrency=minimal
scripts/check.sh
```

Release:

```bash
scripts/publish-local-release.sh v0.11.0
```

- module boundary、release flow、live test、benchmark:
  [Maintainer Architecture](Docs/maintainer-architecture.md)

## 関連ドキュメント

- [Architecture](Docs/architecture.md)
- [Troubleshooting](Docs/troubleshooting.md)
- [MCP / Xcode MCP Benchmark Notes](Docs/mcp-benchmark.md)
- [MCP Connection Permission Dialog Investigation](Docs/mcp-permission-dialog-investigation.md)

## ライセンス

[LICENSE](LICENSE)
