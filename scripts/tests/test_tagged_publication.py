"""Check retry behavior at each GitHub release publication boundary."""
import hashlib
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import release


class TaggedPublicationTests(unittest.TestCase):
    def setUp(self):
        directory = self.enterContext(tempfile.TemporaryDirectory())
        self.paths = [Path(directory) / name for name in ("package.zip", "SHA256SUMS.txt")]
        for path in self.paths:
            path.write_text(path.name)
        self.tag = "v1.2.3"
        self.sha = "a" * 40
        self.release = dict(id=42, tag_name=self.tag, target_commitish=self.sha,
                            prerelease=False, draft=True, assets=[], html_url="release-url",
                            body=f"<!-- XcodeMCPKit release run 123 at {self.sha} -->\n\nGenerated notes")
        self.github = Mock()
        self.matches = self.enterContext(patch.object(release, "matching_releases", return_value=[self.release]))
        self.enterContext(patch.object(release, "check_tag", return_value=self.sha))

    def asset(self, path, state="uploaded"):
        return dict(name=path.name, state=state,
                    digest="sha256:" + hashlib.sha256(path.read_bytes()).hexdigest())

    def publish(self):
        release.publish_tagged(self.github, self.tag, self.sha, "123", self.paths)

    def test_creates_draft_then_publishes_verified_assets(self):
        self.matches.return_value = []
        uploaded = dict(self.release, assets=[self.asset(path) for path in self.paths])
        self.github.api.side_effect = [self.release, uploaded, dict(uploaded, draft=False)]
        self.publish()
        self.assertEqual(self.github.api.call_args_list[0].args[0:2], ("releases", "POST"))
        self.assertTrue(self.github.api.call_args_list[0].args[2]["draft"])
        self.github.upload.assert_called_once_with(self.tag, self.paths)
        self.github.api.assert_called_with("releases/42", "PATCH", {"draft": False})

    def test_retries_incomplete_upload_on_existing_draft(self):
        uploaded = [self.asset(path) for path in self.paths]
        self.release["assets"] = [uploaded[0], self.asset(self.paths[1], "starter")]
        complete = dict(self.release, assets=uploaded)
        self.github.api.side_effect = [complete, dict(complete, draft=False)]
        self.publish()
        self.github.upload.assert_called_once_with(self.tag, self.paths[1:])
        self.github.api.assert_called_with("releases/42", "PATCH", {"draft": False})

    def test_already_published_release_is_verified_without_writes(self):
        self.release.update(draft=False, assets=[self.asset(path) for path in self.paths])
        self.publish()
        self.github.upload.assert_not_called()
        self.github.api.assert_not_called()

    def test_rejects_unrelated_draft(self):
        self.release["body"] = "Release notes from a different run."
        with self.assertRaisesRegex(release.ReleaseError, "different publication"):
            self.publish()
        self.github.upload.assert_not_called()
        self.github.api.assert_not_called()

    def test_rejects_asset_with_wrong_digest(self):
        self.release["assets"] = [dict(self.asset(self.paths[0]), digest="sha256:wrong")]
        with self.assertRaisesRegex(release.ReleaseError, "does not match"):
            self.publish()
        self.github.upload.assert_not_called()
        self.github.api.assert_not_called()
