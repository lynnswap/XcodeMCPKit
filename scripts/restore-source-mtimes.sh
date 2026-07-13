#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$repo_root"

while IFS= read -r -d '' path; do
  timestamp="$(git log -1 --format=%ct -- "$path")"
  if [[ -z "$timestamp" ]]; then
    echo "No commit timestamp found for tracked build input: $path" >&2
    exit 1
  fi
  touch -t "$(date -r "$timestamp" +%Y%m%d%H%M.%S)" "$path"
done < <(
  git ls-files -z -- \
    Package.swift \
    Package.resolved \
    Plugins \
    Sources \
    Tests
)
