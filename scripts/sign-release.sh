#!/usr/bin/env bash
set -euo pipefail

host_identifier=com.lynnswap.XcodeMCPNativeHost

verify_signature() {
  local file="$1" details
  codesign --verify --deep --strict "$file"
  details="$(codesign -d --verbose=4 "$file" 2>&1)"
  grep -Fx "TeamIdentifier=$APPLE_TEAM_ID" <<< "$details"
  grep -q '^Authority=Developer ID Application: ' <<< "$details"
  grep -q '^CodeDirectory .*flags=.*runtime' <<< "$details"
  grep -Eq '^Timestamp=.+$' <<< "$details"
  ! grep -Fxq 'Timestamp=none' <<< "$details"
}

verify_release() {
  local host="$1/libexec/XcodeMCPNativeHost.app"
  verify_signature "$1/libexec/xcode-mcp-server"
  verify_signature "$host"
  codesign -d --verbose=4 "$host" 2>&1 | grep -Fx "Identifier=$host_identifier"
  xcrun stapler validate "$host"
  spctl --assess --type execute "$host"
}

: "${APPLE_TEAM_ID:?Set APPLE_TEAM_ID}"
if [[ $# == 2 && "$1" == verify ]]; then
  verify_release "$2"
  exit
fi
if [[ $# != 3 || "$1" != sign ]]; then
  echo 'Usage: sign-release.sh sign PREFIX OUTPUT_ZIP | sign-release.sh verify PREFIX' >&2
  exit 2
fi

prefix="$2"
output="$3"
payload="$prefix/libexec"
host="$payload/XcodeMCPNativeHost.app"
test -f "$payload/xcode-mcp-server"
test -d "$host"
: "${DEVELOPER_ID_P12_BASE64:?Set DEVELOPER_ID_P12_BASE64}"
: "${DEVELOPER_ID_P12_PASSWORD:?Set DEVELOPER_ID_P12_PASSWORD}"
: "${NOTARY_API_PRIVATE_KEY:?Set NOTARY_API_PRIVATE_KEY}"
: "${NOTARY_API_KEY_ID:?Set NOTARY_API_KEY_ID}"
: "${NOTARY_API_ISSUER_ID:?Set NOTARY_API_ISSUER_ID}"

umask 077
credentials="$(mktemp -d)"
keychain="$credentials/signing.keychain-db"
previous_keychains=()
while IFS= read -r line; do
  [[ "$line" =~ \"(.*)\" ]] && previous_keychains+=("${BASH_REMATCH[1]}")
done < <(security list-keychains -d user)
cleanup() {
  security list-keychains -d user -s "${previous_keychains[@]}" || true
  security delete-keychain "$keychain" || true
  rm -rf "$credentials"
}
trap cleanup EXIT

printf '%s' "$DEVELOPER_ID_P12_BASE64" | base64 -D > "$credentials/identity.p12"
printf '%s\n' "$NOTARY_API_PRIVATE_KEY" > "$credentials/notary.p8"
unset DEVELOPER_ID_P12_BASE64 NOTARY_API_PRIVATE_KEY
password="$(openssl rand -hex 32)"
security create-keychain -p "$password" "$keychain"
security set-keychain-settings -lut 7200 "$keychain"
security unlock-keychain -p "$password" "$keychain"
security import "$credentials/identity.p12" -k "$keychain" -f pkcs12 -x -P "$DEVELOPER_ID_P12_PASSWORD" -T /usr/bin/codesign
unset DEVELOPER_ID_P12_PASSWORD
rm "$credentials/identity.p12"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$keychain" >/dev/null
security list-keychains -d user -s "$keychain" "${previous_keychains[@]}"
identity="$(security find-identity -v -p codesigning "$keychain" |
  awk -v team="($APPLE_TEAM_ID)" 'index($0, "Developer ID Application: ") && index($0, team) {print $2; count++} END {if (count != 1) exit 1}')"

sign=(codesign --force --sign "$identity" --keychain "$keychain" --timestamp --options runtime)
while IFS= read -r -d '' file; do
  "${sign[@]}" "$file"
  verify_signature "$file"
done < <(find "$payload" -type f \( -name '*.dylib' -o -name XcodeMCPPreviewRenderer -o -name xcode-mcp-server \) -print0)
"${sign[@]}" --identifier "$host_identifier" --preserve-metadata=entitlements "$host"

report="$credentials/notary.json"
ditto -c -k --keepParent "$prefix" "$credentials/payload.zip"
auth=(--key "$credentials/notary.p8" --key-id "$NOTARY_API_KEY_ID" --issuer "$NOTARY_API_ISSUER_ID")
xcrun notarytool submit "$credentials/payload.zip" "${auth[@]}" --wait --timeout 30m --output-format json > "$report"
status="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["status"])' "$report")"
if [[ "$status" != Accepted ]]; then
  submission="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["id"])' "$report")"
  xcrun notarytool log "$submission" "${auth[@]}"
  exit 1
fi
xcrun stapler staple "$host"
verify_release "$prefix"
ditto -c -k --keepParent "$prefix" "$output"
