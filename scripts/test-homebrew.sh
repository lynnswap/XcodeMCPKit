#!/usr/bin/env bash
set -euo pipefail

release_dir="${1:?Usage: scripts/test-homebrew.sh <release-dir>}"
release_dir="$(cd "$release_dir" && pwd)"
formula=xcodemcpkit/verification/xcode-mcpkit
if brew list --formula --versions xcode-mcpkit >/dev/null 2>&1; then
  echo "Use a clean Homebrew installation to verify xcode-mcpkit; an existing keg was not changed." >&2
  exit 1
fi
work="$(mktemp -d)"
cleanup() {
  result=$?
  trap - EXIT
  if brew list --formula --versions xcode-mcpkit >/dev/null 2>&1; then
    brew uninstall --force "$formula" || result=1
  fi
  brew untap xcodemcpkit/verification || result=1
  if [[ "$result" == 0 ]]; then rm -rf "$work"; else echo "Verification files remain at $work" >&2; fi
  exit "$result"
}
brew tap-new xcodemcpkit/verification
trap cleanup EXIT
tap_root="$(brew --repository xcodemcpkit/verification)"
cp "$release_dir/xcode-mcpkit.rb" "$tap_root/Formula/xcode-mcpkit.rb"
source_archive="$(find "$release_dir" -maxdepth 1 -name 'xcode-mcpkit-*.tar.gz' -print)"
cache="$(brew --cache --build-from-source "$formula")"
mkdir -p "$(dirname "$cache")"
cp "$source_archive" "$cache"
brew trust --formula "$formula"
brew install --build-bottle "$formula"
brew test "$formula"
cd "$work"
brew bottle --json --root-url=https://example.invalid/xcodemcpkit-verification "$formula"
brew bottle --merge --write --no-commit "$work/"*.bottle.json
bottle_cache="$(brew --cache --force-bottle "$formula")"
cp "$work/"*.bottle.tar.gz "$bottle_cache"
brew uninstall "$formula"
brew install --force-bottle "$formula"
brew info --json=v2 "$formula" | python3 -c '
import json, sys
if not json.load(sys.stdin)["formulae"][0]["installed"][0]["poured_from_bottle"]:
    sys.exit("Verification expected a bottle installation.")
'
brew test "$formula"
