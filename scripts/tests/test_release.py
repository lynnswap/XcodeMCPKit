import copy
from contextlib import ExitStack
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import release


class ReleaseTests(unittest.TestCase):
    repository = "lynnswap/XcodeMCPKit"
    version = "v0.17.0"
    sha = "a" * 40

    def setUp(self):
        self.directory_context = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory_context.cleanup)
        self.directory = Path(self.directory_context.name)
        self.assets = self.directory / "release"
        self.assets.mkdir()
        binaries = self.directory / "bin"
        binaries.mkdir()
        for name in ("xcode-mcp-proxy", "xcode-mcp-proxy-server"):
            (binaries / name).write_bytes(b"release binary fixture")
        with tarfile.open(self.assets / release.ASSET_NAMES[0], "w:gz") as archive:
            archive.add(binaries, arcname="bin")
        subprocess.run([
            str(Path(release.__file__).with_name("render-install-script.sh")),
            "--version", self.version, "--repo", self.repository,
            "--output", str(self.assets / "install.sh"),
        ], check=True, capture_output=True)
        self.checksums = {
            name: hashlib.sha256((self.assets / name).read_bytes()).hexdigest()
            for name in (release.ASSET_NAMES[0], "install.sh")
        }
        (self.assets / "SHA256SUMS.txt").write_text(
            "".join(f"{checksum}  {name}\n" for name, checksum in self.checksums.items())
        )
        self.checksums["SHA256SUMS.txt"] = hashlib.sha256((self.assets / "SHA256SUMS.txt").read_bytes()).hexdigest()
        self.draft = {
            "id": 17, "tag_name": self.version, "target_commitish": self.sha,
            "draft": True, "prerelease": False, "name": "Approved title",
            "body": "Approved notes\n\n日本語 and literal `$(command)`\n", "assets": [],
            "html_url": f"https://github.com/{self.repository}/releases/tag/{self.version}",
        }
        self.tag = None
        self.api_calls = []
        self.uploads = []
        self.after_upload = lambda: None
        self.before_tag_create = lambda: None
        self.before_publish = lambda: None
        self.real_run = release.run
        env = {
            "GITHUB_ACTIONS": "true", "GITHUB_REF": "refs/heads/main", "RELEASE_BRANCH": "main",
            "GITHUB_SHA": self.sha, "GITHUB_REPOSITORY": self.repository,
        }
        context = ExitStack()
        self.addCleanup(context.close)
        context.enter_context(patch.dict(os.environ, env))
        self.api_mock = context.enter_context(patch.object(release, "api", side_effect=self.fake_api))
        context.enter_context(patch.object(release, "run", side_effect=self.fake_run))

    def fake_api(self, endpoint, *, fields=None, paginate=False, method=None):
        self.api_calls.append((endpoint, copy.deepcopy(fields)))
        prefix = f"repos/{self.repository}"
        if endpoint == f"{prefix}/releases?per_page=100":
            self.assertTrue(paginate)
            return [[], [copy.deepcopy(self.draft)]]
        if endpoint == f"{prefix}/git/matching-refs/tags/{self.version}":
            return [] if self.tag is None else [{"ref": f"refs/tags/{self.version}", "object": copy.deepcopy(self.tag)}]
        if endpoint == f"{prefix}/git/refs":
            self.assertEqual(method, "POST")
            self.before_tag_create()
            if self.tag is not None:
                raise release.ReleaseError("Reference already exists")
            self.tag = {"type": "commit", "sha": fields["sha"]}
            return {"ref": fields["ref"], "object": copy.deepcopy(self.tag)}
        if endpoint == f"{prefix}/releases/17":
            if fields is not None:
                self.assertNotIn("name", fields)
                self.assertNotIn("body", fields)
                if fields.get("draft") is False:
                    self.before_publish()
                self.draft.update(fields)
                if fields.get("draft") is False and self.tag is None:
                    self.tag = {"type": "commit", "sha": self.sha}
            return copy.deepcopy(self.draft)
        self.fail(f"Unexpected API call: {endpoint}")

    def fake_run(self, arguments, *, input=None):
        if arguments == ["git", "rev-parse", "HEAD"]:
            return self.sha + "\n"
        if arguments[:3] == ["gh", "release", "upload"]:
            self.uploads.append(arguments)
            # Model --clobber while leaving unrelated attachments visible.
            self.draft["assets"] = [a for a in self.draft["assets"] if a["name"] not in release.ASSET_NAMES]
            self.draft["assets"] += [
                {"name": name, "state": "uploaded", "digest": f"sha256:{checksum}"}
                for name, checksum in self.checksums.items()
            ]
            self.after_upload()
            return ""
        return self.real_run(arguments, input=input)

    def publish(self, prerelease=False):
        return release.publish(self.version, self.sha, 17, prerelease, self.assets,
                               self.checksums[release.ASSET_NAMES[0]])

    def assert_no_publication(self):
        self.assertTrue(self.draft["draft"])
        self.assertFalse(any(fields and fields.get("draft") is False for _, fields in self.api_calls))

    def test_prepare_pins_branch_and_preserves_notes(self):
        self.draft["target_commitish"] = "main"
        before = copy.deepcopy(self.draft)
        result = release.prepare(self.version, self.sha)
        self.assertEqual(result, {**before, "target_commitish": self.sha})
        self.assertIsNone(self.tag)

    def test_prepare_accepts_pinned_commit_and_matching_tag_without_writes(self):
        self.tag = {"type": "commit", "sha": self.sha}
        self.assertEqual(release.prepare(self.version, self.sha), self.draft)
        self.assertTrue(all(fields is None for _, fields in self.api_calls))

    def test_prepare_accepts_annotated_matching_tag(self):
        self.tag = {"type": "tag", "sha": "b" * 40}
        def api_with_tag(endpoint, **kwargs):
            if "/git/tags/" in endpoint:
                return {"object": {"type": "commit", "sha": self.sha}}
            return self.fake_api(endpoint, **kwargs)
        self.api_mock.side_effect = api_with_tag
        self.assertEqual(release.prepare(self.version, self.sha), self.draft)

    def test_prepare_rejects_missing_or_ambiguous_draft(self):
        for releases in ([], [self.draft, self.draft]):
            with self.subTest(releases=len(releases)):
                self.api_mock.side_effect = None
                self.api_mock.return_value = [releases]
                with self.assertRaises(release.ReleaseError):
                    release.prepare(self.version, self.sha)

    def test_prepare_rejects_unapproved_or_published_release(self):
        for changes in ({"body": "  "}, {"draft": False}, {"target_commitish": "b" * 40}):
            with self.subTest(changes=changes):
                original = copy.deepcopy(self.draft)
                self.draft.update(changes)
                with self.assertRaises(release.ReleaseError):
                    release.prepare(self.version, self.sha)
                self.assertTrue(all(fields is None for _, fields in self.api_calls))
                self.draft = original

    def test_prepare_rejects_mismatched_tag_before_pinning(self):
        self.draft["target_commitish"] = "main"
        self.tag = {"type": "commit", "sha": "b" * 40}
        with self.assertRaises(release.ReleaseError):
            release.prepare(self.version, self.sha)
        self.assertEqual(self.draft["target_commitish"], "main")

    def test_prepare_propagates_api_failure(self):
        self.api_mock.side_effect = release.ReleaseError("API unavailable")
        with self.assertRaisesRegex(release.ReleaseError, "API unavailable"):
            release.prepare(self.version, self.sha)

    def test_wrong_branch_or_checkout_is_rejected(self):
        for changes in ({"GITHUB_REF": "refs/heads/feature"}, {"GITHUB_SHA": "b" * 40}):
            with self.subTest(changes=changes), patch.dict(os.environ, changes):
                with self.assertRaises(release.ReleaseError):
                    release.prepare(self.version, self.sha)
        self.assertEqual(self.api_calls, [])

    def test_publish_preserves_notes_and_publishes_all_verified_assets(self):
        before = copy.deepcopy(self.draft)
        self.assertEqual(self.publish(), before["html_url"])
        self.assertEqual(self.draft["name"], before["name"])
        self.assertEqual(self.draft["body"], before["body"])
        self.assertFalse(self.draft["draft"])
        self.assertEqual(self.tag["sha"], self.sha)
        self.assertEqual(len(self.uploads), 1)

    def test_publish_preserves_prerelease_and_note_edits(self):
        self.draft["prerelease"] = True
        self.after_upload = lambda: self.draft.update(name="Edited title", body="Edited notes\n")
        self.publish(prerelease=True)
        self.assertTrue(self.draft["prerelease"])
        self.assertEqual(self.draft["name"], "Edited title")
        self.assertEqual(self.draft["body"], "Edited notes\n")

    def test_tag_is_pinned_before_publication(self):
        def check_tag():
            self.assertEqual(self.tag, {"type": "commit", "sha": self.sha})
            self.assertTrue(self.draft["draft"])
        self.before_publish = check_tag
        self.publish()
        self.assertIn((f"repos/{self.repository}/git/refs", {
            "ref": f"refs/tags/{self.version}", "sha": self.sha,
        }), self.api_calls)

    def test_existing_matching_tag_is_not_recreated(self):
        self.tag = {"type": "commit", "sha": self.sha}
        self.publish()
        self.assertFalse(any(endpoint.endswith("/git/refs") for endpoint, _ in self.api_calls))

    def test_tag_creation_conflict_stops_before_publication(self):
        for competing_sha in (self.sha, "b" * 40):
            with self.subTest(competing_sha=competing_sha):
                self.tag = None
                def create_competing_tag():
                    self.tag = {"type": "commit", "sha": competing_sha}
                self.before_tag_create = create_competing_tag
                with self.assertRaisesRegex(release.ReleaseError, "Reference already exists"):
                    self.publish()
                self.assertEqual(self.tag["sha"], competing_sha)
                self.assert_no_publication()

    def test_tag_creation_failure_leaves_draft(self):
        def fail():
            raise release.ReleaseError("Tag creation unavailable")
        self.before_tag_create = fail
        with self.assertRaisesRegex(release.ReleaseError, "Tag creation unavailable"):
            self.publish()
        self.assertIsNone(self.tag)
        self.assert_no_publication()

    def test_retry_after_publish_failure_reuses_created_tag(self):
        def fail():
            raise release.ReleaseError("Publication unavailable")
        self.before_publish = fail
        with self.assertRaisesRegex(release.ReleaseError, "Publication unavailable"):
            self.publish()
        self.assertTrue(self.draft["draft"])
        self.assertEqual(self.tag["sha"], self.sha)
        self.before_publish = lambda: None
        self.api_calls.clear()
        self.publish()
        self.assertFalse(self.draft["draft"])
        self.assertFalse(any(endpoint.endswith("/git/refs") for endpoint, _ in self.api_calls))

    def test_publish_repairs_partial_draft_uploads(self):
        self.draft["assets"] = [{"name": "install.sh", "state": "starter", "digest": None}]
        self.publish()
        self.assertEqual({a["name"] for a in self.draft["assets"]}, set(release.ASSET_NAMES))

    def test_invalid_local_assets_fail_before_upload(self):
        (self.assets / "install.sh").write_text("changed installer")
        with self.assertRaises(release.ReleaseError):
            self.publish()
        self.assertEqual(self.uploads, [])
        self.assert_no_publication()

    def test_build_digest_mismatch_fails_before_upload(self):
        with self.assertRaises(release.ReleaseError):
            release.publish(self.version, self.sha, 17, False, self.assets, "0" * 64)
        self.assertEqual(self.uploads, [])
        self.assert_no_publication()

    def test_missing_build_digest_cannot_skip_verification(self):
        with self.assertRaises(release.ReleaseError):
            release.publish(self.version, self.sha, 17, False, self.assets, "")
        self.assertEqual(self.uploads, [])
        self.assert_no_publication()

    def test_upload_failure_leaves_draft(self):
        def fail():
            raise release.ReleaseError("Upload interrupted")
        self.after_upload = fail
        with self.assertRaisesRegex(release.ReleaseError, "Upload interrupted"):
            self.publish()
        self.assert_no_publication()

    def test_bad_uploaded_digest_leaves_draft(self):
        self.after_upload = lambda: self.draft["assets"][0].update(digest="sha256:incorrect")
        with self.assertRaises(release.ReleaseError):
            self.publish()
        self.assert_no_publication()

    def test_unrelated_attachment_stops_publication_without_deleting_it(self):
        self.draft["assets"] = [{"name": "unrelated.txt"}]
        with self.assertRaises(release.ReleaseError):
            self.publish()
        self.assertIn({"name": "unrelated.txt"}, self.draft["assets"])
        self.assert_no_publication()

    def test_identity_changes_before_upload_are_rejected(self):
        for changes in ({"tag_name": "v1.0.0"}, {"target_commitish": "b" * 40}, {"prerelease": True}):
            with self.subTest(changes=changes):
                original = copy.deepcopy(self.draft)
                self.draft.update(changes)
                with self.assertRaises(release.ReleaseError):
                    self.publish()
                self.assertEqual(self.uploads, [])
                self.assert_no_publication()
                self.draft = original

    def test_target_changes_during_upload_stop_publication(self):
        self.after_upload = lambda: self.draft.update(target_commitish="b" * 40)
        with self.assertRaises(release.ReleaseError):
            self.publish()
        self.assert_no_publication()

    def test_tag_created_at_wrong_commit_during_upload_stops_publication(self):
        def replace_tag():
            self.tag = {"type": "commit", "sha": "b" * 40}
        self.after_upload = replace_tag
        with self.assertRaises(release.ReleaseError):
            self.publish()
        self.assert_no_publication()

    def test_retry_after_publication_confirms_without_mutation(self):
        self.publish()
        before = copy.deepcopy(self.draft)
        self.api_calls.clear()
        self.uploads.clear()
        self.assertEqual(self.publish(), before["html_url"])
        self.assertEqual(self.draft, before)
        self.assertEqual(self.uploads, [])
        self.assertTrue(all(fields is None for _, fields in self.api_calls))

    def test_retry_does_not_overwrite_different_published_assets(self):
        self.publish()
        self.draft["assets"][0]["digest"] = "sha256:unexpected"
        self.uploads.clear()
        with self.assertRaises(release.ReleaseError):
            self.publish()
        self.assertEqual(self.uploads, [])


if __name__ == "__main__":
    unittest.main()
