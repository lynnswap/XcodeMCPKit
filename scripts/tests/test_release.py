"""Release protocol tests; all GitHub writes are in-memory."""
import copy
import contextlib
import io
import hashlib
from pathlib import Path
import tempfile
import json
import subprocess
import unittest
from unittest.mock import patch

import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import release

SHA = "a" * 40
OTHER = "b" * 40


def draft(**changes):
    value = dict(id=42, tag_name="v0.1.0", target_commitish=SHA,
                 name="First release", body="One\n\nTwo\n", prerelease=False,
                 draft=True, assets=[], html_url="https://github.com/example/project/releases/42")
    value.update(changes)
    return value


class FakeGitHub:
    repository = "example/project"

    def __init__(self, item=None):
        self.release = copy.deepcopy(item)
        self.tag = None
        self.calls = []
        self.dispatch_error = False
        self.publish_error = False
        self.tag_error = False
        self.after_tag = None
        self.before_publish = None
        self.older_page = False
        self.upload_error = False
        self.after_upload = None

    @property
    def writes(self):
        return [call for call in self.calls if call[1] != "GET"]

    def upload(self, tag, paths):
        self.calls.append(("upload", "POST", tag))
        self.release["assets"] = [dict(name=path.name, state="uploaded",
            digest="sha256:" + hashlib.sha256(path.read_bytes()).hexdigest()) for path in paths]
        if self.upload_error:
            self.release["assets"].pop()
            raise subprocess.CalledProcessError(1, "gh release upload")
        if self.after_upload:
            self.after_upload(self)

    def api(self, path, method="GET", data=None):
        self.calls.append((path, method, copy.deepcopy(data)))
        if path == "":
            return {"default_branch": "main"}
        if path.startswith("commits/"):
            return {"sha": path.split("/")[-1]}
        if path.startswith("git/ref/tags/"):
            if self.tag is None:
                raise release.APIError(404, "Not Found")
            return {"object": dict(type="commit", sha=self.tag)}
        if path.startswith("releases?"):
            if self.older_page and path.endswith("page=1"):
                return [draft(id=i, tag_name=f"old-{i}") for i in range(100)]
            return [copy.deepcopy(self.release)] if self.release else []
        if path == "releases" and method == "POST":
            self.release = dict(data, id=42, assets=[], html_url="https://github.com/example/project/releases/42")
            return copy.deepcopy(self.release)
        if path in ("actions/workflows/release.yml/dispatches", "actions/workflows/update-formula.yml/dispatches"):
            if self.dispatch_error:
                raise release.APIError(503, "Dispatch response unavailable")
            return None
        if path == "git/refs" and method == "POST":
            if self.tag_error:
                raise release.APIError(403, "Resource not accessible by integration: workflows permission required")
            self.tag = data["sha"]
            if self.after_tag:
                self.after_tag(self)
            return {"ref": data["ref"]}
        if path == "releases/42":
            if method == "PATCH":
                if self.publish_error:
                    raise release.APIError(503, "Publication failed")
                if self.before_publish:
                    self.before_publish(self)
                self.release.update({key: value for key, value in data.items() if key != "make_latest"})
            return copy.deepcopy(self.release)
        raise AssertionError((path, method, data))


