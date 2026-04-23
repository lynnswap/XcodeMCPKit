#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

swift test \
  --no-parallel \
  --filter 'ProcessRunnerTests|UpstreamProcessTests|StdioAdapterIntegrationTests' \
  -Xswiftc -strict-concurrency=minimal
