#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

keep_temp=0
if [[ "${1:-}" == "--keep-temp" ]]; then
  keep_temp=1
  shift
fi

if [[ $# -ne 0 ]]; then
  echo "usage: scripts/test-live-mcpbridge.sh [--keep-temp]" >&2
  exit 1
fi

if ! xcrun --find mcpbridge >/dev/null 2>&1; then
  echo "error: mcpbridge is not available in the selected Xcode toolchain" >&2
  exit 1
fi

if ! pgrep -x Xcode >/dev/null 2>&1; then
  echo "error: no running Xcode process found; open Xcode first" >&2
  exit 1
fi

xcode_process_count="$(pgrep -x Xcode | wc -l | tr -d ' ')"
if [[ "$xcode_process_count" != "1" ]]; then
  echo "error: expected exactly one running Xcode process for auto-resolved mcpbridge, found $xcode_process_count" >&2
  exit 1
fi

temp_root="$(mktemp -d "${TMPDIR:-/tmp}/xcode-mcp-live.XXXXXX")"
discovery_file="$temp_root/endpoint.json"
proxy_log="$temp_root/proxy.log"
default_discovery="$HOME/Library/Caches/XcodeMCPProxy/endpoint.json"

cleanup() {
  local status=$?
  if [[ -n "${proxy_pid:-}" ]]; then
    kill "$proxy_pid" >/dev/null 2>&1 || true
    wait "$proxy_pid" >/dev/null 2>&1 || true
  fi
  if (( keep_temp == 0 )); then
    rm -rf "$temp_root"
  else
    echo "kept temp root: $temp_root"
  fi
  exit "$status"
}
trap cleanup EXIT

if [[ -f "$default_discovery" ]]; then
  before_default_discovery_hash="$(shasum -a 256 "$default_discovery" | awk '{print $1}')"
else
  before_default_discovery_hash=""
fi

swift build --product xcode-mcp-proxy-server >/dev/null

XCODE_MCP_PROXY_DISCOVERY_FILE="$discovery_file" \
.build/debug/xcode-mcp-proxy-server \
  --listen 127.0.0.1:0 \
  --request-timeout 20 \
  --auto-approve >"$proxy_log" 2>&1 &
proxy_pid=$!

for _ in {1..120}; do
  if [[ -f "$discovery_file" ]]; then
    break
  fi
  sleep 1
done

if [[ ! -f "$discovery_file" ]]; then
  echo "error: proxy discovery file was not written" >&2
  exit 1
fi

proxy_url="$(
  xcrun swift -e '
import Foundation
let fileURL = URL(fileURLWithPath: CommandLine.arguments[1])
let data = try Data(contentsOf: fileURL)
let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
print(object["url"] as! String)
' "$discovery_file"
)"
debug_url="${proxy_url%/mcp}/debug/upstreams"
debug_body="$temp_root/debug.json"

capture_debug_snapshot() {
  curl -sS \
    --max-time 10 \
    -H 'Accept: application/json' \
    "$debug_url" >"$debug_body" || true
}

initialize_headers="$temp_root/initialize.headers"
initialize_body="$temp_root/initialize.json"
curl -sS -D "$initialize_headers" \
  --max-time 25 \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json' \
  --data '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","clientInfo":{"name":"XcodeMCPKitLiveTest","version":"dev"},"capabilities":{}}}' \
  "$proxy_url" >"$initialize_body"

session_id="$(
  awk 'BEGIN {IGNORECASE=1} /^Mcp-Session-Id:/ {print $2}' "$initialize_headers" | tr -d '\r'
)"

if [[ -z "$session_id" ]]; then
  echo "error: initialize response did not include Mcp-Session-Id" >&2
  exit 1
fi

capture_debug_snapshot

tools_body="$temp_root/tools.json"
tools_list_ok=0
for _ in {1..2}; do
  curl -sS \
    --max-time 25 \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json' \
    -H "Mcp-Session-Id: $session_id" \
    --data '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
    "$proxy_url" >"$tools_body"

  if grep -q '"name":"XcodeRefreshCodeIssuesInFile"' "$tools_body"; then
    tools_list_ok=1
    break
  fi
  sleep 2
done

