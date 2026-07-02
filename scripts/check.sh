#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$repo_root"

begin_group() {
  local name="$1"
  if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    printf '::group::%s\n' "$name"
  else
    printf '==> %s\n' "$name"
  fi
}

end_group() {
  if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    printf '::endgroup::\n'
  fi
}

run_group() {
  local name="$1"
  shift

  begin_group "$name"
  set +e
  "$@"
  local status=$?
  set -e
  end_group
  return "$status"
}

run_with_ci_watchdog() {
  if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    "$repo_root/scripts/ci-test-watchdog.sh" "$@"
  else
    "$@"
  fi
}

run_group "swift test" run_with_ci_watchdog swift test \
  --no-parallel \
  -Xswiftc -strict-concurrency=minimal

run_group "XcodeMCPProcessRuntimeTests" run_with_ci_watchdog env XCODE_MCP_RUN_PROCESS_TESTS=1 swift test \
  --no-parallel \
  --filter XcodeMCPProcessRuntimeTests \
  -Xswiftc -strict-concurrency=minimal

run_group "ProxyStdioAdapterTests" run_with_ci_watchdog env XCODE_MCP_RUN_PROCESS_TESTS=1 swift test \
  --no-parallel \
  --filter ProxyStdioAdapterTests \
  -Xswiftc -strict-concurrency=minimal
