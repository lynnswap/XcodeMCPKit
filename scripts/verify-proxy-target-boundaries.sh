#!/bin/bash
set -euo pipefail

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
    output="$(LC_ALL=C grep -E -n -r "${pattern}" "$@" 2>&1)"
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
    '(^|[^[:alnum:]_])ProxyConfig([^[:alnum:]_]|$)|listenHost|listenPort|discoveryFileURL|configPath' \
    Sources/XcodeMCPProxyRuntime

reject_matches \
    "XcodeMCPProxyKit must not own the HTTP listener lifecycle" \
    'ServerBootstrap|ProxyAcceptedChannel|listenChannels|childChannelInitializer' \
    Sources/XcodeMCPProxyKit

reject_matches \
    "XcodeMCPProxyHTTP references a Runtime implementation type" \
    'ToolsCatalogAuthority|(^|[^[:alnum:]_])ControlPlane([^[:alnum:]_]|$)|LeaseManager|(^|[^[:alnum:]_])Upstream[A-Za-z0-9_]*([^[:alnum:]_]|$)|SessionContext|RuntimeCoordinator|RefreshCodeIssues' \
    Sources/XcodeMCPProxyHTTP

reject_matches \
    "deleted proxy gateway or test-support graph is still present" \
    'RuntimeHTTPGatewayPort|RuntimeHTTPControlPort|XcodeMCPProxyInternalTestSupport' \
    Sources Tests Package.swift

reject_matches \
    "native host, installation, and wire modules must not import NIO or the proxy/client runtime" \
    '^[[:space:]]*([[:alnum:]_@()]+[[:space:]]+)*import[[:space:]]+((class|enum|func|let|protocol|struct|typealias|var)[[:space:]]+)?(NIO[[:alnum:]_]*|CNIO[[:alnum:]_]*|_NIO[[:alnum:]_]*|XcodeMCPCore|XcodeMCPKit|XcodeMCPProxy[[:alnum:]_]*)([[:space:].;]|$)' \
    Sources/XcodeMCPNativeHost Sources/XcodeMCPNativeRuntime Sources/XcodeMCPInstallation Sources/XcodeMCPWire

package_description="$(swift package describe --type json)"
if ! jq -e '
    .targets | map({key: .name, value: ((.target_dependencies // []) + (.product_dependencies // []))}) | from_entries as $graph |
    def dependencies($target):
        [$graph[$target][]? as $child | $child, dependencies($child)[]] | unique;
    def excludes($target; $forbidden):
        (dependencies($target) - $forbidden) == dependencies($target);
    def directlyUses($target; $dependency):
        ($graph[$target] | index($dependency)) != null;
    def hasOnlyNativeDependencies($target):
        dependencies($target) | all(test("^(NIO|CNIO|_NIO|XcodeMCPCore$|XcodeMCPKit$|XcodeMCPProxy)") | not);
    hasOnlyNativeDependencies("XcodeMCPNativeHost") and
    hasOnlyNativeDependencies("XcodeMCPNativeRuntime") and
    ($graph["XcodeMCPInstallation"] == []) and
    ($graph["XcodeMCPWire"] == []) and
    directlyUses("XcodeMCPNativeHost"; "XcodeMCPInstallation") and
    directlyUses("XcodeMCPNativeRuntime"; "XcodeMCPInstallation") and
    directlyUses("XcodeMCPProxyRuntime"; "XcodeMCPInstallation") and
    directlyUses("XcodeMCPNativeHost"; "XcodeMCPNativeRuntime") and
    directlyUses("XcodeMCPNativeHost"; "XcodeMCPWire") and
    directlyUses("XcodeMCPNativeRuntime"; "XcodeMCPWire") and
    directlyUses("XcodeMCPNativeRuntime"; "ABIBridge") and
    directlyUses("XcodeMCPCore"; "XcodeMCPWire") and
    excludes("XcodeMCPCore"; ["XcodeMCPKit", "XcodeMCPProxyRuntime", "XcodeMCPProxyHTTP", "XcodeMCPProxyKit"]) and
    excludes("XcodeMCPKit"; ["XcodeMCPProxyRuntime", "XcodeMCPProxyHTTP", "XcodeMCPProxyKit"]) and
    excludes("XcodeMCPProxyRuntime"; ["XcodeMCPKit", "XcodeMCPProxyHTTP", "XcodeMCPProxyKit"]) and
    excludes("XcodeMCPProxyHTTP"; ["XcodeMCPKit", "XcodeMCPProxyRuntime", "XcodeMCPProxyKit"]) and
    excludes("XcodeMCPProxyRuntimeContract"; ["XcodeMCPKit", "XcodeMCPProxyRuntime", "XcodeMCPProxyHTTP", "XcodeMCPProxyKit"]) and
    excludes("XcodeMCPCoreTests"; ["XcodeMCPKit", "XcodeMCPProxyRuntime", "XcodeMCPProxyHTTP", "XcodeMCPProxyKit"]) and
    excludes("XcodeMCPProcessRuntimeTests"; ["XcodeMCPKit", "XcodeMCPProxyRuntime", "XcodeMCPProxyHTTP", "XcodeMCPProxyKit"]) and
    excludes("XcodeMCPProxyRuntimeTests"; ["XcodeMCPKit", "XcodeMCPProxyHTTP", "XcodeMCPProxyKit"]) and
    excludes("XcodeMCPProxyRuntimeTestSupport"; ["XcodeMCPKit", "XcodeMCPProxyHTTP", "XcodeMCPProxyKit"]) and
    excludes("XcodeMCPProxyTestSupport"; ["XcodeMCPKit", "XcodeMCPProxyRuntime", "XcodeMCPProxyHTTP", "XcodeMCPProxyKit"]) and
    excludes("XcodeMCPProxyHTTPTests"; ["XcodeMCPKit", "XcodeMCPProxyRuntime", "XcodeMCPProxyKit"]) and
    directlyUses("XcodeMCPKit"; "XcodeMCPCore") and
    directlyUses("XcodeMCPProxyRuntime"; "XcodeMCPCore") and
    directlyUses("XcodeMCPProxyHTTP"; "XcodeMCPCore") and
    directlyUses("XcodeMCPProxyHTTP"; "XcodeMCPProxyRuntimeContract") and
    directlyUses("XcodeMCPProxyRuntime"; "XcodeMCPProxyRuntimeContract") and
    directlyUses("XcodeMCPProxyKit"; "XcodeMCPProxyRuntime") and
    directlyUses("XcodeMCPProxyKit"; "XcodeMCPProxyHTTP")
' <<< "${package_description}" >/dev/null; then
    echo "error: package dependencies violate the native-host, shared-core, or proxy ownership boundaries" >&2
    exit 1
fi

echo "Native host and proxy target boundaries verified."
