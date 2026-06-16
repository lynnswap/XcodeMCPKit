#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/publish-local-release.sh <tag> [--dist-root <dir>] [--output-dir <dir>] [--remote <name>] [--release-branch <branch>] [--skip-tests] [--allow-dirty]

Builds and uploads the arm64 release archive, then pushes the release tag.
The dispatched release verification workflow publishes the draft release only after remote tests pass.
Passing --allow-dirty creates a local-only archive and never pushes a tag or GitHub release.
EOF
}

tag=""
dist_root="dist"
output_dir="release"
remote="origin"
release_branch="main"
skip_tests=0
allow_dirty=0
tag_needs_push=1
github_repo=""

remote_tag_commit() {
  local remote_name="$1"
  local tag_name="$2"
  local tag_lines peeled direct

  tag_lines="$(git ls-remote --tags "$remote_name" "refs/tags/$tag_name" "refs/tags/$tag_name^{}")"
  if [[ -z "$tag_lines" ]]; then
    return 1
  fi

  peeled="$(awk '$2 ~ /\^\{\}$/ { print $1 }' <<<"$tag_lines" | tail -n 1)"
  if [[ -n "$peeled" ]]; then
    echo "$peeled"
    return 0
  fi

  direct="$(awk -v ref="refs/tags/$tag_name" '$2 == ref { print $1; exit }' <<<"$tag_lines")"
  if [[ -n "$direct" ]]; then
    echo "$direct"
    return 0
  fi

  return 1
}

verify_release_branch_matches_head() {
  local local_commit remote_commit

  git fetch --quiet "$remote" "refs/heads/$release_branch:refs/remotes/$remote/$release_branch" --tags
  local_commit="$(git rev-parse HEAD)"
  remote_commit="$(git rev-parse "$remote/$release_branch")"
  if [[ "$local_commit" != "$remote_commit" ]]; then
    echo "Release tag target must match $remote/$release_branch before the tag is pushed." >&2
    echo "Local HEAD:  $local_commit" >&2
    echo "Remote HEAD: $remote_commit" >&2
    exit 1
  fi
}

refresh_tag_state() {
  local local_commit local_tag_commit remote_tag_target

  local_commit="$(git rev-parse HEAD)"
  if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    local_tag_commit="$(git rev-parse "$tag^{commit}")"
    if [[ "$local_tag_commit" != "$local_commit" ]]; then
      echo "Local or fetched tag already exists but does not point to HEAD: $tag" >&2
      echo "Tag target: $local_tag_commit" >&2
      echo "HEAD:       $local_commit" >&2
      exit 1
    fi
  fi

  if remote_tag_target="$(remote_tag_commit "$remote" "$tag")"; then
    if [[ "$remote_tag_target" != "$local_commit" ]]; then
      echo "Remote tag already exists on $remote but does not point to HEAD: $tag" >&2
      echo "Remote tag target: $remote_tag_target" >&2
      echo "HEAD:              $local_commit" >&2
      exit 1
    fi
    tag_needs_push=0
  else
    tag_needs_push=1
  fi
}

is_release_asset() {
  case "$1" in
    xcode-mcp-proxy-darwin-arm64.tar.gz|SHA256SUMS.txt)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

github_repo_for_remote() {
  local remote_name="$1"
  local remote_url slug

  remote_url="$(git remote get-url --push "$remote_name")"
  case "$remote_url" in
    https://github.com/*)
      slug="${remote_url#https://github.com/}"
      ;;
    git@github.com:*)
      slug="${remote_url#git@github.com:}"
      ;;
    ssh://git@github.com/*)
      slug="${remote_url#ssh://git@github.com/}"
      ;;
    *)
      echo "Release remote must be a GitHub remote: $remote_name ($remote_url)" >&2
      return 1
      ;;
  esac

  slug="${slug%.git}"
  slug="${slug%/}"
  if [[ ! "$slug" =~ ^[^/]+/[^/]+$ ]]; then
    echo "Could not derive GitHub owner/repo from remote: $remote_name ($remote_url)" >&2
    return 1
  fi

  echo "$slug"
}

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
    --remote)
      remote="${2:-}"
      shift 2
      ;;
    --release-branch)
      release_branch="${2:-}"
      shift 2
      ;;
    --skip-tests)
      skip_tests=1
      shift
      ;;
    --allow-dirty)
      allow_dirty=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
    *)
      if [[ -n "$tag" ]]; then
        echo "Only one release tag can be specified." >&2
        usage
        exit 1
      fi
      tag="$1"
      shift
      ;;
  esac
