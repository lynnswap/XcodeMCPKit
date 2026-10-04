#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/build-release.sh --version <tag> [--dist-root <dir>]

Builds arm64 release binaries and stages them under:
  <dist-root>/arm64/bin/
EOF
}

version=""
dist_root="dist"
arch="arm64"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      version="${2:-}"
      shift 2
      ;;
    --dist-root)
      dist_root="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$version" ]]; then
  echo "--version is required." >&2
  usage
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$dist_root" = /* ]]; then
  dist_base="$dist_root"
else
  dist_base="$repo_root/$dist_root"
fi

out_dir="$dist_base/$arch"
bin_out="$out_dir/bin"
products=(
  "xcode-mcp-proxy"
  "xcode-mcp-proxy-server"
)

pushd "$repo_root" >/dev/null

for product in "${products[@]}"; do
  XCODE_MCP_BUILD_VERSION="$version" swift build -c release --disable-sandbox --force-resolved-versions \
    -Xswiftc -strict-concurrency=minimal \
    --arch "$arch" \
    --product "$product"
done

bin_path="$(swift build -c release --arch "$arch" --show-bin-path)"
rm -rf "$out_dir"
mkdir -p "$bin_out"

for product in "${products[@]}"; do
  source_path="$bin_path/$product"
  if [[ -z "$source_path" || ! -f "$source_path" ]]; then
    echo "Failed to locate built binary: $product" >&2
    exit 1
  fi

  target_path="$bin_out/$product"
  cp "$source_path" "$target_path"
  chmod +x "$target_path"
  xcrun swift-stdlib-tool --copy --platform macosx --scan-executable "$target_path" \
    --destination "$bin_out/xcode-mcp-runtime"
  xcrun install_name_tool -add_rpath '@loader_path/xcode-mcp-runtime' "$target_path"
  if command -v lipo >/dev/null 2>&1; then
    archs="$(lipo -archs "$target_path")"
    if [[ "$archs" != "arm64" ]]; then
      echo "Expected arm64 binary for $product, got: $archs" >&2
      exit 1
    fi
  fi
  if command -v codesign >/dev/null 2>&1; then
    codesign --force --sign - "$target_path" >/dev/null
  fi
done

for library in "$bin_out/xcode-mcp-runtime/"*.dylib; do
  [[ -f "$library" ]] || continue
  codesign --force --sign - "$library"
done

XCODE_MCP_BUILD_VERSION="$version" "$repo_root/scripts/build-native-host.sh" \
  --configuration release --output "$bin_out/XcodeMCPNativeHost.app"
if command -v lipo >/dev/null 2>&1; then
  native_archs="$(lipo -archs "$bin_out/XcodeMCPNativeHost.app/Contents/MacOS/xcode-mcp-native-host")"
  if [[ "$native_archs" != "arm64" ]]; then
    echo "Expected arm64 native helper, got: $native_archs" >&2
    exit 1
  fi
fi

popd >/dev/null

echo "Staged release binaries at: $out_dir"
