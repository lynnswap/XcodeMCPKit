#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

if ! command -v rg >/dev/null 2>&1; then
  echo "error: scripts/check-architecture.sh requires rg" >&2
  exit 1
fi

required_dirs=(
  "Sources/ProxyCore"
  "Sources/ProxyMCP"
  "Sources/ProxySession"
  "Sources/ProxyXcodeSupport"
  "Sources/ProxyXcodeFeatures"
  "Sources/ProxyHTTPGateway"
  "Sources/ProxyStdioTransport"
  "Sources/XcodeMCPProxy"
  "Sources/ProxyCLI"
)

for dir in "${required_dirs[@]}"; do
  if [[ ! -d "$dir" ]]; then
    echo "error: missing required source directory: $dir" >&2
    exit 1
  fi
done

violations=0

check_forbidden_imports() {
  local dir="$1"
  shift
  local modules=("$@")
  local pattern
  pattern="$(printf '%s|' "${modules[@]}")"
  pattern="${pattern%|}"
  local matches
  matches="$(rg -n "^import (${pattern})$" "$dir" || true)"
  if [[ -n "$matches" ]]; then
    echo "error: forbidden imports detected in $dir" >&2
    echo "$matches" >&2
    violations=1
  fi
}

check_forbidden_imports "Sources/ProxyCore" \
  ProxySession ProxyXcodeSupport ProxyXcodeFeatures ProxyHTTPGateway ProxyStdioTransport XcodeMCPProxy ProxyCLI
check_forbidden_imports "Sources/ProxyMCP" \
  ProxySession ProxyXcodeSupport ProxyXcodeFeatures ProxyHTTPGateway ProxyStdioTransport XcodeMCPProxy ProxyCLI
check_forbidden_imports "Sources/ProxySession" \
  ProxyXcodeSupport ProxyXcodeFeatures ProxyHTTPGateway ProxyStdioTransport XcodeMCPProxy ProxyCLI
check_forbidden_imports "Sources/ProxyXcodeSupport" \
  ProxyMCP ProxySession ProxyXcodeFeatures ProxyHTTPGateway ProxyStdioTransport XcodeMCPProxy ProxyCLI
check_forbidden_imports "Sources/ProxyXcodeFeatures" \
  ProxySession ProxyHTTPGateway ProxyStdioTransport XcodeMCPProxy ProxyCLI
check_forbidden_imports "Sources/ProxyHTTPGateway" \
  ProxyStdioTransport XcodeMCPProxy ProxyCLI
check_forbidden_imports "Sources/ProxyStdioTransport" \
  ProxySession ProxyXcodeSupport ProxyXcodeFeatures ProxyHTTPGateway XcodeMCPProxy ProxyCLI
check_forbidden_imports "Sources/ProxyCLI" \
  ProxyCore ProxyMCP ProxySession ProxyXcodeSupport ProxyXcodeFeatures ProxyHTTPGateway ProxyStdioTransport

if (( violations != 0 )); then
  exit 1
fi
