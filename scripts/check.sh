#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"$repo_root/scripts/check-architecture.sh"
"$repo_root/scripts/test-fast.sh"
"$repo_root/scripts/test-process.sh"
