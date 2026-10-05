import copy
import hashlib
import io
import json
import unittest
from unittest.mock import patch
import zipfile

from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import package_release
import release
import release_sync as sync
from test_release_homebrew_ready import FakeTap


def archive(files):
    data = io.BytesIO()
    with zipfile.ZipFile(data, "w") as output:
        for name, content in files.items():
            output.writestr(name, content)
    return data.getvalue()


class FakeCore:
    repository = "example/core"

    def __init__(self):
        sha = "a" * 40
        self.draft = dict(id=42, tag_name="v1.2.3", target_commitish=sha, name="v1.2.3",
                          body="Approved notes", draft=True, prerelease=False)
        self.run = dict(id=99, workflow_id=11, head_branch="main", head_sha=sha, event="workflow_dispatch",
                        created_at="2026-10-01T00:00:00Z", status="completed", run_attempt=1,
                        display_title=f"Release draft 42 at {sha}")
        names = (sync.APPROVAL_JOB, "Check approved draft", "Package approved source and Formula",
                 "Test approved source / Package Checks", sync.RECEIPT_JOB, sync.PROBE_JOB, sync.TAP_APPROVAL_JOB)
        self.jobs = [dict(name=name, id=100 + n, run_attempt=1, status="completed", conclusion="success")
                     for n, name in enumerate(names)]
        self.calls = []
        digest = hashlib.sha256(b"prepared source").hexdigest()
        self.formula = package_release.render_formula("v1.2.3", self.repository, digest)
        sums = (f"{digest}  xcode-mcpkit-1.2.3.tar.gz\n"
                f"{hashlib.sha256(self.formula.encode()).hexdigest()}  xcode-mcpkit.rb\n")
        sums += f"{hashlib.sha256(b'installer').hexdigest()}  install.sh\n"
        self.receipt = dict(release_id=42, version="v1.2.3", target=sha,
                            content_digest=release.fingerprint(self.draft), source_artifact_id=2,
                            checksums_sha256=hashlib.sha256(sums.encode()).hexdigest())
        self.source_files = {"xcode-mcpkit-1.2.3.tar.gz": b"prepared source",
                             "xcode-mcpkit.rb": self.formula, "install.sh": b"installer", "SHA256SUMS.txt": sums}
        self.refresh_archives()

    def refresh_archives(self):
        self.bytes = {1: archive({"release-plan.json": json.dumps(self.receipt)}), 2: archive(self.source_files)}
        self.artifacts = [dict(id=key, name="release-plan-1" if key == 1 else "release-assets-1",
                               expired=False, created_at="2026-10-01T00:01:00Z",
                               digest="sha256:" + hashlib.sha256(value).hexdigest())
                          for key, value in self.bytes.items()]

    def api(self, path, method="GET", data=None):
        self.calls.append((path, method))
        if path == "": return dict(default_branch="main")
        if path == "actions/workflows/release.yml": return dict(id=11)
        if path.startswith("releases?"): return [copy.deepcopy(self.draft)]
        if path.startswith("actions/workflows/11/runs?"): return dict(workflow_runs=[copy.deepcopy(self.run)])
        if path.startswith("actions/runs/99/jobs?"): return dict(jobs=copy.deepcopy(self.jobs))
        if path.startswith("actions/runs/99/artifacts?"): return dict(artifacts=copy.deepcopy(self.artifacts))
        if path == "releases/42": return copy.deepcopy(self.draft)
        if path == "git/ref/tags/v1.2.3": return dict(object=dict(type="commit", sha="a" * 40))
        if path == "actions/runs/99": return copy.deepcopy(self.run)
        if path == "actions/jobs/105/rerun" and method == "POST":
            self.run["status"] = "in_progress"
            return {}
        raise AssertionError((path, method))


