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
if [[ -z "$output" ]]; then output="$repo_root/.build/native/XcodeMCPNativeHost.app"; fi
if [[ "$output" != /* ]]; then output="$PWD/$output"; fi

cd "$repo_root"
DEVELOPER_DIR="$developer_dir" swift build -c "$configuration" --disable-sandbox --force-resolved-versions --product xcode-mcp-native-host
bin_path="$(DEVELOPER_DIR="$developer_dir" swift build -c "$configuration" --show-bin-path)"
mkdir -p "$output/Contents/MacOS"
cp "$bin_path/xcode-mcp-native-host" "$output/Contents/MacOS/xcode-mcp-native-host"
chmod +x "$output/Contents/MacOS/xcode-mcp-native-host"
DEVELOPER_DIR="$developer_dir" xcrun swift-stdlib-tool --copy --platform macosx \
  --scan-executable "$output/Contents/MacOS/xcode-mcp-native-host" \
  --destination "$output/Contents/Frameworks"
DEVELOPER_DIR="$developer_dir" xcrun install_name_tool -add_rpath '@executable_path/../Frameworks' \
  "$output/Contents/MacOS/xcode-mcp-native-host"
for library in "$output/Contents/Frameworks/"*.dylib; do
  [[ -f "$library" ]] || continue
  /usr/bin/codesign --force --sign - "$library"
done
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
}))
PY
entitlements_directory="$(mktemp -d)"
trap 'rm -rf "$entitlements_directory"' EXIT
entitlements="$entitlements_directory/host.plist"
python3 - "$entitlements" <<'PY'
import pathlib, plistlib, sys
# The host reexecs with loader paths for the selected Xcode's frameworks.
pathlib.Path(sys.argv[1]).write_bytes(plistlib.dumps({
    'com.apple.security.cs.allow-dyld-environment-variables': True,
}))
PY
/usr/bin/codesign --force --sign - --identifier com.lynnswap.XcodeMCPNativeHost --entitlements "$entitlements" "$output"
/usr/bin/codesign --verify --deep --strict "$output"
echo "Native host: $output/Contents/MacOS/xcode-mcp-native-host"
