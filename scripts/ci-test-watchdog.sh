#!/bin/bash
# Runs a test command and watches its output for stalls. If the command
# produces no output for STALL_SECONDS, the test process is likely hung.
# Recheck before killing because Swift Testing can emit a completion line at
# the same moment the watchdog crosses the threshold. If it is still silent,
# dump thread backtraces of every test-related process with `sample` so the
# hang site is visible in the CI log, then fail fast instead of waiting for
# the job timeout.
set -uo pipefail

STALL_SECONDS="${STALL_SECONDS:-120}"
POLL_SECONDS=10
RESUME_RECHECK_SECONDS=5

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

log_size() {
    stat -f%z "${log}" 2> /dev/null || echo 0
}

wait_for_output_or_exit() {
    local stalled_size=$1
    local remaining=${RESUME_RECHECK_SECONDS}
    while [ "${remaining}" -gt 0 ]; do
        sleep 1
        if ! kill -0 "${runner}" 2> /dev/null; then
            return 0
        fi
        size=$(log_size)
        if [ "${size}" -ne "${stalled_size}" ]; then
            stalled_for=0
            last_size="${size}"
            return 0
        fi
        remaining=$((remaining - 1))
    done
    return 1
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
    size=$(log_size)
    if [ "${size}" -eq "${last_size}" ]; then
        stalled_for=$((stalled_for + POLL_SECONDS))
    else
        stalled_for=0
        last_size=${size}
    fi
    if [ "${stalled_for}" -ge "${STALL_SECONDS}" ]; then
        stalled_size="${size}"
        if wait_for_output_or_exit "${stalled_size}"; then
            continue
        fi

        dump_hang_diagnostics
        if ! kill -0 "${runner}" 2> /dev/null; then
            break
        fi
        if wait_for_output_or_exit "${stalled_size}"; then
            echo "::warning::test output resumed or runner exited while dumping diagnostics; continuing instead of killing"
            continue
        fi

        pkill -9 -f 'swiftpm-testing-helper|PackageTests|xctest' || true
        kill -9 "${runner}" 2> /dev/null || true
        exit 70
    fi
done

wait "${runner}"