class ReleaseResumptionTests(unittest.TestCase):
    def setUp(self):
        self.core = FakeCore()
        block = ('\n  bottle do\n'
                 '    root_url "https://github.com/lynnswap/homebrew-tap/releases/download/xcode-mcpkit-1.2.3"\n'
                 f'    sha256 cellar: :any_skip_relocation, arm64_tahoe: "{"b" * 64}"\n  end\n')
        self.tap = FakeTap(self.core.formula.replace('  license "MIT"', '  license "MIT"' + block))
        self.bytes_patch = patch.object(sync, "artifact_bytes", side_effect=lambda gh, artifact_id: self.core.bytes[artifact_id])
        self.tap_patch = patch.object(release, "GitHub", return_value=self.tap)
        self.bytes_patch.start()
        self.tap_patch.start()
        self.addCleanup(self.bytes_patch.stop)
        self.addCleanup(self.tap_patch.stop)

    def result(self, dry_run=False):
        return sync.synchronize(self.core, dry_run)[0]

    def assert_no_writes(self):
        self.assertTrue(all(method == "GET" for _, method in self.core.calls))

    def test_ready_receipt_resumes_only_the_original_probe_and_dependents(self):
        value = self.result()
        self.assertEqual(value["status"], "resumed")
        self.assertEqual(value["job_id"], 105)
        self.assertEqual([call for call in self.core.calls if call[1] == "POST"], [("actions/jobs/105/rerun", "POST")])
        self.assertEqual(self.result()["status"], "running")

    def test_waiting_tap_and_dry_run_never_mutate(self):
        self.tap.formula = self.tap.formula.replace("v1.2.3.tar.gz", "v1.2.2.tar.gz")
        self.assertEqual(self.result()["status"], "waiting")
        self.assert_no_writes()
        self.tap.formula = self.tap.formula.replace("v1.2.2.tar.gz", "v1.2.3.tar.gz")
        self.assertEqual(self.result(dry_run=True)["status"], "ready")
        self.assert_no_writes()

    def test_changed_notes_and_wrong_receipt_release_require_attention(self):
        self.core.draft["body"] = "Unapproved change"
        self.assertEqual(self.result()["status"], "blocked")
        self.assert_no_writes()
        self.core.draft["body"] = "Approved notes"
        self.core.receipt["release_id"] = 43
        self.core.refresh_archives()
        self.assertEqual(self.result()["status"], "blocked")
        self.assert_no_writes()

    def test_unapproved_preparation_and_real_installation_failure_are_not_retried(self):
        for name in (sync.APPROVAL_JOB, "Test approved source / Package Checks"):
            original = copy.deepcopy(self.core.jobs)
            next(job for job in self.core.jobs if job["name"] == name)["conclusion"] = "failure"
            self.assertEqual(self.result()["status"], "blocked")
            self.core.jobs = original
        self.core.jobs.append(dict(name="Verify published tap installation", id=106, run_attempt=1,
                                   status="completed", conclusion="failure"))
        self.assertEqual(self.result()["status"], "blocked")
        self.assert_no_writes()

    def test_artifact_digest_expiry_and_source_checksum_failures_block_resumption(self):
        self.core.artifacts[0]["digest"] = "sha256:" + "0" * 64
        self.assertEqual(self.result()["status"], "blocked")
        self.core.refresh_archives()
        self.core.artifacts[1]["expired"] = True
        self.assertEqual(self.result()["status"], "blocked")
        self.core.source_files["xcode-mcpkit-1.2.3.tar.gz"] = b"changed source"
        self.core.refresh_archives()
        self.assertEqual(self.result()["status"], "blocked")
        self.assert_no_writes()

    def test_foreign_workflow_and_receipt_artifacts_do_not_authorize_actions(self):
        self.core.run["workflow_id"] = 12
        self.assertEqual(self.result()["status"], "waiting")
        self.core.run["workflow_id"] = 11
        self.core.receipt["source_artifact_id"] = 999
        self.core.refresh_archives()
        self.assertEqual(self.result()["status"], "blocked")
        self.assert_no_writes()

    def test_latest_attempt_failure_is_not_hidden_by_an_older_success(self):
        job = copy.deepcopy(self.core.jobs[0])
        job.update(id=200, run_attempt=2, conclusion="failure")
        self.core.jobs.append(job)
        self.assertEqual(self.result()["status"], "blocked")
        self.assert_no_writes()

    def test_prereleases_published_releases_and_running_runs_do_not_restart(self):
        self.core.draft["prerelease"] = True
        self.assertEqual(sync.synchronize(self.core), [])
        self.core.draft.update(prerelease=False, draft=False)
        self.assertEqual(sync.synchronize(self.core), [])
        self.core.draft["draft"] = True
        self.core.run["status"] = "in_progress"
        self.assertEqual(self.result()["status"], "running")
        self.assert_no_writes()

    def test_a_new_attempt_started_during_readiness_does_not_duplicate_rerun(self):
        api = self.core.api
        def changed(path, method="GET", data=None):
            if path == "actions/runs/99":
                self.core.run["run_attempt"] += 1
            return api(path, method, data)
        self.core.api = changed
        self.assertEqual(self.result()["status"], "running")
        self.assert_no_writes()

    def test_new_preparations_require_successful_tap_key_approval(self):
        self.core.jobs.append(dict(name=sync.TAP_APPROVAL_JOB, id=110, run_attempt=1,
                                   status="completed", conclusion="skipped"))
        self.assertEqual(self.result()["status"], "waiting")
        self.assert_no_writes()
        self.core.jobs[-1]["conclusion"] = "failure"
        self.assertEqual(self.result()["status"], "blocked")
        self.assert_no_writes()
        self.core.jobs[-1]["conclusion"] = "success"
        self.assertEqual(self.result(dry_run=True)["status"], "ready")
        self.assert_no_writes()

    def test_pre_receipt_runs_are_not_adopted_automatically(self):
        self.core.jobs = [job for job in self.core.jobs if job["name"] != sync.RECEIPT_JOB]
        self.assertEqual(self.result()["status"], "waiting")
        self.assert_no_writes()


if __name__ == "__main__":
    unittest.main()