done

if [[ -z "$tag" ]]; then
  usage
  exit 1
fi

if [[ ! "$tag" =~ ^v[0-9]+[.][0-9]+[.][0-9]+([-.][0-9A-Za-z.-]+)?$ ]]; then
  echo "Release tag must look like v1.2.3." >&2
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

dirty_status="$(git status --porcelain --untracked-files=all --ignore-submodules=dirty)"
if [[ -n "$dirty_status" && "$allow_dirty" -eq 0 ]]; then
  echo "Working tree has uncommitted or untracked changes. Commit them first, or pass --allow-dirty for a local-only test." >&2
  echo "$dirty_status" >&2
  exit 1
fi

if [[ "$allow_dirty" -eq 1 ]]; then
  echo "--allow-dirty enabled: creating a local-only archive without pushing a tag or GitHub release." >&2
fi

if [[ "$allow_dirty" -eq 0 ]]; then
  current_branch="$(git branch --show-current)"
  if [[ "$current_branch" != "$release_branch" ]]; then
    echo "Release tags must be created from $release_branch, not $current_branch." >&2
    exit 1
  fi

  verify_release_branch_matches_head
  refresh_tag_state

  if ! command -v gh >/dev/null 2>&1; then
    echo "gh CLI is required to create the draft GitHub Release and dispatch release verification." >&2
    exit 1
  fi

  if ! gh auth status >/dev/null 2>&1; then
    echo "gh CLI is not authenticated." >&2
    exit 1
  fi

  github_repo="$(github_repo_for_remote "$remote")"
fi

if [[ "$skip_tests" -eq 0 ]]; then
  scripts/check.sh
fi

scripts/build-release.sh --version "$tag" --dist-root "$dist_root"
scripts/package-release.sh --dist-root "$dist_root" --output-dir "$output_dir"

if [[ "$output_dir" = /* ]]; then
  output_base="$output_dir"
else
  output_base="$repo_root/$output_dir"
fi
archive_path="$output_base/xcode-mcp-proxy-darwin-arm64.tar.gz"
checksum_path="$output_base/SHA256SUMS.txt"

if [[ ! -f "$archive_path" ]]; then
  echo "Expected release archive was not created: $archive_path" >&2
  exit 1
fi
if [[ ! -f "$checksum_path" ]]; then
  echo "Expected checksum file was not created: $checksum_path" >&2
  exit 1
fi

(
  cd "$output_base"
  shasum -a 256 -c SHA256SUMS.txt
)

if [[ "$allow_dirty" -eq 1 ]]; then
  echo "Created local-only release archive: $archive_path"
  echo "Created local-only checksum file: $checksum_path"
  echo "Skipped tag push, GitHub Release upload, and release workflow dispatch because --allow-dirty was supplied."
  exit 0
fi

verify_release_branch_matches_head
refresh_tag_state

if [[ "$tag_needs_push" -eq 1 ]]; then
  if ! git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    git tag -a "$tag" -m "Release $tag"
  fi
  git push "$remote" "$tag"
else
  echo "Remote tag already exists on $remote and points to HEAD; continuing release upload."
fi

if gh release view "$tag" --repo "$github_repo" >/dev/null 2>&1; then
  is_draft="$(gh release view "$tag" --repo "$github_repo" --json isDraft --jq '.isDraft')"
  if [[ "$is_draft" != "true" ]]; then
    echo "Release $tag already exists and is not a draft." >&2
    exit 1
  fi

  while IFS= read -r asset_name; do
    [[ -n "$asset_name" ]] || continue
    if ! is_release_asset "$asset_name"; then
      gh release delete-asset "$tag" "$asset_name" --repo "$github_repo" --yes
    fi
  done < <(gh release view "$tag" --repo "$github_repo" --json assets --jq '.assets[].name')

  gh release upload "$tag" "$archive_path" "$checksum_path" --repo "$github_repo" --clobber
else
  gh release create "$tag" "$archive_path" "$checksum_path" --repo "$github_repo" --draft --generate-notes --title "$tag" --verify-tag
fi

gh workflow run release.yml --repo "$github_repo" --ref "$tag" -f version="$tag"

echo "Created local release draft for $tag with assets:"
echo "  $archive_path"
echo "  $checksum_path"
echo "Dispatched Release Verification workflow for $tag"
echo "The workflow will publish the draft release after verification succeeds."
