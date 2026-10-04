# Homebrew distribution

`lynnswap/tap/xcode-mcpkit` installs the two proxy commands and
`XcodeMCPNativeHost.app` together in `libexec`. Only the commands are linked into
Homebrew's `bin`. A Swift client can discover the helper through the server link
on `PATH`, or supply its bundle explicitly.

The Formula builds versioned source with the checked-in `Package.resolved`.
`scripts/build-release.sh` stages the commands and calls
`scripts/build-native-host.sh`, which owns the native bundle's Info.plist,
selected-Xcode entitlements, and signature. Swift compatibility libraries are
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
archive, `xcode-mcpkit.rb`, and `SHA256SUMS.txt`. The Release remains a Draft.
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
The tap's existing publisher uploads the tested bottle and merges the PR using
its own `GITHUB_TOKEN`, without another human deployment approval.

The source workflow installs the public bottle, checks its CLI versions and
signature, and exercises native and proxy MCP sessions against a disposable
project. It rechecks the tested delivery before publishing the approved Draft.
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
- Disable administrator bypass. Leave self-review enabled for the sole maintainer.
- Set `TAP_DISPATCH_APP_CLIENT_ID` to the existing App's Client ID.
- Register the same PEM key as `TAP_DISPATCH_APP_PRIVATE_KEY`. Environment secrets
  are scoped to each repository; another repository's registration is not inherited.

```sh
gh variable set TAP_DISPATCH_APP_CLIENT_ID --repo lynnswap/XcodeMCPKit \
  --env release-publish --body APP_CLIENT_ID
gh secret set TAP_DISPATCH_APP_PRIVATE_KEY --repo lynnswap/XcodeMCPKit \
  --env release-publish < /path/to/existing-app.private-key.pem
```

Only the dispatch job receives that key. The job executes the workflow's pinned
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
