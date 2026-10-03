#!/usr/bin/env bash
set -euo pipefail

configuration=debug
output=""
developer_dir="${DEVELOPER_DIR:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --configuration) configuration="${2:?Missing configuration}"; shift 2 ;;
    --output) output="${2:?Missing output directory}"; shift 2 ;;
    --developer-dir) developer_dir="${2:?Missing developer directory}"; shift 2 ;;
    -h|--help)
      echo 'Usage: scripts/build-native-host.sh [--configuration debug|release] [--output app-path] [--developer-dir path]'
      exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done
if [[ "$configuration" != debug && "$configuration" != release ]]; then
  echo 'Configuration must be debug or release.' >&2
  exit 1
fi
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -z "$developer_dir" ]]; then developer_dir="$(/usr/bin/xcode-select -p)"; fi
if [[ "$developer_dir" == *.app || "$developer_dir" == *.app/ ]]; then
  developer_dir="${developer_dir%/}/Contents/Developer"
fi
contents_dir="$(cd "$developer_dir/.." && pwd)"
service_app="$contents_dir/Developer/Library/Xcode/Agents/Xcode Service.app"
bridge_binary="$contents_dir/Developer/usr/bin/mcpbridge"
if [[ ! -d "$service_app" ]]; then
  echo "Selected Xcode has no Xcode Service entitlement source: $service_app" >&2
  exit 1
fi
if [[ ! -f "$bridge_binary" ]]; then
  echo "Selected Xcode has no GUI bridge entitlement source: $bridge_binary" >&2
  exit 1
fi
if [[ -z "$output" ]]; then output="$repo_root/.build/native/XcodeMCPNativeHost.app"; fi
if [[ "$output" != /* ]]; then output="$PWD/$output"; fi

cd "$repo_root"
DEVELOPER_DIR="$developer_dir" swift build -c "$configuration" --product xcode-mcp-native-host
bin_path="$(DEVELOPER_DIR="$developer_dir" swift build -c "$configuration" --show-bin-path)"
mkdir -p "$output/Contents/MacOS"
cp "$bin_path/xcode-mcp-native-host" "$output/Contents/MacOS/xcode-mcp-native-host"
chmod +x "$output/Contents/MacOS/xcode-mcp-native-host"
python3 - "$output/Contents/Info.plist" <<'PY'
import pathlib, plistlib, sys
pathlib.Path(sys.argv[1]).write_bytes(plistlib.dumps({
    'CFBundleIdentifier': 'com.apple.dt.mcp-server',
    'CFBundleExecutable': 'xcode-mcp-native-host',
    'CFBundleName': 'XcodeMCPNativeHost',
    'CFBundlePackageType': 'APPL',
    'CFBundleShortVersionString': '1.0',
    'CFBundleVersion': '1',
    'LSUIElement': True,
    'NSPrincipalClass': 'NSApplication',
    'BSServiceDomains': {
        'com.apple.dt.mcpbridge.services': {
            'Services': {
                'com.apple.dt.mcpbridge.tool-service': {'LaunchWhitelisted': True},
            },
        },
    },
}))
PY
entitlements_directory="$(mktemp -d)"
trap 'rm -rf "$entitlements_directory"' EXIT
service_entitlements="$entitlements_directory/service.plist"
bridge_entitlements="$entitlements_directory/bridge.plist"
entitlements="$entitlements_directory/host.plist"
/usr/bin/codesign -d --entitlements :- "$service_app" > "$service_entitlements" 2>/dev/null
/usr/bin/codesign -d --entitlements :- "$bridge_binary" > "$bridge_entitlements" 2>/dev/null
python3 - "$service_entitlements" "$bridge_entitlements" "$entitlements" <<'PY'
import pathlib, plistlib, sys

def merge(service, bridge, key):
    if isinstance(service, dict) and isinstance(bridge, dict):
        result = dict(service)
        for name, value in bridge.items():
            result[name] = merge(result[name], value, f'{key}.{name}') if name in result else value
        return result
    if isinstance(service, list) and isinstance(bridge, list):
        result = list(service)
        for value in bridge:
            if value not in result:
                result.append(value)
        return result
    if type(service) is type(bridge) and service == bridge:
        return service
    raise ValueError(f'Incompatible native service and GUI bridge entitlement values for {key}')

service = plistlib.loads(pathlib.Path(sys.argv[1]).read_bytes())
bridge = plistlib.loads(pathlib.Path(sys.argv[2]).read_bytes())
# The host performs both native service work and the GUI connection's process role.
entitlements = merge(service, bridge, 'entitlements')
pathlib.Path(sys.argv[3]).write_bytes(plistlib.dumps(entitlements))
PY
/usr/bin/codesign --force --sign - --entitlements "$entitlements" "$output"
/usr/bin/codesign --verify --strict "$output"
echo "Native host: $output/Contents/MacOS/xcode-mcp-native-host"
