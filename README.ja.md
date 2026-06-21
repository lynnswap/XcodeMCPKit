# XcodeMCPKit

[English](README.md)

XcodeMCPKitは、Xcode MCPのためのローカルプロキシです。MCPクライアントに安定したendpointを提供し、`mcpbridge`の承認フローを自動化します。

## 要件

- macOS 15.0+
- Swift 6.2+

## インストール

### GitHub Releasesからインストール

```bash
curl -fsSL https://github.com/lynnswap/XcodeMCPKit/releases/latest/download/install.sh | sh
```

<details>
<summary>その他のインストール方法</summary>

インストール先を変える場合:

```bash
curl -fsSL https://github.com/lynnswap/XcodeMCPKit/releases/latest/download/install.sh | sh -s -- --bindir "$HOME/bin"
```

バージョンを指定する場合:

```bash
curl -fsSL https://github.com/lynnswap/XcodeMCPKit/releases/download/v0.11.0/install.sh | sh
```

### ソースからインストール

proxy serverとSTDIO adapterをまとめてインストールします:

```bash
swift run -c release xcode-mcp-proxy-install
```

インストール先を変える場合:

```bash
swift run -c release xcode-mcp-proxy-install --prefix "$HOME/.local"
swift run -c release xcode-mcp-proxy-install --bindir "$HOME/bin"
```

`PATH`に追加:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

</details>

## MCPクライアント設定

### 1. プロキシサーバーを起動

```bash
xcode-mcp-proxy-server --auto-approve
```

`--auto-approve`はXcodeの**Allow**ボタンを自動でクリックします。macOSのAccessibility権限が必要です。

Accessibility権限を付けられない場合は、`--auto-approve`を外して、手動で**Allow**ボタンを押してください:

```bash
xcode-mcp-proxy-server
```

### 2. クライアントに登録

`xcrun mcpbridge`をproxy endpointに置き換えます。

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

CLI help:

```bash
xcode-mcp-proxy-server --help
xcode-mcp-proxy --help
```

### Server options

| Option | 説明 |
|--------|------|
| `--listen host:port` | listen address。既定値は`localhost:8765`。 |
| `--host host` / `--port port` | `--listen`を使わない場合のlisten host / port。 |
| `--upstream-processes n` | upstream `mcpbridge` process数。既定値は`1`、最大`10`。 |
| `--request-timeout seconds` | request timeout。`0`で`initialize`以外のtimeoutを無効化します。`initialize`には固定のhandshake timeoutがあります。 |
| `--config path` | TOML config path。 |
| `--auto-approve` | Xcodeの**Allow**ボタンを自動でクリックします。Accessibility権限が必要です。 |
| `--refresh-code-issues-mode proxy|upstream` | `XcodeRefreshCodeIssuesInFile`をproxy diagnosticsで提供するか（`proxy`、既定値）、Xcode live diagnosticsにpass-throughするか（`upstream`）。 |
| `--force-restart` | listen port上の既存`xcode-mcp-proxy-server`を終了して新しく起動します。 |

### Environment Variables

| Variable | 説明 |
|------|------|
| `LISTEN` | listen address。例:`127.0.0.1:8765`。 |
| `HOST` / `PORT` | `LISTEN`未指定時のlisten host / port。 |
| `MCP_XCODE_PID` | upstream `mcpbridge`へそのまま渡します。proxy自身は解釈しません。 |
| `MCP_XCODE_SESSION_ID` | 明示的に指定するupstream Xcode MCP session ID。 |
| `MCP_XCODE_CONFIG` | TOML config path。`--config`が優先されます。 |
| `MCP_XCODE_REFRESH_CODE_ISSUES_MODE` | `proxy`または`upstream`。 |
| `MCP_LOG_LEVEL` | `trace`, `debug`, `info`, `notice`, `warning`, `error`, `critical`。 |
| `XCODE_MCP_PROXY_ENDPOINT` | STDIO adapterのupstream URL。`--url`が優先されます。 |
| `XCODE_MCP_PROXY_DISCOVERY_FILE` | 隔離されたlocal/live test run向けのdiscovery file override。 |
| `XCODE_MCP_PROXY_CACHE_ROOT` | `XCODE_MCP_PROXY_DISCOVERY_FILE`未指定時にdiscovery pathを導出するcache root。 |

### TOML Config

```toml
[upstream_handshake]
clientName = "XcodeMCPKit"

[tools]
disabled = ["RunAllTests", "RunSomeTests"]
```

| Key | Type | Default |
|-----|----|--------|
| `upstream_handshake.clientName` | string | `"XcodeMCPKit"` |
| `upstream_handshake.clientVersion` | string | `"dev"` |
| `upstream_handshake.capabilities` | table | `{}` |
| `tools.disabled` | array of strings | `[]` |

- `clientVersion`省略時: Xcodeの`IDEChat*Version` defaults entryから解決します。
- disabled toolは`tools/list`から削除し、直接の`tools/call`は拒否します。
- config変更後は`xcode-mcp-proxy-server`を再起動してください。

## 移行

### v0.11.0

Codex/Claude Codeから利用している場合は、移行作業はありません。
以下のどちらかに当てはまる場合だけ対応してください。

- Streamable HTTP endpointを直接呼んでいる場合:
  `initialize`後はserverが発行した`MCP-Session-Id`と
  `MCP-Protocol-Version: 2025-06-18`を送り、`POST /mcp`には
  `Accept: application/json, text/event-stream`を付けてください。
  JSON-RPC batch requestは送らないでください。
- SwiftPM library productに依存している場合:
  `v0.10.2`に固定するか、executable productに移行してください。

## Troubleshooting

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

## Documentation

- [Architecture](Docs/architecture.md)
- [Troubleshooting](Docs/troubleshooting.md)
- [MCP / Xcode MCP Benchmark Notes](Docs/mcp-benchmark.md)
- [MCP Connection Permission Dialog Investigation](Docs/mcp-permission-dialog-investigation.md)

## License

[LICENSE](LICENSE)
