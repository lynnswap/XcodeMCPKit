#!/bin/bash
# Runs a test command and watches its output for stalls. If the command
# produces no output for STALL_SECONDS, the test process has hung (the
# swift-testing runner emits events continuously); dump thread backtraces
# of every test-related process with `sample` so the hang site is visible
# in the CI log, then fail fast instead of waiting for the job timeout.
set -uo pipefail

STALL_SECONDS="${STALL_SECONDS:-120}"
POLL_SECONDS=10

log="$(mktemp -t ci-test-watchdog)"

"$@" > >(tee "$log") 2>&1 &
runner=$!

sample_process() {
    local pid=$1
    echo "===== sample of pid ${pid} ($(ps -o comm= -p "${pid}" 2>/dev/null)) ====="
    if command -v sudo > /dev/null 2>&1 && sudo -n true 2> /dev/null; then
        sudo sample "${pid}" 5 -mayDie 2>&1 || true
    else
        sample "${pid}" 5 -mayDie 2>&1 || true
    fi
}

dump_hang_diagnostics() {
    echo "::error::test run produced no output for ${STALL_SECONDS}s; dumping thread backtraces"
    ps -ef | grep -E 'swift|xctest' | grep -v grep || true
    local pids
    pids=$(pgrep -f 'swiftpm-testing-helper|PackageTests|xctest' || true)
    for pid in ${pids}; do
        sample_process "${pid}"
    done
    sample_process "${runner}"
}

last_size=-1
stalled_for=0
while kill -0 "${runner}" 2> /dev/null; do
    sleep "${POLL_SECONDS}"
    size=$(stat -f%z "${log}" 2> /dev/null || echo 0)
    if [ "${size}" -eq "${last_size}" ]; then
        stalled_for=$((stalled_for + POLL_SECONDS))
    else
        stalled_for=0
        last_size=${size}
    fi
    if [ "${stalled_for}" -ge "${STALL_SECONDS}" ]; then
        dump_hang_diagnostics
        pkill -9 -f 'swiftpm-testing-helper|PackageTests|xctest' || true
        kill -9 "${runner}" 2> /dev/null || true
        exit 70
    fi
done

wait "${runner}"
