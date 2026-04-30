#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$repo_root"

swift test \
  -Xswiftc -strict-concurrency=minimal

XCODE_MCP_RUN_PROCESS_TESTS=1 swift test \
  --no-parallel \
  --filter ProxyProcessTests \
  -Xswiftc -strict-concurrency=minimal
