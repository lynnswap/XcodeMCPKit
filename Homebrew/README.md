# Homebrew distribution

`lynnswap/tap/xcode-mcpkit` installs the two proxy commands and
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
retains the builder's normal Homebrew platform tag. The source release verifies
installation on that image without forcing bottle selection. A host without a
matching bottle can build from source with Xcode 27. The package's macOS 15.4
deployment target and the environments covered by distribution checks are separate;
the deployment target alone does not establish older-host compatibility.

## Release an approved revision

After approving the version, full commit SHA, title, and release notes, run:

```sh
python3 scripts/release.py start vX.Y.Z --repo lynnswap/XcodeMCPKit \
  --target FULL_COMMIT_SHA --notes-file /path/to/notes.md
```

The script creates or reuses the matching Draft and dispatches `release.yml`
from the default branch. CI tests the approved source, creates its public source
tag, verifies GitHub's tag archive against that commit, and prepares the source
archive, `xcode-mcpkit.rb`, stable `install.sh`, and `SHA256SUMS.txt`. The Release remains a Draft.
The generated Formula uses the public tag archive, so tap CI can build it before
the Release is published.

Review the version, target, notes, Formula artifact, and trusted workflow commit
in the Actions summary. Approve the `release-publish` deployment to allow the job
to use the GitHub App key. It revalidates the approved content, then creates a
short-lived token restricted to `homebrew-tap` and `Actions: write`.

The job dispatches the tap's `update-formula.yml` with the source tag, commit,
and source/Formula digests. The tap checks those inputs against the public source,
creates or reuses a Formula PR, and starts bottle CI for its exact head. This path
handles the first Formula and subsequent versions; it does not use Renovate.
The tap prepares a candidate with the tested bottle artifact ID and digest.
Approve its `release-signing` deployment to allow Developer ID signing and
notarization. The signing job handles the bottle as data and does not build or
execute its payload. A separate job installs the signed bottle, checks the Team
ID and stable helper signing identifier, validates its notarization ticket, and
runs the native/proxy smoke tests. The tap then uploads that exact signed bottle
and merges the Formula PR automatically using its own `GITHUB_TOKEN`.

The source workflow installs the public bottle, checks its CLI versions and
signature, and exercises native and proxy MCP sessions against a disposable
project. The Formula test covers CLI options and signatures; Xcode integration
runs outside Homebrew's test sandbox in both tap CI and source-release CI.
The source publisher rechecks the tested delivery before publishing the approved Draft.
Stable publication never runs when the bottle is missing or installation fails.
An existing running server must be restarted to use an upgraded payload.

Prerelease tags such as `v1.0.0-rc.1` use an isolated verification tap to build,
bottle, reinstall, and test the Formula. They do not update the stable tap or
replace the latest stable release.

## Configure the GitHub App and approval

The existing `lynnswap-homebrew-release-dispatch` App can be reused. Its
installation must include `homebrew-tap` with `Actions: write`. Adding this source
repository to the installation is unnecessary for dispatching to the tap; the
source workflow uses its own `GITHUB_TOKEN` for source tags and releases.

In XcodeMCPKit's `release-publish` Environment:

- Require the maintainer as reviewer and restrict deployment branches to `main`.
- Disable administrator bypass. Leave **Prevent self-review** off for the sole maintainer.
- Set `TAP_DISPATCH_APP_CLIENT_ID` to the existing App's Client ID.
- Register the same PEM key as `TAP_DISPATCH_APP_PRIVATE_KEY`. Environment secrets
  are scoped to each repository; another repository's registration is not inherited.

```sh
gh variable set TAP_DISPATCH_APP_CLIENT_ID --repo lynnswap/XcodeMCPKit \
  --env release-publish --body APP_CLIENT_ID
gh secret set TAP_DISPATCH_APP_PRIVATE_KEY --repo lynnswap/XcodeMCPKit \
  --env release-publish < /path/to/existing-app.private-key.pem
```

In the tap's separate `release-signing` Environment, require the maintainer as
reviewer, restrict branches to `main`, and disable administrator bypass. Register
`DEVELOPER_ID_P12_BASE64`, `DEVELOPER_ID_P12_PASSWORD`, and
`NOTARY_API_PRIVATE_KEY` as Environment secrets. Set `APPLE_TEAM_ID`,
`NOTARY_API_KEY_ID`, and `NOTARY_API_ISSUER_ID` as Environment variables. The
installed helper uses signing identifier `com.lynnswap.XcodeMCPNativeHost`; its
Team ID and signing identifier remain stable across bottle upgrades.

Only the source dispatch job receives the GitHub App key. The job executes the workflow's pinned
trusted scripts and revokes its installation token when it finishes. The tap
maintains its own CI, publication permissions, and approval settings; see its
[maintenance guide](https://github.com/lynnswap/homebrew-tap/blob/main/CONTRIBUTING.md).

## Retry and resume

While tap delivery is pending, the source workflow leaves the Draft and immutable
prepared assets. `resume-release.yml` checks every 15 minutes and reruns delivery
verification and its dependent jobs after the matching bottle is public. It reuses
the completed source tests, source archive, and tap-dispatch approval. It can also
be dispatched manually from `main`.

Actual build, install, authentication, or publication failures need attention;
the resumer does not repeatedly retry them. Rerun the failed jobs after fixing
the reported cause. A failed dispatch can have an uncertain acceptance outcome:
inspect tap Actions before retrying. Repeated notifications reuse the same PR
and CI; changed or closed proposals require inspection.

Keep the approved target and publication content unchanged during a run. Changed
notes or tag identity stop publication. Artifacts are retained for 35 days, while
GitHub's job-rerun window also applies; expired preparation requires a new run.
Public source tags and any already-published tap bottles remain if a later step
fails. Previously published binary releases and their installer assets are retained.

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
