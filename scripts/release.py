"""Prepare an existing draft and publish it with verified release assets."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys


ASSET_NAMES = ("xcode-mcp-proxy-darwin-arm64.tar.gz", "SHA256SUMS.txt", "install.sh")


class ReleaseError(Exception):
    pass


def run(arguments, *, input=None):
    result = subprocess.run(arguments, input=input, capture_output=True, text=True)
    if result.returncode:
        raise ReleaseError(f"{arguments[0]} failed: {result.stderr.strip()}\n{result.stdout.strip()}")
    return result.stdout


def api(endpoint, *, fields=None, paginate=False, method=None):
    arguments = ["gh", "api", "--method", method or ("PATCH" if fields is not None else "GET"), endpoint]
    if paginate:
        arguments += ["--paginate", "--slurp"]
    if fields is not None:
        arguments += ["--input", "-"]
    return json.loads(run(arguments, input=json.dumps(fields) if fields is not None else None))


def validate_request(version, source_sha):
    if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?", version):
        raise ReleaseError("Release tag must look like v1.2.3.")
    branch = os.environ["RELEASE_BRANCH"]
    if os.environ.get("GITHUB_ACTIONS") != "true" or os.environ.get("GITHUB_REF") != f"refs/heads/{branch}":
        raise ReleaseError(f"Release must run from the default branch: {branch}.")
    if source_sha != os.environ["GITHUB_SHA"] or run(["git", "rev-parse", "HEAD"]).strip() != source_sha:
        raise ReleaseError("Release source differs from the workflow checkout.")
    return os.environ["GITHUB_REPOSITORY"]


def tag_commit(repository, version):
    refs = api(f"repos/{repository}/git/matching-refs/tags/{version}")
    tag = next((ref["object"] for ref in refs if ref["ref"] == f"refs/tags/{version}"), None)
    if tag is None:
        return None
    while tag["type"] == "tag":
        tag = api(f"repos/{repository}/git/tags/{tag['sha']}")["object"]
    if tag["type"] != "commit":
        raise ReleaseError("Release tag does not point to a commit.")
    return tag["sha"]


def validate_tag(repository, version, source_sha):
    commit = tag_commit(repository, version)
    if commit is not None and commit != source_sha:
        raise ReleaseError("Release tag already points to a different commit.")
    return commit


def require_draft(release, version, source_sha, prerelease=None):
    if release["draft"] is not True or release["tag_name"] != version:
        raise ReleaseError("The selected release is no longer the requested draft.")
    if release["target_commitish"] != source_sha:
        raise ReleaseError("Draft target differs from the tested commit.")
    if prerelease is not None and release["prerelease"] is not prerelease:
        raise ReleaseError("Draft prerelease setting changed during this run.")
    if not (release.get("body") or "").strip():
        raise ReleaseError("Save the approved release notes in the draft before starting publication.")


def prepare(version, source_sha):
    repository = validate_request(version, source_sha)
    pages = api(f"repos/{repository}/releases?per_page=100", paginate=True)
    releases = [release for page in pages for release in page if release["tag_name"] == version]
    if len(releases) != 1:
        raise ReleaseError("Create one draft with the requested tag and approved notes before running Release.")
    release = releases[0]
    target = release["target_commitish"]
    if target not in (os.environ["RELEASE_BRANCH"], source_sha):
        raise ReleaseError("Draft must target the default branch or this workflow's exact commit.")
    require_draft({**release, "target_commitish": source_sha}, version, source_sha)
    validate_tag(repository, version, source_sha)
    if target != source_sha:
        release = api(f"repos/{repository}/releases/{release['id']}", fields={"target_commitish": source_sha})
        require_draft(release, version, source_sha)
    return release


def verify_uploads(release, checksums):
    assets = release["assets"]
    if len(assets) != len(checksums) or {asset["name"] for asset in assets} != set(checksums):
        raise ReleaseError("Release assets differ from the verified asset set.")
    for asset in assets:
        if asset["state"] != "uploaded" or asset.get("digest") != f"sha256:{checksums[asset['name']]}":
            raise ReleaseError(f"Release asset upload or checksum mismatch: {asset['name']}")


def confirm_publication(repository, release, version, source_sha, prerelease, checksums):
    if release["draft"] is not False or release["tag_name"] != version or release["prerelease"] is not prerelease:
        raise ReleaseError("Publication was not confirmed; inspect the release before retrying.")
    verify_uploads(release, checksums)
    if tag_commit(repository, version) != source_sha:
        raise ReleaseError("Published tag differs from the tested commit; inspect the release.")
    return release["html_url"]


def publish(version, source_sha, release_id, prerelease, directory, archive_sha256):
    repository = validate_request(version, source_sha)
    if not re.fullmatch(r"[0-9a-fA-F]{64}", archive_sha256):
        raise ReleaseError("Missing or malformed archive digest from the build job.")
    run([
        str(Path(__file__).with_name("verify-release-assets.sh")),
        "--version", version, "--repo", repository, "--release-dir", str(directory.resolve()),
        "--archive-sha256", archive_sha256,
    ])
    checksums = {}
    for name in ASSET_NAMES:
        digest = hashlib.sha256()
        with (directory / name).open("rb") as source:
            for block in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(block)
        checksums[name] = digest.hexdigest()
    endpoint = f"repos/{repository}/releases/{release_id}"
    release = api(endpoint)
    if release["draft"] is False:
        # Publication may succeed even if its response is lost. Confirm without changing it.
        return confirm_publication(repository, release, version, source_sha, prerelease, checksums)
    require_draft(release, version, source_sha, prerelease)
    validate_tag(repository, version, source_sha)
    run(["gh", "release", "upload", version, *(str(directory / name) for name in ASSET_NAMES),
         "--repo", repository, "--clobber"])
    release = api(endpoint)
    require_draft(release, version, source_sha, prerelease)
    verify_uploads(release, checksums)
    if validate_tag(repository, version, source_sha) is None:
        # Claim the tag before publication: GitHub ignores target_commitish for existing tags.
        # A concurrent ref creation fails here, while the release is still a draft.
        api(f"repos/{repository}/git/refs", method="POST", fields={
            "ref": f"refs/tags/{version}", "sha": source_sha,
        })
    # Publish the same release and keep its current title and notes untouched.
    published = api(endpoint, fields={
        "tag_name": version, "target_commitish": source_sha,
        "prerelease": prerelease, "draft": False,
    })
    return confirm_publication(repository, published, version, source_sha, prerelease, checksums)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("prepare", "publish"):
        command = commands.add_parser(name)
        command.add_argument("--version", required=True)
        command.add_argument("--source-sha", required=True)
        if name == "publish":
            command.add_argument("--release-id", type=int, required=True)
            command.add_argument("--prerelease", choices=("true", "false"), required=True)
            command.add_argument("--directory", type=Path, required=True)
            command.add_argument("--archive-sha256", required=True)
    args = parser.parse_args()
    try:
        if args.command == "prepare":
            release = prepare(args.version, args.source_sha)
            with open(os.environ["GITHUB_OUTPUT"], "a") as output:
                output.write(f"release-id={release['id']}\nprerelease={str(release['prerelease']).lower()}\n")
            print(f"Prepared draft {release['id']}: {args.version} at {args.source_sha}")
        else:
            url = publish(args.version, args.source_sha, args.release_id, args.prerelease == "true",
                          args.directory, args.archive_sha256)
            print(url)
            with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as summary:
                summary.write(f"## Release published\n\n[{args.version}]({url}) targets `{args.source_sha}`.\n")
    except (ReleaseError, OSError, ValueError, KeyError) as error:
        print(f"Release failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
