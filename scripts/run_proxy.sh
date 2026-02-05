#!/bin/bash
set -euo pipefail

HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-8765}"
LISTEN="${LISTEN:-$HOST:$PORT}"
XCODE_PID="${XCODE_PID:-${MCP_XCODE_PID:-}}"
LAZY_INIT="${LAZY_INIT:-}"
DRY_RUN="${DRY_RUN:-}"
STDIO="${STDIO:-}"

if [[ "${1:-}" == "--stdio" ]]; then
  STDIO=1
  shift
fi

resolve_xcode_pid() {
  local pid=""

  if [[ -n "$XCODE_PID" ]]; then
    echo "$XCODE_PID"
    return 0
  fi

  pid="$(pgrep -x Xcode | head -n 1 || true)"
  if [[ -z "$pid" ]]; then
    pid="$(pgrep -f "/Applications/Xcode.*\\.app/Contents/MacOS/Xcode" | head -n 1 || true)"
  fi
  if [[ -z "$pid" ]]; then
    pid="$(pgrep -f "Xcode.app/Contents/MacOS/Xcode" | head -n 1 || true)"
  fi

  if [[ -z "$pid" ]]; then
    return 1
  fi

  echo "$pid"
  return 0
}

ARGS=(--listen "$LISTEN")

if XCODE_PID="$(resolve_xcode_pid)"; then
  ARGS+=(--xcode-pid "$XCODE_PID")
else
  open -a Xcode >/dev/null 2>&1 || true
  for _ in {1..40}; do
    if XCODE_PID="$(resolve_xcode_pid)"; then
      ARGS+=(--xcode-pid "$XCODE_PID")
      break
    fi
    sleep 0.25
  done
fi

if [[ -z "${XCODE_PID:-}" ]]; then
  echo "warning: Xcode PID not found; running without --xcode-pid." >&2
fi

if [[ -n "$DRY_RUN" ]]; then
  printf '%s\n' "${ARGS[@]}"
  exit 0
fi
if [[ -n "$LAZY_INIT" ]]; then
  ARGS+=(--lazy-init)
fi

if [[ -n "$STDIO" ]]; then
  if [[ -z "${STDIO_NO_PROXY:-}" ]]; then
    swift run xcode-mcp-proxy "${ARGS[@]}" &
    PROXY_PID=$!
    trap 'kill $PROXY_PID' EXIT
  fi
  STDIO_ARGS=(--no-spawn-proxy --proxy-listen "$LISTEN")
  if [[ -n "${XCODE_PID:-}" ]]; then
    STDIO_ARGS+=(--proxy-xcode-pid "$XCODE_PID")
  fi
  if [[ -n "$LAZY_INIT" ]]; then
    STDIO_ARGS+=(--proxy-lazy-init)
  fi
  swift run xcode-mcp-stdio-proxy "${STDIO_ARGS[@]}"
  exit $?
else
  exec swift run xcode-mcp-proxy "${ARGS[@]}"
fi
