# XcodeMCPKit

[English](README.md)

Xcode MCP (mcpbridge) の MCPプロキシ。  
Xcode のダイアログが、プロキシ起動時に一度だけ表示されるよう設計しています。

## クイックスタート

1. プロキシサーバーを起動
   ```bash
   xcode-mcp-proxy-server --auto-approve
   ```
2. 自動承認に必要な macOS の「アクセシビリティ」権限を許可

`--auto-approve` オプションを使用すると、Xcode の承認ダイアログを監視し、自動で「許可（Allow）」をクリックします。

この機能を利用するには、macOS の「アクセシビリティ」権限が必要なため、デフォルトでは無効（オプトイン方式）になっています。もし権限を与えたくない場合は、`--auto-approve` を付けずにサーバーを起動し、Xcode 上で手動で「許可」をクリックしてください。

## アーキテクチャ

プロセス構成は [アーキテクチャ](Docs/architecture.md) を参照してください。
モジュール境界とローカル検証コマンドは [Maintainer Architecture](Docs/maintainer-architecture.md) を参照してください。

## インストール

### 1. バイナリをインストール

#### ソースからビルドしてインストール

```bash
swift run -c release xcode-mcp-proxy-install
```

#### GitHub Releases からインストール

各リリースタグ（`v*`）では、次のファイルを公開します:

- `xcode-mcp-proxy.tar.gz`（universal binary）
- `xcode-mcp-proxy-darwin-arm64.tar.gz`
- `xcode-mcp-proxy-darwin-x86_64.tar.gz`
- `SHA256SUMS.txt`

例:

```bash
VERSION=v0.1.0
BASE_URL="https://github.com/lynnswap/XcodeMCPKit/releases/download/${VERSION}"

ARCHIVE="xcode-mcp-proxy.tar.gz"
curl -fL -O "${BASE_URL}/${ARCHIVE}"
curl -fL -O "${BASE_URL}/SHA256SUMS.txt"
grep "  ${ARCHIVE}\$" SHA256SUMS.txt | shasum -a 256 -c

tar -xzf "${ARCHIVE}"
mkdir -p "${HOME}/.local/bin"
cp bin/* "${HOME}/.local/bin/"
chmod +x "${HOME}/.local/bin/xcode-mcp-proxy" \
         "${HOME}/.local/bin/xcode-mcp-proxy-server" \
         "${HOME}/.local/bin/xcode-mcp-proxy-install"
```

プラットフォーム別アーカイブを使いたい場合は、次のいずれかを選べます:

- `xcode-mcp-proxy.tar.gz`: universal binary
- `xcode-mcp-proxy-darwin-arm64.tar.gz`: Apple Silicon
- `xcode-mcp-proxy-darwin-x86_64.tar.gz`: Intel

#### 任意: インストール先を変更

```bash
./.build/release/xcode-mcp-proxy-install --prefix "$HOME/.local"
# または
./.build/release/xcode-mcp-proxy-install --bindir "$HOME/bin"
```

### 2. インストール先を `PATH` に追加

既定では `~/.local/bin` に `xcode-mcp-proxy` と `xcode-mcp-proxy-server` がインストールされます。

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

### 3. MCP クライアントに登録

`xcrun mcpbridge` を削除して、用途に応じて以下のいずれかを登録します:

#### Codex

```bash
codex mcp remove xcode
# 推奨: Streamable HTTP
codex mcp add xcode --url http://localhost:8765/mcp

# 代替: STDIO
codex mcp add xcode -- xcode-mcp-proxy
```

#### Claude Code

```bash
claude mcp remove xcode
claude mcp add --transport stdio xcode -- xcode-mcp-proxy
```

## 使い方

### プロキシサーバー: `xcode-mcp-proxy-server`

起動方法は「クイックスタート」を参照してください。

#### デフォルト値

- command: `xcrun`
- args: `mcpbridge`
- upstream processes: `1`（増やすと `mcpbridge` を複数プロセス起動）
- listen: `localhost:8765`
- request timeout: `300` seconds（`0` で無制限）
- max body size: `1048576` bytes
- initialization: eager at startup
- discovery: `~/Library/Caches/XcodeMCPProxy/endpoint.json`

#### オプション

