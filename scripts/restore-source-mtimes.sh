#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$repo_root"

while IFS= read -r -d '' path; do
  blob="$(git rev-parse "HEAD:$path")"
  if [[ -z "$blob" ]]; then
    echo "No blob found for tracked build input: $path" >&2
    exit 1
  fi
  # Swift's incremental build record compares input mtimes. Deriving the
  # timestamp from content keeps unchanged inputs stable across checkouts and
  # guarantees changed content does not collide merely because two commits
  # share a timestamp.
  timestamp=$((16#${blob:0:8}))
  touch -t "$(date -r "$timestamp" +%Y%m%d%H%M.%S)" "$path"
done < <(
  git ls-files -z -- \
    Package.swift \
    Package.resolved \
    Plugins \
    Sources \
    Tests
)

# The build-info command reads Git state, which is intentionally not a tracked
# SwiftPM input. Remove only its generated output so a restored cache cannot
# retain the version string from the commit that produced the cache.
find .build \
  -type f \
  -path '*/ProxyBuildInfoPlugin/BuildInfo.generated.swift' \
  -delete 2> /dev/null || true
