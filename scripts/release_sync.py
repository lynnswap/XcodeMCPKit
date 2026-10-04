#!/usr/bin/env python3
"""Resume only delivery verification in an unchanged, approved prepared release."""

import argparse
import hashlib
import io
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import zipfile

import package_release
import release

PROBE_JOB = "Check stable tap delivery"
RECEIPT_JOB = "Record prepared release"
APPROVAL_JOB = "Prepare public approved source tag"
TAP_APPROVAL_JOB = "Start approved stable tap update"


def pages(github, path, field=None):
    items, page = [], 1
    while True:
        separator = "&" if "?" in path else "?"
        response = github.api(f"{path}{separator}per_page=100&page={page}")
        values = response[field] if field else response
        items.extend(values)
        if len(values) < 100:
            return items
        page += 1


def artifact_bytes(github, artifact_id):
    result = subprocess.run(["gh", "api", f"repos/{github.repository}/actions/artifacts/{artifact_id}/zip"],
                            capture_output=True, check=False)
    if result.returncode:
        raise release.ReleaseError(result.stderr.decode(errors="replace").strip())
    return result.stdout


def artifact_files(github, artifact, names):
    if artifact["expired"]:
        raise release.ReleaseError("Prepared release artifacts expired; a new preparation run is required.")
    data = artifact_bytes(github, artifact["id"])
    expected = "sha256:" + hashlib.sha256(data).hexdigest()
    if artifact.get("digest") != expected:
        raise release.ReleaseError("Transferred artifact bytes differ from their immutable GitHub digest.")
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        if any(archive.namelist().count(name) != 1 for name in names):
            raise release.ReleaseError("The prepared artifact has missing or ambiguous release files.")
        return {name: archive.read(name) for name in names}


def latest_jobs(github, run_id):
    latest = {}
    for job in pages(github, f"actions/runs/{run_id}/jobs?filter=all", "jobs"):
        old = latest.get(job["name"])
        if old is None or (job["run_attempt"], job["id"]) > (old["run_attempt"], old["id"]):
            latest[job["name"]] = job
    return latest


def prepared_candidate(github, draft, run):
    jobs = latest_jobs(github, run["id"])
    required = (APPROVAL_JOB, "Check approved draft", "Package approved source and Formula",
                "Test approved source / Package Checks", RECEIPT_JOB, TAP_APPROVAL_JOB)
    if RECEIPT_JOB not in jobs:
        return None, "This earlier preparation has no immutable release receipt."
    if jobs.get("Publish verified source release", {}).get("conclusion") == "success":
        return None, "The original run already completed publication."
    failed = [name for name, job in jobs.items() if name != PROBE_JOB
              and job["conclusion"] in ("failure", "cancelled", "timed_out", "action_required")]
    if failed:
        raise release.ReleaseError("Verification or publication needs attention: " + ", ".join(failed))
    if any(jobs.get(name, {}).get("conclusion") != "success" for name in required):
        return None, "Source approval or preparation checks have not succeeded."
    probe = jobs.get(PROBE_JOB)
    if probe is None or probe["status"] != "completed":
        return None, "The delivery probe has not completed."
    artifacts = pages(github, f"actions/runs/{run['id']}/artifacts", "artifacts")
    receipts = [item for item in artifacts if re.fullmatch(r"release-plan-[0-9]+", item["name"])]
    if not receipts:
        raise release.ReleaseError("The successful preparation job has no immutable release receipt.")
    receipt_artifact = max(receipts, key=lambda item: (item["created_at"], item["id"]))
    receipt = json.loads(artifact_files(github, receipt_artifact, ["release-plan.json"])["release-plan.json"])
    if receipt["release_id"] != draft["id"] or receipt["version"] != draft["tag_name"]:
        raise release.ReleaseError("The receipt describes a different release.")
    release.verify(github, draft["id"], receipt["target"], receipt["content_digest"])
    if release.tag_commit(github, draft["tag_name"]) != receipt["target"]:
        raise release.ReleaseError("The approved public source tag changed or disappeared.")
    source_artifacts = [item for item in artifacts if item["id"] == receipt["source_artifact_id"]]
    if len(source_artifacts) != 1:
        raise release.ReleaseError("The receipt's prepared source artifact does not belong to this run.")
    files = artifact_files(github, source_artifacts[0], package_release.asset_names(draft["tag_name"]))
    with tempfile.TemporaryDirectory(prefix="xcode-mcpkit-delivery-") as directory:
        root = Path(directory)
        for name, data in files.items():
            (root / name).write_bytes(data)
        package_release.verify(root, draft["tag_name"], receipt["checksums_sha256"])
        evidence = release.verify_homebrew_ready(release.GitHub(release.HOMEBREW_TAP), draft["tag_name"], root)
    return dict(run_id=run["id"], run_attempt=run["run_attempt"], job_id=probe["id"],
                release_id=draft["id"], version=draft["tag_name"], delivery=evidence), None


