#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$repo_root"

# Keep restored inputs in a fixed historical range so they remain older than
# build outputs while retaining stable, content-derived mtimes across runners.
readonly timestamp_floor=946684800  # 2000-01-01T00:00:00Z
readonly timestamp_span=631152000   # 2000-01-01 through 2019-12-31

while IFS= read -r -d '' path; do
  blob="$(git rev-parse "HEAD:$path")"
  if [[ -z "$blob" ]]; then
    echo "No blob found for tracked build input: $path" >&2
    exit 1
  fi
  # Swift's incremental build record compares input mtimes. Mapping the blob
  # hash into the fixed range keeps unchanged inputs stable and makes changed
  # content overwhelmingly likely to receive a different timestamp.
  timestamp=$((timestamp_floor + (16#${blob:0:8} % timestamp_span)))
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
