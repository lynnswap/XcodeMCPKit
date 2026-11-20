#!/bin/bash
set -euo pipefail

if ! command -v jq > /dev/null 2>&1; then
    echo "error: verify-server-target-boundaries requires jq" >&2
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
    "permission automation must not import native execution, server routing, or SDK modules" \
    '^[[:space:]]*import[[:space:]]+(XcodeMCPCore|XcodeMCPKit|XcodeMCPNative[A-Za-z0-9_]*|XcodeMCPServer[A-Za-z0-9_]*)([[:space:].;]|$)' \
    Sources/XcodeMCPPermissionAutomation

reject_matches \
    "XcodeMCPServerRuntime must not import NIOHTTP1" \
    '^import NIOHTTP1$' \
    Sources/XcodeMCPServerRuntime

reject_matches \
    "XcodeMCPServerRuntime must not own the facade aggregate configuration" \
    'listenHost|listenPort|discoveryFileURL' \
    Sources/XcodeMCPServerRuntime

reject_matches \
    "XcodeMCPServerKit must not own the HTTP listener lifecycle" \
    'ServerBootstrap|ServerAcceptedChannel|listenChannels|childChannelInitializer' \
    Sources/XcodeMCPServerKit

reject_matches \
    "XcodeMCPServerHTTP references a host process type" \
    '(^|[^[:alnum:]_])(Upstream|MCPProcess)[A-Za-z0-9_]*([^[:alnum:]_]|$)' \
    Sources/XcodeMCPServerHTTP

reject_matches \
    "native host, installation, and wire modules must not import NIO or the server/client runtime" \
    '^[[:space:]]*([[:alnum:]_@()]+[[:space:]]+)*import[[:space:]]+((class|enum|func|let|protocol|struct|typealias|var)[[:space:]]+)?(NIO[[:alnum:]_]*|CNIO[[:alnum:]_]*|_NIO[[:alnum:]_]*|XcodeMCPCore|XcodeMCPKit|XcodeMCPServer[[:alnum:]_]*)([[:space:].;]|$)' \
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
        dependencies($target) | all(test("^(NIO|CNIO|_NIO|XcodeMCPCore$|XcodeMCPKit$|XcodeMCPServer|XcodeMCPPermissionAutomation$)") | not);
    hasOnlyNativeDependencies("XcodeMCPNativeHost") and
    hasOnlyNativeDependencies("XcodeMCPNativeRuntime") and
    ($graph["XcodeMCPInstallation"] == []) and
    ($graph["XcodeMCPWire"] == []) and
    ($graph["XcodeMCPPermissionAutomation"] == ["Logging"]) and
    excludes("XcodeMCPServerRuntime"; ["XcodeMCPPermissionAutomation"]) and
    excludes("XcodeMCPServerHTTP"; ["XcodeMCPPermissionAutomation"]) and
    directlyUses("XcodeMCPNativeHost"; "XcodeMCPInstallation") and
    directlyUses("XcodeMCPNativeRuntime"; "XcodeMCPInstallation") and
    directlyUses("XcodeMCPServerRuntime"; "XcodeMCPInstallation") and
    directlyUses("XcodeMCPNativeHost"; "XcodeMCPNativeRuntime") and
    directlyUses("XcodeMCPNativeHost"; "XcodeMCPWire") and
    directlyUses("XcodeMCPNativeRuntime"; "XcodeMCPWire") and
    directlyUses("XcodeMCPNativeRuntime"; "ABIBridge") and
    ($graph["XcodeMCPCore"] == ["XcodeMCPWire"]) and
    (dependencies("XcodeMCPKit") == ["XcodeMCPCore", "XcodeMCPWire"]) and
    (dependencies("XcodeMCPKitTesting") == ["XcodeMCPCore", "XcodeMCPKit", "XcodeMCPWire"]) and
    excludes("XcodeMCPServerRuntime"; ["XcodeMCPKit", "XcodeMCPServerHTTP", "XcodeMCPServerKit"]) and
    excludes("XcodeMCPServerHTTP"; ["XcodeMCPKit", "XcodeMCPServerRuntime", "XcodeMCPServerKit"]) and
    excludes("XcodeMCPServerRuntimeContract"; ["XcodeMCPKit", "XcodeMCPServerRuntime", "XcodeMCPServerHTTP", "XcodeMCPServerKit"]) and
    excludes("XcodeMCPCoreTests"; ["XcodeMCPKit", "XcodeMCPServerRuntime", "XcodeMCPServerHTTP", "XcodeMCPServerKit"]) and
    excludes("XcodeMCPProcessRuntimeTests"; ["XcodeMCPKit", "XcodeMCPServerRuntime", "XcodeMCPServerHTTP", "XcodeMCPServerKit"]) and
    excludes("XcodeMCPServerRuntimeTests"; ["XcodeMCPKit", "XcodeMCPServerHTTP", "XcodeMCPServerKit"]) and
    excludes("XcodeMCPServerRuntimeTestSupport"; ["XcodeMCPKit", "XcodeMCPServerHTTP", "XcodeMCPServerKit"]) and
    excludes("XcodeMCPServerTestSupport"; ["XcodeMCPKit", "XcodeMCPServerRuntime", "XcodeMCPServerHTTP", "XcodeMCPServerKit"]) and
    excludes("XcodeMCPServerHTTPTests"; ["XcodeMCPKit", "XcodeMCPServerRuntime", "XcodeMCPServerKit"]) and
    excludes("XcodeMCPServerKit"; ["XcodeMCPKit"]) and
    directlyUses("XcodeMCPServerRuntime"; "XcodeMCPCore") and
    directlyUses("XcodeMCPServerHTTP"; "XcodeMCPCore") and
    directlyUses("XcodeMCPServerHTTP"; "XcodeMCPServerRuntimeContract") and
    directlyUses("XcodeMCPServerRuntime"; "XcodeMCPServerRuntimeContract") and
    directlyUses("XcodeMCPServerKit"; "XcodeMCPServerRuntime") and
    directlyUses("XcodeMCPServerKit"; "XcodeMCPServerHTTP") and
    directlyUses("XcodeMCPServerKit"; "XcodeMCPPermissionAutomation")
' <<< "${package_description}" >/dev/null; then
    echo "error: package dependencies violate the native-host, shared-core, or server ownership boundaries" >&2
    exit 1
fi

echo "Native host and server target boundaries verified."
