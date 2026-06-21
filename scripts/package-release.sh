#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/package-release.sh --version <tag> [--repo <owner/repo>] [--dist-root <dir>] [--output-dir <dir>]

Requires staged arm64 binaries from:
  <dist-root>/arm64/bin/

Outputs:
  <output-dir>/xcode-mcp-proxy-darwin-arm64.tar.gz
  <output-dir>/SHA256SUMS.txt
  <output-dir>/install.sh
EOF
}

version=""
release_repo="lynnswap/XcodeMCPKit"
dist_root="dist"
output_dir="release"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      version="${2:-}"
      shift 2
      ;;
    --repo)
      release_repo="${2:-}"
      shift 2
      ;;
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

if [[ -z "$version" ]]; then
  echo "--version is required." >&2
  usage
  exit 1
fi

if [[ ! "$version" =~ ^v[0-9]+[.][0-9]+[.][0-9]+([-.][0-9A-Za-z.-]+)?$ ]]; then
  echo "Release tag must look like v1.2.3." >&2
  exit 1
fi

if [[ ! "$release_repo" =~ ^[0-9A-Za-z_.-]+/[0-9A-Za-z_.-]+$ ]]; then
  echo "Release repo must look like owner/repo." >&2
  exit 1
fi

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
install_script="$output_base/install.sh"
find "$output_base" -maxdepth 1 -type f -name 'xcode-mcp-proxy*.tar.gz' -delete
rm -f "$output_base/SHA256SUMS.txt" "$install_script"

products=(
  "xcode-mcp-proxy"
  "xcode-mcp-proxy-server"
)

for product in "${products[@]}"; do
  source_path="$arm_bin/$product"
  if [[ ! -f "$source_path" ]]; then
    echo "Missing staged binary: $source_path" >&2
    exit 1
  fi
done

mkdir -p "$tmp_dir/bin"
for product in "${products[@]}"; do
  cp "$arm_bin/$product" "$tmp_dir/bin/$product"
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

cat > "$install_script" <<'INSTALL_SH'
#!/usr/bin/env sh
set -eu

VERSION="${VERSION:-__VERSION__}"
REPO="${XCODE_MCPKIT_REPO:-__REPO__}"
ARCHIVE="xcode-mcp-proxy-darwin-arm64.tar.gz"
DEFAULT_BASE_URL="https://github.com/${REPO}/releases/download/${VERSION}"
BASE_URL="${XCODE_MCPKIT_BASE_URL:-$DEFAULT_BASE_URL}"

if [ -z "${BINDIR:-}" ]; then
  PREFIX="${PREFIX:-${HOME}/.local}"
  BINDIR="${PREFIX}/bin"
fi

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

need curl
need grep
need install
need mktemp
need shasum
need tar
need uname

OS="$(uname -s)"
ARCH="$(uname -m)"
if [ "$OS" != "Darwin" ]; then
  echo "GitHub release archives are macOS arm64 only. Build from source on ${OS}/${ARCH}." >&2
  exit 1
fi

ARM64_CAPABLE=0
if [ "$ARCH" = "arm64" ]; then
  ARM64_CAPABLE=1
elif [ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" = "1" ]; then
  ARM64_CAPABLE=1
fi

if [ "$ARM64_CAPABLE" != "1" ]; then
  echo "GitHub release archives are macOS arm64 only. Build from source on ${OS}/${ARCH}." >&2
  exit 1
fi

tmp_root="${TMPDIR:-/tmp}"
tmp_dir="$(mktemp -d "${tmp_root%/}/xcode-mcpkit.XXXXXX")"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT INT TERM

curl -fsSL -o "$tmp_dir/$ARCHIVE" "$BASE_URL/$ARCHIVE"
curl -fsSL -o "$tmp_dir/SHA256SUMS.txt" "$BASE_URL/SHA256SUMS.txt"

(
  cd "$tmp_dir"
  grep "  ${ARCHIVE}\$" SHA256SUMS.txt > SHA256SUMS.selected
  shasum -a 256 -c SHA256SUMS.selected
  tar -xzf "$ARCHIVE"
)

mkdir -p "$BINDIR"
install -m 755 "$tmp_dir/bin/xcode-mcp-proxy" "$BINDIR/xcode-mcp-proxy"
install -m 755 "$tmp_dir/bin/xcode-mcp-proxy-server" "$BINDIR/xcode-mcp-proxy-server"

echo "Installed XcodeMCPKit ${VERSION} to ${BINDIR}"
case ":${PATH}:" in
  *":${BINDIR}:"*) ;;
  *)
    echo "Add this directory to PATH:"
    echo "  export PATH=\"${BINDIR}:\$PATH\""
    ;;
esac
INSTALL_SH

sed \
  -e "s|__VERSION__|$version|g" \
  -e "s|__REPO__|$release_repo|g" \
  "$install_script" > "$install_script.tmp"
mv "$install_script.tmp" "$install_script"
chmod +x "$install_script"

echo "Created release package: $archive"
echo "Created checksum file: $output_base/SHA256SUMS.txt"
echo "Created install script: $install_script"
