#!/bin/bash
set -euo pipefail

if ! command -v rg > /dev/null 2>&1; then
    echo "error: verify-proxy-target-boundaries requires rg" >&2
    exit 2
fi
if ! command -v jq > /dev/null 2>&1; then
    echo "error: verify-proxy-target-boundaries requires jq" >&2
    exit 2
fi

reject_matches() {
    local description=$1
    local pattern=$2
    shift 2

    local output
    local status
    set +e
    output="$(rg -n "${pattern}" "$@" 2>&1)"
    status=$?
    set -e

    if [ "${status}" -eq 0 ]; then
        echo "error: ${description}" >&2
        echo "${output}" >&2
        exit 1
    fi
    if [ "${status}" -ne 1 ]; then
        echo "error: boundary search failed for ${description}" >&2
        echo "${output}" >&2
        exit "${status}"
    fi
}

reject_matches \
    "XcodeMCPProxyRuntime must not import NIOHTTP1" \
    '^import NIOHTTP1$' \
    Sources/XcodeMCPProxyRuntime

reject_matches \
    "XcodeMCPProxyRuntime must not own the facade aggregate configuration" \
    '\bProxyConfig\b|listenHost|listenPort|discoveryFileURL|configPath' \
    Sources/XcodeMCPProxyRuntime

reject_matches \
    "XcodeMCPProxyKit must not own the HTTP listener lifecycle" \
    'ServerBootstrap|ProxyAcceptedChannel|listenChannels|childChannelInitializer' \
    Sources/XcodeMCPProxyKit

reject_matches \
    "XcodeMCPProxyHTTP references a Runtime implementation type" \
    'ProcessControlPlaneAuthority|\bControlPlane\b|LeaseManager|\bUpstream[A-Za-z0-9_]*\b|SessionContext|RuntimeCoordinator|DocumentationProvider|RefreshCodeIssues' \
    Sources/XcodeMCPProxyHTTP

reject_matches \
    "deleted proxy gateway or test-support graph is still present" \
    'RuntimeHTTPGatewayPort|RuntimeHTTPControlPort|XcodeMCPProxyInternalTestSupport' \
    Sources Tests Package.swift

package_description="$(swift package describe --type json)"
runtime_dependencies="$(
    jq -r '.targets[] | select(.name == "XcodeMCPProxyRuntime") | .target_dependencies | sort | join(",")' \
        <<< "${package_description}"
)"
http_dependencies="$(
    jq -r '.targets[] | select(.name == "XcodeMCPProxyHTTP") | .target_dependencies | sort | join(",")' \
        <<< "${package_description}"
)"
facade_dependencies="$(
    jq -r '.targets[] | select(.name == "XcodeMCPProxyKit") | .target_dependencies | sort | join(",")' \
        <<< "${package_description}"
)"

if [ "${runtime_dependencies}" != "XcodeMCPKit" ]; then
    echo "error: unexpected XcodeMCPProxyRuntime target dependencies: ${runtime_dependencies}" >&2
    exit 1
fi
if [ "${http_dependencies}" != "XcodeMCPKit,XcodeMCPProxyRuntime" ]; then
    echo "error: unexpected XcodeMCPProxyHTTP target dependencies: ${http_dependencies}" >&2
    exit 1
fi
if [[ ",${facade_dependencies}," != *",XcodeMCPProxyHTTP,"* ]] \
    || [[ ",${facade_dependencies}," != *",XcodeMCPProxyRuntime,"* ]]; then
    echo "error: XcodeMCPProxyKit must compose both Runtime and HTTP: ${facade_dependencies}" >&2
    exit 1
fi

echo "Proxy target boundaries verified."
