# Homebrew distribution

`lynnswap/tap/xcode-mcpkit` installs the server commands and
`XcodeMCPNativeHost.app` together in `libexec`. Only the commands are linked into
Homebrew's `bin`. A Swift client can discover the helper through the server link
on `PATH`, or supply its bundle explicitly.

The Formula builds versioned source with the checked-in `Package.resolved`.
`scripts/build-release.sh` stages the commands and calls
`scripts/build-native-host.sh`, which owns the native bundle's Info.plist,
public loader entitlement, and ad-hoc build signature. Swift compatibility libraries are
collected with `swift-stdlib-tool` and located relative to the executables.
Apple's private frameworks are loaded from the user's selected Xcode installation.

The tap builds Apple Silicon bottles on the GitHub-hosted `xcode-27` image and
registers them as `arm64_tahoe` for macOS 26 and later. The bottle receipt retains
the actual build environment. Before publication, the tap verifies ordinary
bottle installation, CLI startup, and signing on macOS 26 and the Xcode 27 runner.
Native and server MCP integration tests run on the Xcode 27 runner. The source
release also verifies the public bottle on that image without forcing selection.
A host without a matching bottle can build from source with Xcode 27. The
package's macOS 15.4 deployment target is separate from bottle availability.

## Publish a tagged release

After the target commit reaches the default branch, tag the reviewed commit and
push the tag:

```sh
git tag vX.Y.Z FULL_COMMIT_SHA
git push origin refs/tags/vX.Y.Z
```

The Release workflow tests the tagged commit, builds the arm64 macOS CLI and
native host, and prepares the source archive and Formula. Approve the
`release-signing` deployment after checking the tag and commit in the run.
That job signs the distribution with Developer ID Application, submits the
archive for Apple notarization, and staples the ticket to the native host app.
A separate job verifies signatures and the ticket from the extracted ZIP, then
runs an MCP smoke test. After verification passes, the workflow publishes the
GitHub Release with generated notes, the signed ZIP, and checksums. Tags such
as `v1.0.0-rc.1` publish as prereleases and skip stable tap dispatch.

After publication, the stable release workflow requests a Formula update in
`lynnswap/homebrew-tap`. The tap builds, signs, notarizes, and checks its bottle
using its own pipeline. A pending approval or failed tap job leaves the
published GitHub Release available. The `install.sh` asset uses Homebrew and
follows the tap's available version. To use the GitHub distribution directly,
extract the macOS arm64 ZIP, keep `bin` and `libexec` together, and run
`./xcode-mcpkit/bin/xcode-mcp-server`.

## Set up XcodeMCPKit release signing

1. In **Settings → Environments**, create `release-signing` in XcodeMCPKit.
   Require a maintainer reviewer and allow deployment from release tags
   matching `v*`. Restrict who can create or update those tags using a
   repository ruleset.
2. Export a **Developer ID Application** certificate **with its private key**
   as a password-protected `.p12` file. Use a team App Store Connect API key
   authorized for notarization and keep its `.p8` file.
3. Set the following secrets on the XcodeMCPKit environment. The tap's secrets
   are scoped to the tap repository.

   ```sh
   base64 -i /path/to/DeveloperID.p12 | tr -d '\n' |
     gh secret set DEVELOPER_ID_P12_BASE64 --repo lynnswap/XcodeMCPKit --env release-signing
   gh secret set DEVELOPER_ID_P12_PASSWORD --repo lynnswap/XcodeMCPKit --env release-signing
   gh secret set NOTARY_API_PRIVATE_KEY --repo lynnswap/XcodeMCPKit --env release-signing \
     < /path/to/AuthKey_KEY_ID.p8
   ```

4. Set `APPLE_TEAM_ID` as a repository Actions variable so both signing and
   verification can check the signing team. Set the notarization key ID and
   issuer ID on `release-signing`.

   ```sh
   gh variable set APPLE_TEAM_ID --repo lynnswap/XcodeMCPKit --body TEAM_ID
   gh variable set NOTARY_API_KEY_ID --repo lynnswap/XcodeMCPKit --env release-signing --body KEY_ID
   gh variable set NOTARY_API_ISSUER_ID --repo lynnswap/XcodeMCPKit --env release-signing --body ISSUER_ID
   ```

The post-publication tap dispatch uses the existing `release-publish`
environment. Allow deployment from release tags matching `v*` and keep
`TAP_DISPATCH_APP_CLIENT_ID` and `TAP_DISPATCH_APP_PRIVATE_KEY` there. The
GitHub App installation needs `Actions: write` on `lynnswap/homebrew-tap`.
The tap retains its own `release-signing` environment and bottle verification.

## Retry and legacy drafts

Rerun failed jobs in the tagged Release workflow after resolving the failure.
Publication resumes the draft created by the same Actions run and checks the
SHA-256 digests of uploaded assets. If publication already finished, the
rerun checks the published assets and succeeds.
If only Homebrew dispatch failed, rerun that job or inspect the tap Actions
run if the dispatch may have reached it.

Tags created before this workflow change retain the workflows from their
tagged commits. Existing drafts can use the legacy manual
`resume-release.yml` workflow on `main` where applicable. To use the
tag-triggered process, create a new version tag on a commit containing this
workflow.

## Local verification

Run the release protocol tests and workflow lint:

```sh
python3 -B -m unittest discover -s scripts/tests -v
actionlint
```

On a clean Apple Silicon Homebrew installation with Xcode 27 selected, package a
committed revision and verify both source and bottle installation:

```sh
python3 scripts/package_release.py create --source-root . \
  --commit "$(git rev-parse HEAD)" --version v0.0.0-local \
  --repo lynnswap/XcodeMCPKit --output-dir .build/homebrew-release
scripts/test-homebrew.sh .build/homebrew-release
```

Local preparation uses a Git archive for verification only. Release CI supplies
the downloaded canonical public archive through `--source-archive` and verifies
its tree before generating the publishable Formula. The verification script uses
its own tap and removes its installation afterward; it does not replace an
existing Homebrew or standalone installation. Failed verification retains its
temporary bottle files for diagnosis.

## Release installer

The release packager reads `Homebrew/installer.json` from the approved source
commit, fetches the shared installer at that full homebrew-tap revision, verifies
its SHA-256, and embeds it in `install.sh`. The release checksums and upload
verification cover this asset alongside the source archive and Formula. Update
the pin deliberately when adopting shared installer changes. The generated
installer uses macOS Bash and downloads no additional migration code at execution
time. Public release assets remain gated on the verified Homebrew delivery.

Prereleases omit `install.sh` because the installer uses the stable tap. Their
source archives and Formulae retain the existing isolated verification path.
