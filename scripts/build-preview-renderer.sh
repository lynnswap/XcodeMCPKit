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
      echo 'Usage: scripts/build-preview-renderer.sh [--configuration debug|release] [--output directory] [--developer-dir path]'
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
if [[ -z "$output" ]]; then output="$repo_root/.build/native/PreviewRenderer/iphonesimulator-arm64"; fi
if [[ "$output" != /* ]]; then output="$PWD/$output"; fi
swift_executable="$(DEVELOPER_DIR="$developer_dir" xcrun --find swift)"
sdk="$(DEVELOPER_DIR="$developer_dir" xcrun --sdk iphonesimulator --show-sdk-path)"
triple=arm64-apple-ios18.4-simulator
# Cross-building must not retarget the installer's macOS configuration symlinks.
scratch_path="$repo_root/.build/preview-renderer"

cd "$repo_root"
DEVELOPER_DIR="$developer_dir" "$swift_executable" build -c "$configuration" --disable-sandbox \
  --scratch-path "$scratch_path" --triple "$triple" --sdk "$sdk" \
  --force-resolved-versions --product XcodeMCPPreviewRenderer
bin_path="$(DEVELOPER_DIR="$developer_dir" "$swift_executable" build -c "$configuration" \
  --scratch-path "$scratch_path" --triple "$triple" --sdk "$sdk" --show-bin-path --force-resolved-versions)"
mkdir -p "$output/Frameworks"
archive="$output/libXcodeMCPPreviewRenderer.a"
cp "$bin_path/libXcodeMCPPreviewRenderer.a" "$archive"
DEVELOPER_DIR="$developer_dir" xcrun --sdk iphonesimulator swiftc \
  -target "$triple" -sdk "$sdk" "$archive" -lc++ \
  -Xlinker -force_load -Xlinker "$archive" \
  -Xlinker -rpath -Xlinker '@executable_path/Frameworks' \
  -o "$output/XcodeMCPPreviewRenderer"
chmod +x "$output/XcodeMCPPreviewRenderer"
DEVELOPER_DIR="$developer_dir" xcrun swift-stdlib-tool --copy --platform iphonesimulator \
  --scan-executable "$output/XcodeMCPPreviewRenderer" --destination "$output/Frameworks"
for library in "$output/Frameworks/"*.dylib; do
  [[ -f "$library" ]] || continue
  /usr/bin/codesign --force --sign - "$library"
done
/usr/bin/codesign --force --sign - "$output/XcodeMCPPreviewRenderer"
/usr/bin/codesign --verify --strict "$output/XcodeMCPPreviewRenderer"
echo "Preview renderer: $output/XcodeMCPPreviewRenderer"
