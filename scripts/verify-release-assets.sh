#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/verify-release-assets.sh --version <tag> --repo <owner/repo> [--release-dir <dir>]
EOF
}

version=""
release_repo=""
release_dir="release"

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
    --release-dir)
      release_dir="${2:-}"
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

if [[ -z "$version" || -z "$release_repo" ]]; then
  usage >&2
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
if [[ "$release_dir" = /* ]]; then
  release_base="$release_dir"
else
  release_base="$repo_root/$release_dir"
fi

if [[ ! -d "$release_base" ]]; then
  echo "Missing release directory: $release_base" >&2
  exit 1
fi

expected_assets=(
  "xcode-mcp-proxy-darwin-arm64.tar.gz"
  "SHA256SUMS.txt"
  "install.sh"
)

for asset in "${expected_assets[@]}"; do
  if [[ ! -f "$release_base/$asset" ]]; then
    echo "Expected release asset was not created: $asset" >&2
    exit 1
  fi
done

expected_asset_list="$(printf '%s\n' "${expected_assets[@]}" | sort)"
actual_asset_list="$(
  cd "$release_base"
  for path in *; do
    [[ -f "$path" ]] && printf '%s\n' "$path"
  done | sort
)"
if [[ "$actual_asset_list" != "$expected_asset_list" ]]; then
  echo "Release asset set is not expected." >&2
  printf 'Expected:\n%s\n' "$expected_asset_list" >&2
  printf 'Actual:\n%s\n' "$actual_asset_list" >&2
  exit 1
fi

(
  cd "$release_base"
  shasum -a 256 -c SHA256SUMS.txt
)

sh -n "$release_base/install.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
"$repo_root/scripts/render-install-script.sh" \
  --version "$version" \
  --repo "$release_repo" \
  --output "$tmp_dir/install.expected.sh"
if ! cmp -s "$tmp_dir/install.expected.sh" "$release_base/install.sh"; then
  echo "install.sh does not match the generated installer for $version." >&2
  diff -u "$tmp_dir/install.expected.sh" "$release_base/install.sh" || true
  exit 1
fi

expected_entries="$(printf '%s\n' \
  "bin/" \
  "bin/xcode-mcp-proxy" \
  "bin/xcode-mcp-proxy-server")"
actual_entries="$(tar -tzf "$release_base/xcode-mcp-proxy-darwin-arm64.tar.gz" | sort)"
if [[ "$actual_entries" != "$expected_entries" ]]; then
  echo "Release archive contents are not expected." >&2
  printf 'Expected:\n%s\n' "$expected_entries" >&2
  printf 'Actual:\n%s\n' "$actual_entries" >&2
  exit 1
fi
