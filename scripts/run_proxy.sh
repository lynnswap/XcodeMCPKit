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
  STDIO_ARGS=()
  if [[ -n "${STDIO_FRAMING:-}" ]]; then
    STDIO_ARGS+=(--stdio-framing "$STDIO_FRAMING")
  fi

  if [[ -n "${STDIO_NO_PROXY:-}" ]]; then
    PROXY_ARGS=(--no-spawn-proxy --proxy-listen "$LISTEN")
    if [[ -n "${XCODE_PID:-}" ]]; then
      PROXY_ARGS+=(--proxy-xcode-pid "$XCODE_PID")
    fi
    if [[ -n "$LAZY_INIT" ]]; then
      PROXY_ARGS+=(--proxy-lazy-init)
    fi
    exec swift run xcode-mcp-stdio-proxy "${PROXY_ARGS[@]}" "${STDIO_ARGS[@]}"
  else
    exec swift run xcode-mcp-proxy "${ARGS[@]}" --stdio "${STDIO_ARGS[@]}"
  fi
else
  exec swift run xcode-mcp-proxy "${ARGS[@]}"
fi