def synchronize(github, dry_run=False):
    branch = github.api("")["default_branch"]
    workflow = github.api("actions/workflows/release.yml")
    drafts = [item for item in pages(github, "releases") if item["draft"] and not item["prerelease"]]
    if not drafts:
        return []
    runs = pages(github, f"actions/workflows/{workflow['id']}/runs?event=workflow_dispatch", "workflow_runs")
    results = []
    for draft in drafts:
        value = dict(version=draft["tag_name"], release_id=draft["id"])
        title = f"Release draft {draft['id']} at {draft['target_commitish']}"
        matches = [run for run in runs if run["display_title"] == title
                   and run["workflow_id"] == workflow["id"] and run["event"] == "workflow_dispatch"
                   and run["head_branch"] == branch]
        if not matches:
            results.append(dict(value, status="waiting", reason="No matching source preparation run exists."))
            continue
        run = max(matches, key=lambda item: (item["created_at"], item["id"]))
        if run["status"] != "completed":
            results.append(dict(value, status="running", run_id=run["id"]))
            continue
        try:
            candidate, reason = prepared_candidate(github, draft, run)
            if candidate is None:
                results.append(dict(value, status="waiting", reason=reason))
                continue
            fresh = github.api(f"actions/runs/{run['id']}")
            if fresh["status"] != "completed" or fresh["run_attempt"] != candidate["run_attempt"]:
                results.append(dict(value, status="running", run_id=run["id"]))
                continue
            if not dry_run:
                github.api(f"actions/jobs/{candidate['job_id']}/rerun", "POST", {})
            results.append(dict(candidate, status="ready" if dry_run else "resumed"))
        except release.HomebrewPending as error:
            results.append(dict(value, status="waiting", reason=str(error)))
        except (release.ReleaseError, KeyError, ValueError, OSError, zipfile.BadZipFile) as error:
            results.append(dict(value, status="blocked", reason=str(error)))
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    record = commands.add_parser("record")
    record.add_argument("--release-id", type=int, required=True)
    record.add_argument("--version", required=True)
    record.add_argument("--target", required=True)
    record.add_argument("--content-digest", required=True)
    record.add_argument("--source-artifact-id", type=int, required=True)
    record.add_argument("--checksums-sha256", required=True)
    record.add_argument("--output", type=Path, required=True)
    resume = commands.add_parser("resume")
    resume.add_argument("--repo", required=True)
    resume.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    try:
        if args.command == "record":
            release.check_sha(args.target)
            args.output.write_text(json.dumps({key: getattr(args, key) for key in
                ("release_id", "version", "target", "content_digest", "source_artifact_id", "checksums_sha256")}) + "\n")
        else:
            results = synchronize(release.GitHub(args.repo), args.dry_run)
            print(json.dumps(results, indent=2))
            if any(item["status"] == "blocked" for item in results):
                return 1
        return 0
    except (release.ReleaseError, KeyError, ValueError, OSError, zipfile.BadZipFile) as error:
        print(error, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