class ReleaseTests(unittest.TestCase):
    def test_published_release_retries_reject_missing_or_changed_assets_without_writes(self):
        for damage in (lambda assets: assets.pop(),
                       lambda assets: assets[0].update(digest="sha256:" + "0" * 64)):
            github = FakeGitHub(draft())
            digest = release.fingerprint(github.release)
            self.publish(github, digest)
            self.assertFalse(github.release["draft"])
            damage(github.release["assets"])
            writes = len(github.writes)
            with self.assertRaises(release.ReleaseError):
                self.publish(github, digest)
            self.assertEqual(len(github.writes), writes)

    def setUp(self):
        self.tested_delivery = dict(formula_sha256="a" * 64, bottle_sha256="b" * 64, bottle_url="https://example.test/verified.bottle.tar.gz")
        readiness = patch("release.verify_homebrew_ready", return_value=self.tested_delivery.copy())
        self.readiness = readiness.start()
        self.addCleanup(readiness.stop)
        self.output = io.StringIO()
        self.redirect = contextlib.redirect_stdout(self.output)
        self.redirect.__enter__()
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.release_dir = Path(directory.name)
        for name in release.asset_names("v0.1.0"):
            (self.release_dir / name).write_text("verified " + name)

    def tearDown(self):
        self.redirect.__exit__(None, None, None)

    def start(self, github, **overrides):
        values = dict(tag="v0.1.0", sha=SHA, title="First release",
                      notes="One\n\nTwo\n")
        values.update(overrides)
        release.start(github, **values)

    def publish(self, github, digest):
        release.publish(github, 42, SHA, digest, self.release_dir, self.tested_delivery)

    def test_stable_tag_notification_starts_only_the_main_tap_workflow(self):
        github = FakeGitHub()
        release.dispatch_tap(github, "lynnswap/XcodeMCPKit", "v0.1.0", SHA, self.release_dir)
        self.assertEqual(github.writes, [("actions/workflows/update-formula.yml/dispatches", "POST",
            dict(ref="main", inputs=dict(source_repository="lynnswap/XcodeMCPKit", source_tag="v0.1.0", source_sha=SHA,
                source_sha256=hashlib.sha256((self.release_dir / release.asset_names("v0.1.0")[0]).read_bytes()).hexdigest(),
                formula_sha256=hashlib.sha256((self.release_dir / "xcode-mcpkit.rb").read_bytes()).hexdigest())))])
        self.assertIsNone(github.tag)
        self.assertIsNone(github.release)

    def test_prereleases_and_invalid_tags_do_not_notify_the_stable_tap(self):
        github = FakeGitHub()
        release.dispatch_tap(github, "lynnswap/XcodeMCPKit", "v0.3.5-rc.1", SHA, self.release_dir)
        for tag in ("custom-v0.1.0", "main", "v0.1.0\n", "v0.1.0; command"):
            with self.subTest(tag=tag), self.assertRaises((release.ReleaseError, ValueError, subprocess.CalledProcessError)):
                release.dispatch_tap(github, "lynnswap/XcodeMCPKit", tag, SHA, self.release_dir)
        self.assertEqual(github.calls, [])

    def test_failed_notification_reports_the_remaining_tag_without_retrying(self):
        github = FakeGitHub()
        github.dispatch_error = True
        with self.assertRaisesRegex(release.ReleaseError, "Public source tag v0.1.0 remains"):
            release.dispatch_tap(github, "lynnswap/XcodeMCPKit", "v0.1.0", SHA, self.release_dir)
        self.assertEqual(len(github.writes), 1)

    def test_start_keeps_notes_and_pins_dispatch_without_creating_tag(self):
        github = FakeGitHub()
        self.start(github)
        self.assertEqual(github.release, draft())
        self.assertIsNone(github.tag)
        self.assertEqual([call[0] for call in github.writes],
                         ["releases", "actions/workflows/release.yml/dispatches"])
        dispatch = github.writes[-1][2]
        self.assertEqual(dispatch["ref"], "main")
        self.assertEqual(dispatch["inputs"], dict(
            release_id="42", target_sha=SHA, content_digest=release.fingerprint(draft())))

    def test_start_reuses_matching_draft_in_later_page(self):
        github = FakeGitHub(draft())
        github.older_page = True
        self.start(github)
        self.assertEqual(len(github.writes), 1)
        self.assertIn("dispatches", github.writes[0][0])

    def test_existing_content_or_published_release_is_not_overwritten(self):
        for changes in (dict(body="Changed"), dict(name="Changed"),
                        dict(target_commitish=OTHER), dict(prerelease=True), dict(draft=False)):
            with self.subTest(changes=changes):
                github = FakeGitHub(draft(**changes))
                with self.assertRaises(release.ReleaseError):
                    self.start(github)
                self.assertEqual(github.writes, [])

    def test_dispatch_failure_leaves_reusable_draft(self):
        github = FakeGitHub()
        github.dispatch_error = True
        with self.assertRaisesRegex(release.ReleaseError, "Draft 42 remains"):
            self.start(github)
        self.assertTrue(github.release["draft"])
        self.assertIsNone(github.tag)
        github.dispatch_error = False
        self.start(github)
        self.assertEqual(sum(call[0] == "releases" for call in github.writes), 1)

    def test_branch_target_or_conflicting_tag_never_creates_draft(self):
        for target, tag in (("main", None), (SHA, OTHER)):
            github = FakeGitHub()
            github.tag = tag
            with self.assertRaises(release.ReleaseError):
                self.start(github, sha=target)
            self.assertEqual(github.writes, [])

    def test_annotated_tags_are_peeled(self):
        github = FakeGitHub()
        with patch.object(github, "api", side_effect=[
            {"object": {"type": "tag", "sha": OTHER}},
            {"object": {"type": "commit", "sha": SHA}},
        ]):
            self.assertEqual(release.check_tag(github, "v0.1.0", SHA), SHA)

    def test_lookup_failure_is_not_treated_as_missing_tag(self):
        github = FakeGitHub()
        with patch.object(github, "api", side_effect=release.APIError(403, "Forbidden")):
            with self.assertRaises(release.APIError):
                release.tag_commit(github, "v0.1.0")

    def test_verify_detects_content_target_and_tag_changes_without_writes(self):
        original = draft()
        for changes in (dict(body="Changed"), dict(name="Changed"), dict(prerelease=True),
                        dict(tag_name="v0.2.0"), dict(target_commitish=OTHER)):
            github = FakeGitHub(draft(**changes))
            with self.assertRaises(release.ReleaseError):
                release.verify(github, 42, SHA, release.fingerprint(original))
            self.assertEqual(github.writes, [])
        github = FakeGitHub(original)
        github.tag = OTHER
        with self.assertRaises(release.ReleaseError):
            self.publish(github, release.fingerprint(original))
        self.assertEqual(github.writes, [])

    def test_verify_ignores_unrelated_metadata_and_never_publishes(self):
        github = FakeGitHub(draft(updated_at="later", download_count=10))
        release.verify(github, 42, SHA, release.fingerprint(draft()))
        self.assertEqual(github.writes, [])
        self.assertTrue(github.release["draft"])

    def test_source_preparation_creates_only_the_approved_tag_and_keeps_release_draft(self):
        github = FakeGitHub(draft())
        digest = release.fingerprint(github.release)
        prepared = release.prepare_source(github, 42, SHA, digest)
        self.assertTrue(prepared["draft"])
        self.assertEqual(github.tag, SHA)
        self.assertEqual(github.writes, [("git/refs", "POST", dict(ref="refs/tags/v0.1.0", sha=SHA))])
        github.calls.clear()
        release.prepare_source(github, 42, SHA, digest)
        self.assertEqual(github.writes, [])

    def test_source_preparation_stops_for_changed_draft_tag_or_tag_permissions(self):
        for mutation in (lambda g: g.release.update(body="unapproved"),
                         lambda g: setattr(g, "tag", OTHER),
                         lambda g: setattr(g, "tag_error", True)):
            with self.subTest(mutation=mutation):
                github = FakeGitHub(draft())
                mutation(github)
                with self.assertRaises(release.ReleaseError):
                    release.prepare_source(github, 42, SHA, release.fingerprint(draft()))
                self.assertTrue(github.release["draft"])
                self.assertFalse(any(call[0] == "upload" or call[1] == "PATCH" for call in github.writes))

    def test_draft_change_during_source_tag_creation_stops_preparation(self):
        github = FakeGitHub(draft())
        github.after_tag = lambda g: g.release.update(body="edited")
        with self.assertRaises(release.ReleaseError):
            release.prepare_source(github, 42, SHA, release.fingerprint(draft()))
        self.assertTrue(github.release["draft"])
        self.assertEqual(github.tag, SHA)

    def test_publish_creates_exact_tag_and_preserves_stable_or_prerelease_content(self):
        for prerelease in (False, True):
            tag = "v0.1.0-rc.1" if prerelease else "v0.1.0"
            for name in release.asset_names(tag):
                (self.release_dir / name).write_text("verified " + name)
            github = FakeGitHub(draft(tag_name=tag, prerelease=prerelease))
            digest = release.fingerprint(github.release)
            self.publish(github, digest)
            self.assertEqual(github.tag, SHA)
            self.assertFalse(github.release["draft"])
            self.assertEqual(release.fingerprint(github.release), digest)
            self.assertEqual(github.writes[1], ("git/refs", "POST", dict(ref="refs/tags/" + tag, sha=SHA)))
            self.assertEqual(github.writes[2][2], dict(
                tag_name=tag, target_commitish=SHA, name="First release",
                body="One\n\nTwo\n", prerelease=prerelease, draft=False,
                make_latest="false" if prerelease else "legacy"))

    def test_publish_writes_approved_fields_even_if_the_draft_changes_after_verification(self):
        github = FakeGitHub(draft())
        digest = release.fingerprint(github.release)
        github.before_publish = lambda state: state.release.update(
            name="Unapproved title", body="Unapproved notes", tag_name="v9.9.9",
            target_commitish=OTHER, prerelease=True)
        self.publish(github, digest)
        self.assertEqual(release.fingerprint(github.release), digest)
        self.assertFalse(github.release["draft"])
        self.assertEqual(github.tag, SHA)

    def test_unexpected_assets_stop_publication_without_removing_them(self):
        github = FakeGitHub(draft(assets=[{"id": 91, "name": "unapproved.zip"}]))
        with self.assertRaisesRegex(release.ReleaseError, "Remove unexpected draft assets"):
            self.publish(github, release.fingerprint(draft()))
        self.assertEqual(github.writes, [])
        self.assertEqual(github.release["assets"][0]["id"], 91)

    def test_failed_upload_leaves_draft_and_can_resume(self):
        github = FakeGitHub(draft())
        github.upload_error = True
        digest = release.fingerprint(draft())
        with self.assertRaisesRegex(release.ReleaseError, "Draft/assets or tag"):
            self.publish(github, digest)
        self.assertTrue(github.release["draft"])
        self.assertIsNone(github.tag)
        github.upload_error = False
        self.publish(github, digest)
        self.assertFalse(github.release["draft"])
        self.assertEqual({asset["name"] for asset in github.release["assets"]}, set(release.asset_names("v0.1.0")))

    def test_changed_uploads_stop_publication(self):
        def corrupt(state):
            state.release["assets"][0]["digest"] = "sha256:" + "0" * 64
        def missing(state):
            state.release["assets"].pop()
        def extra(state):
            state.release["assets"].append(dict(name="unknown.zip"))
        def notes(state):
            state.release["body"] = "Unapproved notes"
        for mutation in (corrupt, missing, extra, notes):
            with self.subTest(mutation=mutation.__name__):
                github = FakeGitHub(draft())
                github.after_upload = mutation
                with self.assertRaises(release.ReleaseError):
                    self.publish(github, release.fingerprint(draft()))
                self.assertTrue(github.release["draft"])
                self.assertIsNone(github.tag)

    def test_start_classifies_prerelease_and_rejects_empty_notes(self):
        github = FakeGitHub()
        self.start(github, tag="v0.1.0-rc.1")
        self.assertTrue(github.release["prerelease"])
        github = FakeGitHub()
        with self.assertRaisesRegex(release.ReleaseError, "approved release notes"):
            self.start(github, notes="  ")
        self.assertEqual(github.writes, [])

    def test_failed_publication_can_resume_without_recreating_tag(self):
        github = FakeGitHub(draft())
        digest = release.fingerprint(github.release)
        github.publish_error = True
        with self.assertRaisesRegex(release.ReleaseError, "Draft/assets or tag"):
            self.publish(github, digest)
        self.assertTrue(github.release["draft"])
        self.assertEqual(github.tag, SHA)
        github.publish_error = False
        self.publish(github, digest)
        self.assertFalse(github.release["draft"])
        self.assertEqual(sum(call[0] == "git/refs" for call in github.writes), 1)
        github.calls = []
        self.publish(github, digest)
        self.assertEqual(github.writes, [])

    def test_changed_tap_after_approval_blocks_stable_publication_and_can_resume(self):
        github = FakeGitHub(draft())
        digest = release.fingerprint(github.release)
        self.readiness.side_effect = release.ReleaseError("Homebrew is not ready")
        with self.assertRaisesRegex(release.ReleaseError, "Homebrew is not ready"):
            self.publish(github, digest)
        self.assertTrue(github.release["draft"])
        self.assertFalse(any(call[1] == "PATCH" for call in github.writes))
        self.readiness.side_effect = None
        self.publish(github, digest)
        self.assertFalse(github.release["draft"])
        github.calls.clear()
        self.readiness.reset_mock()
        self.readiness.side_effect = release.ReleaseError("Tap now has a newer version")
        self.publish(github, digest)
        self.assertEqual(github.writes, [])
        self.readiness.assert_not_called()

    def test_prerelease_publication_does_not_require_a_stable_tap_update(self):
        tag = "v0.1.0-rc.1"
        for name in release.asset_names(tag):
            (self.release_dir / name).write_text("verified " + name)
        github = FakeGitHub(draft(tag_name=tag, prerelease=True))
        self.readiness.side_effect = release.ReleaseError("Stable tap not updated")
        self.publish(github, release.fingerprint(github.release))
        self.assertFalse(github.release["draft"])
        self.readiness.assert_not_called()

    def test_changed_installed_bottle_identity_blocks_publication_until_reverified(self):
        for key, value in (("formula_sha256", "d" * 64), ("bottle_sha256", "c" * 64), ("bottle_url", "https://example.test/rebuilt.bottle.tar.gz")):
            with self.subTest(key=key):
                github = FakeGitHub(draft())
                current = dict(self.tested_delivery, **{key: value})
                self.readiness.return_value = current
                digest = release.fingerprint(github.release)
                with self.assertRaisesRegex(release.ReleaseError, "Re-run Verify published tap installation"):
                    self.publish(github, digest)
                self.assertTrue(github.release["draft"])
                self.assertFalse(any(call[1] == "PATCH" for call in github.writes))
                release.publish(github, 42, SHA, digest, self.release_dir, current)
                self.assertFalse(github.release["draft"])

    def test_stable_publication_requires_installed_bottle_evidence_before_writes(self):
        github = FakeGitHub(draft())
        with self.assertRaisesRegex(release.ReleaseError, "installed and verified"):
            release.publish(github, 42, SHA, release.fingerprint(github.release), self.release_dir)
        self.assertEqual(github.writes, [])

    def test_change_during_tag_creation_stops_publication(self):
        github = FakeGitHub(draft())
        github.after_tag = lambda state: state.release.update(body="Edited during CI")
        with self.assertRaises(release.ReleaseError):
            self.publish(github, release.fingerprint(draft()))
        self.assertTrue(github.release["draft"])
        self.assertEqual(len(github.writes), 2)

    def test_tag_permission_failure_preserves_draft_and_can_resume_after_fixing_rules(self):
        github = FakeGitHub(draft())
        digest = release.fingerprint(github.release)
        github.tag_error = True
        with self.assertRaisesRegex(release.ReleaseError, "GITHUB_TOKEN could not create the tested tag"):
            self.publish(github, digest)
        self.assertTrue(github.release["draft"])
        self.assertIsNone(github.tag)
        self.assertFalse(any(call[1] == "PATCH" for call in github.writes))
        github.tag_error = False
        self.publish(github, digest)
        self.assertEqual(github.tag, SHA)
        self.assertFalse(github.release["draft"])

    def test_racing_tag_creation_only_accepts_the_same_commit(self):
        for actual in (SHA, OTHER):
            github = FakeGitHub(draft())
            def create(state):
                state.tag = actual
                raise release.APIError(422, "Reference already exists")
            github.after_tag = create
            if actual == SHA:
                self.publish(github, release.fingerprint(draft()))
                self.assertFalse(github.release["draft"])
            else:
                with self.assertRaises(release.ReleaseError):
                    self.publish(github, release.fingerprint(draft()))
                self.assertTrue(github.release["draft"])

    def test_gh_transport_preserves_json_and_distinguishes_http_failure(self):
        github = release.GitHub("example/project")
        with patch("release.subprocess.run") as run:
            run.return_value = subprocess.CompletedProcess([], 0, 'HTTP/2.0 201 Created\nX: value\n\n{"id":42}', "")
            self.assertEqual(github.api("releases", "POST", {"body": "first\nsecond"}), {"id": 42})
            self.assertEqual(json.loads(run.call_args.kwargs["input"]), {"body": "first\nsecond"})
            run.return_value = subprocess.CompletedProcess([], 1, 'HTTP/2.0 404 Not Found\n\n{"message":"Not Found"}', "")
            with self.assertRaises(release.APIError) as caught:
                github.api("releases/42")
            self.assertEqual(caught.exception.status, 404)
            run.return_value = subprocess.CompletedProcess([], 0, "HTTP/2.0 204 No Content\nX: value\n\n", "")
            self.assertIsNone(github.api("actions/workflows/release.yml/dispatches", "POST", {}))
            run.return_value = subprocess.CompletedProcess([], 0, 'HTTP/2.0 200 OK\n\n{"default_branch":"main"}', "")
            self.assertEqual(github.api("")["default_branch"], "main")
            self.assertEqual(run.call_args.args[0][-1], "repos/example/project")


if __name__ == "__main__":
    unittest.main()