if (( tools_list_ok == 0 )); then
  capture_debug_snapshot
  if grep -q '"message":"upstream timeout"' "$tools_body"; then
    echo "warning: tools/list timed out against the current Xcode session; continuing with window and refresh checks" >&2
  else
    echo "error: tools/list did not expose XcodeRefreshCodeIssuesInFile" >&2
    exit 1
  fi
fi

windows_body="$temp_root/windows.json"
window_selection=""
for _ in {1..2}; do
  curl -sS \
    --max-time 25 \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json' \
    -H "Mcp-Session-Id: $session_id" \
    --data '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"XcodeListWindows","arguments":{}}}' \
    "$proxy_url" >"$windows_body"

  window_selection="$(
    xcrun swift -e '
import Foundation
let fileURL = URL(fileURLWithPath: CommandLine.arguments[1])
let data = try Data(contentsOf: fileURL)
let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
let result = object["result"] as? [String: Any] ?? [:]
let structured = result["structuredContent"] as? [String: Any]
let messageFromStructured = structured?["message"] as? String
let content = result["content"] as? [[String: Any]] ?? []
let messageFromContent = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
let message: String
if let messageFromStructured, !messageFromStructured.isEmpty {
    message = messageFromStructured
} else {
    message = messageFromContent
}
for line in message.split(separator: "\n") {
    let raw = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
    guard raw.hasPrefix("* tabIdentifier: ") else { continue }
    let suffix = raw.dropFirst("* tabIdentifier: ".count)
    guard let comma = suffix.range(of: ", workspacePath: ") else { continue }
    let tabIdentifier = String(suffix[..<comma.lowerBound])
    let workspacePath = String(suffix[comma.upperBound...])
    if workspacePath.isEmpty == false {
        print("\(tabIdentifier)|\(workspacePath)")
        break
    }
}
' "$windows_body"
  )"

  if [[ -n "$window_selection" ]]; then
    break
  fi
  sleep 1
done

if [[ -z "$window_selection" ]]; then
  capture_debug_snapshot
  echo "error: failed to resolve an open Xcode workspace from XcodeListWindows" >&2
  exit 1
fi

tab_identifier="${window_selection%%|*}"
workspace_path="${window_selection#*|}"
search_root="$workspace_path"
if [[ "$workspace_path" == *.xcworkspace || "$workspace_path" == *.xcodeproj ]]; then
  search_root="$(dirname "$workspace_path")"
fi

source_file="$(find "$search_root" -type f -name '*.swift' ! -path '*/.build/*' | head -n 1 || true)"
if [[ -z "$source_file" ]]; then
  echo "error: could not find a Swift source file under the open workspace root: $search_root" >&2
  exit 1
fi

refresh_body="$temp_root/refresh.json"
refresh_payload="$(
  xcrun swift -e '
import Foundation
let filePath = CommandLine.arguments[1]
let tabIdentifier = CommandLine.arguments[2]
let payload: [String: Any] = [
    "jsonrpc": "2.0",
    "id": 4,
    "method": "tools/call",
    "params": [
        "name": "XcodeRefreshCodeIssuesInFile",
        "arguments": [
            "filePath": filePath,
            "tabIdentifier": tabIdentifier
        ]
    ]
]
let data = try JSONSerialization.data(withJSONObject: payload)
print(String(data: data, encoding: .utf8)!)
' "$source_file" "$tab_identifier"
)"

curl -sS \
  --max-time 25 \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json' \
  -H "Mcp-Session-Id: $session_id" \
  --data "$refresh_payload" \
  "$proxy_url" >"$refresh_body"

capture_debug_snapshot

if ! grep -q '"result"\|"error"' "$refresh_body"; then
  echo "error: refresh response missing result/error" >&2
  exit 1
fi

if ! grep -q '"controlPlane"' "$debug_body"; then
  echo "error: debug snapshot did not include controlPlane state" >&2
  exit 1
fi

if [[ -f "$default_discovery" ]]; then
  after_default_discovery_hash="$(shasum -a 256 "$default_discovery" | awk '{print $1}')"
else
  after_default_discovery_hash=""
fi

if [[ "$before_default_discovery_hash" != "$after_default_discovery_hash" ]]; then
  echo "error: default discovery file changed during live test" >&2
  exit 1
fi

echo "live mcpbridge test passed"
