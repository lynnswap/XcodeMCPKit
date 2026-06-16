#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/package-release.sh [--dist-root <dir>] [--output-dir <dir>]

Requires staged arm64 binaries from:
  <dist-root>/arm64/bin/

Outputs:
  <output-dir>/xcode-mcp-proxy-darwin-arm64.tar.gz
  <output-dir>/SHA256SUMS.txt
EOF
}

dist_root="dist"
output_dir="release"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dist-root)
      dist_root="${2:-}"
      shift 2
      ;;
    --output-dir)
      output_dir="${2:-}"
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

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$dist_root" = /* ]]; then
  dist_base="$dist_root"
else
  dist_base="$repo_root/$dist_root"
fi
if [[ "$output_dir" = /* ]]; then
  output_base="$output_dir"
else
  output_base="$repo_root/$output_dir"
fi

arm_bin="$dist_base/arm64/bin"
if [[ ! -d "$arm_bin" ]]; then
  echo "Missing staged directory: $arm_bin" >&2
  exit 1
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

mkdir -p "$output_base"

archive="$output_base/xcode-mcp-proxy-darwin-arm64.tar.gz"
find "$output_base" -maxdepth 1 -type f -name 'xcode-mcp-proxy*.tar.gz' -delete
rm -f "$output_base/SHA256SUMS.txt"

products=(
  "xcode-mcp-proxy"
  "xcode-mcp-proxy-server"
  "xcode-mcp-proxy-install"
)

for product in "${products[@]}"; do
  source_path="$arm_bin/$product"
  if [[ ! -f "$source_path" ]]; then
    echo "Missing staged binary: $source_path" >&2
    exit 1
  fi
done

cp -R "$arm_bin" "$tmp_dir/bin"
for product in "${products[@]}"; do
  chmod +x "$tmp_dir/bin/$product"
  if command -v lipo >/dev/null 2>&1; then
    archs="$(lipo -archs "$tmp_dir/bin/$product")"
    if [[ "$archs" != "arm64" ]]; then
      echo "Expected arm64 binary for $product, got: $archs" >&2
      exit 1
    fi
  fi
done

tar -C "$tmp_dir" -czf "$archive" bin

(
  cd "$output_base"
  shasum -a 256 xcode-mcp-proxy-darwin-arm64.tar.gz > SHA256SUMS.txt
)

echo "Created release package: $archive"
echo "Created checksum file: $output_base/SHA256SUMS.txt"
