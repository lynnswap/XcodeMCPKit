#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/render-install-script.sh --version <tag> --repo <owner/repo> --output <path>
EOF
}

version=""
release_repo=""
output=""

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
    --output)
      output="${2:-}"
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

if [[ -z "$version" || -z "$release_repo" || -z "$output" ]]; then
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
template="$repo_root/scripts/install-release.sh.in"

if [[ ! -f "$template" ]]; then
  echo "Missing installer template: $template" >&2
  exit 1
fi

output_dir="$(dirname "$output")"
mkdir -p "$output_dir"
tmp_output="${output}.tmp"
sed \
  -e "s|__VERSION__|$version|g" \
  -e "s|__REPO__|$release_repo|g" \
  "$template" > "$tmp_output"
mv "$tmp_output" "$output"
chmod +x "$output"
