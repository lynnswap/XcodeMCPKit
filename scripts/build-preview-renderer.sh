#!/usr/bin/env bash
set -euo pipefail

configuration=debug
platform=iphonesimulator
output=""
developer_dir="${DEVELOPER_DIR:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --platform) platform="${2:?Missing platform}"; shift 2 ;;
    --configuration) configuration="${2:?Missing configuration}"; shift 2 ;;
    --output) output="${2:?Missing output directory}"; shift 2 ;;
    --developer-dir) developer_dir="${2:?Missing developer directory}"; shift 2 ;;
    -h|--help)
      echo 'Usage: scripts/build-preview-renderer.sh [--platform iphonesimulator|appletvsimulator|xrsimulator|watchsimulator|macosx|maccatalyst] [--configuration debug|release] [--output directory] [--developer-dir path]'
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
case "$platform" in
  iphonesimulator) sdk_name=iphonesimulator; triple=arm64-apple-ios18.4-simulator ;;
  appletvsimulator) sdk_name=appletvsimulator; triple=arm64-apple-tvos18.4-simulator ;;
  xrsimulator) sdk_name=xrsimulator; triple=arm64-apple-xros2.4-simulator ;;
  watchsimulator) sdk_name=watchsimulator; triple=arm64-apple-watchos11.4-simulator ;;
  macosx) sdk_name=macosx; triple=arm64-apple-macos15.4 ;;
  maccatalyst) sdk_name=macosx; triple=arm64-apple-ios18.4-macabi ;;
  *) echo "Unsupported preview platform: $platform" >&2; exit 1 ;;
esac
if [[ -z "$output" ]]; then output="$repo_root/.build/native/PreviewRenderer/$platform-arm64"; fi
if [[ "$output" != /* ]]; then output="$PWD/$output"; fi
swift_executable="$(DEVELOPER_DIR="$developer_dir" xcrun --find swift)"
sdk="$(DEVELOPER_DIR="$developer_dir" xcrun --sdk "$sdk_name" --show-sdk-path)"
swift_flags=(--force-resolved-versions)
link_flags=(-target "$triple" -sdk "$sdk")
rpath='@executable_path/Frameworks'
if [[ "$platform" == macosx || "$platform" == maccatalyst ]]; then rpath='@executable_path/../Frameworks'; fi
if [[ "$platform" == maccatalyst ]]; then
  support="$sdk/System/iOSSupport"
  swift_flags+=( -Xswiftc "-F$support/System/Library/Frameworks" -Xswiftc "-I$support/usr/include"
               -Xcc "-F$support/System/Library/Frameworks" -Xcc "-I$support/usr/include")
  link_flags+=( "-F$support/System/Library/Frameworks" "-I$support/usr/include" "-L$support/usr/lib")
fi
# Cross-building must not retarget the installer's macOS configuration symlinks.
scratch_path="$repo_root/.build/preview-renderer-$platform"

cd "$repo_root"
DEVELOPER_DIR="$developer_dir" "$swift_executable" build -c "$configuration" --disable-sandbox \
  --scratch-path "$scratch_path" --triple "$triple" --sdk "$sdk" \
  "${swift_flags[@]}" --product XcodeMCPPreviewRenderer
bin_path="$(DEVELOPER_DIR="$developer_dir" "$swift_executable" build -c "$configuration" \
  --scratch-path "$scratch_path" --triple "$triple" --sdk "$sdk" --show-bin-path "${swift_flags[@]}")"
# Swift Build reports the base Products directory for the Catalyst SDK variant.
if [[ "$platform" == maccatalyst && -d "$(dirname "$bin_path")/$configuration-maccatalyst" ]]; then
  bin_path="$(dirname "$bin_path")/$configuration-maccatalyst"
fi
mkdir -p "$output/Frameworks"
archive="$output/libXcodeMCPPreviewRenderer.a"
cp "$bin_path/libXcodeMCPPreviewRenderer.a" "$archive"
DEVELOPER_DIR="$developer_dir" xcrun --sdk "$sdk_name" swiftc \
  "${link_flags[@]}" "$archive" -lc++ \
  -Xlinker -force_load -Xlinker "$archive" \
  -Xlinker -rpath -Xlinker "$rpath" \
  -o "$output/XcodeMCPPreviewRenderer"
chmod +x "$output/XcodeMCPPreviewRenderer"
stdlib_platform="$sdk_name"
if [[ "$platform" == watchsimulator ]]; then stdlib_platform=watchos; fi
if [[ "$platform" != xrsimulator ]]; then
  DEVELOPER_DIR="$developer_dir" xcrun swift-stdlib-tool --copy --platform "$stdlib_platform" \
    --scan-executable "$output/XcodeMCPPreviewRenderer" --destination "$output/Frameworks"
fi
for library in "$output/Frameworks/"*.dylib; do
  [[ -f "$library" ]] || continue
  /usr/bin/codesign --force --sign - "$library"
done
/usr/bin/codesign --force --sign - "$output/XcodeMCPPreviewRenderer"
/usr/bin/codesign --verify --strict "$output/XcodeMCPPreviewRenderer"
echo "Preview renderer: $output/XcodeMCPPreviewRenderer"