| オプション | 説明 |
|--------|-------------|
| `--upstream-command cmd` | `mcpbridge` 実行コマンド |
| `--upstream-args a,b,c` | `mcpbridge` 引数（カンマ区切り） |
| `--upstream-arg value` | `mcpbridge` 引数の追加（単一項目） |
| `--upstream-processes n` | アップストリーム `mcpbridge` プロセスの起動数（デフォルト: 1、最大: 10） |
| `--session-id id` | 明示的な Xcode MCP セッション ID |
| `--max-body-bytes n` | リクエストボディの最大サイズ |
| `--request-timeout seconds` | リクエストタイムアウト設定（`0` で初期化以外のタイムアウトを無効化。`initialize` 時のハンドシェイクには固定のタイムアウトが適用されます） |
| `--config path` | アップストリームのハンドシェイクを上書きするためのプロキシ設定（TOML）のパス |
| `--auto-approve` | Xcode の許可ダイアログ自動承認を有効化する opt-in フラグ |
| `--refresh-code-issues-mode mode` | `XcodeRefreshCodeIssuesInFile` の提供モード。プロキシ側のナビゲーター問題として処理（`proxy`、デフォルト）、または Xcode のライブ診断へパススルー（`upstream`） |
| `--force-restart` | ポートが使用中の場合、既存の `xcode-mcp-proxy-server` を終了して再起動 |

#### 環境変数

| 変数 | 説明 |
|------|------|
| `LISTEN` | listen アドレス。例: `127.0.0.1:8765` |
| `HOST` | listen ホスト。`LISTEN` 未指定時に `PORT` と組み合わせて使用 |
| `PORT` | listen ポート。`LISTEN` 未指定時に `HOST` と組み合わせて使用 |
| `MCP_XCODE_PID` | upstream `mcpbridge` へそのまま渡す互換 env。proxy 自身は解釈しない |
| `MCP_XCODE_SESSION_ID` | 任意の明示的 upstream session ID |
| `MCP_XCODE_CONFIG` | proxy config TOML のパス。`--config` が優先 |
| `MCP_XCODE_REFRESH_CODE_ISSUES_MODE` | `proxy` または `upstream` |
| `MCP_LOG_LEVEL` | ログレベル: `trace`, `debug`, `info`, `notice`, `warning`, `error`, `critical` |
| `XCODE_MCP_PROXY_DISCOVERY_FILE` | discovery file の出力先を上書きします。隔離されたローカル/live テスト向けです |
| `XCODE_MCP_PROXY_CACHE_ROOT` | `XCODE_MCP_PROXY_DISCOVERY_FILE` 未指定時の discovery 用 cache root を上書きします |

ログは stderr に出力されます。

## Maintainer Commands

```bash
scripts/check-architecture.sh
scripts/test-fast.sh
scripts/test-process.sh
scripts/check.sh
scripts/test-live-mcpbridge.sh
```

- `test-live-mcpbridge.sh` はローカル専用で、CI には含めません。
- live script は現在起動中の Xcode を使い、Xcode process が 1 つだけある前提で、`127.0.0.1:0` と temp discovery path を使います。

#### Proxy Config

| キー | 型 | 既定値 |
|------|----|--------|
| `upstream_handshake.protocolVersion` | string | `"2025-03-26"` |
| `upstream_handshake.clientName` | string | `"XcodeMCPKit"` |
| `upstream_handshake.clientVersion` | string | `"dev"` |
| `upstream_handshake.capabilities` | table | `{}` |

`clientVersion` を省略した場合、`clientName` に対応する Xcode の `IDEChat*Version` があれば、その version を自動で使います。

### アダプタ: `xcode-mcp-proxy`

#### オプション

| オプション | 説明 |
|-----------|------|
| `--request-timeout seconds` | HTTP リクエストタイムアウト（`0` で無制限） |
| `--url url` | 上流 URL を明示（例: `http://localhost:9000/mcp`） |

#### 環境変数

| 変数 | 説明 |
|------|------|
| `XCODE_MCP_PROXY_ENDPOINT` | 上流 URL を上書き。`--url` が優先 |

## トラブルシューティング

[Troubleshooting](Docs/troubleshooting.md)

## 参考資料

- [MCP / Xcode MCP Benchmark Notes](Docs/mcp-benchmark.md)
- [MCP Connection Permission Dialog Investigation](Docs/mcp-permission-dialog-investigation.md)

## ライセンス

[LICENSE](LICENSE)
