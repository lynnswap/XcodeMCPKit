"""Verify public tap delivery without executing Formula code or publishing."""
import base64
import contextlib
import copy
import hashlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import package_release
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import release


class FakeTap:
    repository = release.HOMEBREW_TAP

    def __init__(self, formula):
        self.sha = "c" * 40
        self.formula = formula
        self.calls = []
        root = f"https://github.com/{self.repository}/releases/download/xcode-mcpkit-1.2.3"
        name = "xcode-mcpkit-1.2.3.arm64_tahoe.bottle.tar.gz"
        self.published = dict(draft=False, assets=[dict(
            name=name, state="uploaded", digest="sha256:" + "b" * 64,
            browser_download_url=root + "/" + name)])

    def api(self, path, method="GET", data=None):
        self.calls.append((path, method))
        if method != "GET":
            raise AssertionError("Tap readiness must not write")
        if path == "commits/main":
            return dict(sha=self.sha)
        if path == f"contents/Formula/xcode-mcpkit.rb?ref={self.sha}":
            return dict(content=base64.b64encode(self.formula.encode()).decode())
        if path.startswith("releases/tags/xcode-mcpkit-1.2.3"):
            return copy.deepcopy(self.published)
        raise AssertionError(path)


class HomebrewReadinessTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / "xcode-mcpkit-1.2.3.tar.gz").write_bytes(b"prepared source")
        self.digest = hashlib.sha256(b"prepared source").hexdigest()
        self.expected = package_release.render_formula("v1.2.3", "example/project", self.digest)
        (self.root / "xcode-mcpkit.rb").write_text(self.expected)
        bottle = ('\n\n  bottle do\n'
                  '    root_url "https://github.com/lynnswap/homebrew-tap/releases/download/xcode-mcpkit-1.2.3"\n'
                  f'    sha256 cellar: :any_skip_relocation, arm64_tahoe: "{"b" * 64}"\n'
                  '  end')
        self.formula = self.expected.replace('  license "MIT"', '  license "MIT"' + bottle)
        self.tap = FakeTap(self.formula)

    def ready(self):
        return release.verify_homebrew_ready(self.tap, "v1.2.3", self.root)

    def test_matching_public_source_and_bottle_have_read_only_pinned_evidence(self):
        evidence = self.ready()
        self.assertEqual(evidence["tap_sha"], self.tap.sha)
        self.assertEqual(evidence["formula_sha256"], hashlib.sha256(self.formula.encode()).hexdigest())
        self.assertEqual(evidence["source_sha256"], self.digest)
        self.assertEqual(evidence["bottle_sha256"], "b" * 64)
        self.assertEqual(self.tap.calls, [
            ("commits/main", "GET"),
            (f"contents/Formula/xcode-mcpkit.rb?ref={self.tap.sha}", "GET"),
            ("releases/tags/xcode-mcpkit-1.2.3", "GET")])

    def test_missing_or_mismatched_source_version_bottle_or_asset_cannot_be_ready(self):
        mutations = [
            lambda t: setattr(t, "formula", t.formula.replace(self.digest, "a" * 64)),
            lambda t: setattr(t, "formula", t.formula.replace("example/project", "other/project")),
            lambda t: setattr(t, "formula", t.formula.replace('  license', '  version "9.9.9"\n  license')),
            lambda t: setattr(t, "formula", self.expected),
            lambda t: setattr(t, "formula", t.formula.replace("arm64_tahoe", "arm64_sequoia")),
            lambda t: setattr(t, "formula", t.formula.replace("lynnswap/homebrew-tap", "other/homebrew-tap")),
            lambda t: setattr(t, "formula", t.formula.replace("releases/download/xcode-mcpkit-1.2.3", "releases/download/xcode-mcpkit-9.9.9")),
            lambda t: t.published.update(draft=True),
            lambda t: t.published.update(assets=[]),
            lambda t: t.published["assets"][0].update(state="new"),
            lambda t: t.published["assets"][0].update(digest="sha256:" + "a" * 64),
            lambda t: t.published["assets"][0].update(browser_download_url="https://example.invalid/bottle.tar.gz"),
            lambda t: t.published["assets"].append(copy.deepcopy(t.published["assets"][0])),
        ]
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                self.tap = FakeTap(self.formula)
                mutation(self.tap)
                with self.assertRaises(release.ReleaseError):
                    self.ready()
                self.assertTrue(all(method == "GET" for _, method in self.tap.calls))

    def test_unrelated_recipe_comments_and_release_metadata_do_not_block_publication(self):
        self.tap.formula += "\n# Maintainer documentation\n"
        self.tap.published.update(body="Changed notes", download_count=20)
        self.tap.sha = "d" * 40
        self.assertEqual(self.ready()["tap_sha"], self.tap.sha)

    def test_formula_code_identity_changes_independently_of_bottle_identity(self):
        original = self.ready()
        self.tap.formula += "\n  def post_install\n    system \"changed installation\"\n  end\n"
        changed = self.ready()
        self.assertNotEqual(changed["formula_sha256"], original["formula_sha256"])
        self.assertEqual(changed["bottle_sha256"], original["bottle_sha256"])
        self.assertEqual(changed["bottle_url"], original["bottle_url"])

    def test_unrelated_tap_commit_does_not_change_tested_artifact_identity(self):
        original = self.ready()
        self.tap.sha = "e" * 40
        changed = self.ready()
        for key in ("formula_sha256", "bottle_sha256", "bottle_url"):
            self.assertEqual(changed[key], original[key])

    def test_literal_comments_quotes_and_checksum_case_preserve_metadata_meaning(self):
        self.tap.formula = self.tap.formula.replace(self.digest, self.digest.upper())
        self.tap.formula = self.tap.formula.replace('"' + "b" * 64 + '"', "'" + "B" * 64 + "' # rebuilt")
        self.tap.formula = self.tap.formula.replace('  license', '  version "1.2.3" # explicit\n  license')
        self.assertEqual(self.ready()["bottle_sha256"], "b" * 64)

    def test_bottle_revision_and_rebuild_follow_the_consumers_filename(self):
        self.tap.formula = self.tap.formula.replace('  license', '  revision 2\n  license')
        self.tap.formula = self.tap.formula.replace('  bottle do', '  bottle do\n    rebuild 1')
        self.tap.formula = self.tap.formula.replace('releases/download/xcode-mcpkit-1.2.3"',
                                                   'releases/download/xcode-mcpkit-1.2.3_2"')
        name = "xcode-mcpkit-1.2.3_2.arm64_tahoe.bottle.1.tar.gz"
        self.tap.published["assets"][0].update(
            name=name, browser_download_url=f"https://github.com/{self.tap.repository}/releases/download/xcode-mcpkit-1.2.3_2/{name}")
        self.assertTrue(self.ready()["bottle_url"].endswith(name))
        self.tap.formula = self.tap.formula.replace("revision 2", "revision 3")
        with self.assertRaisesRegex(release.ReleaseError, "bottle URL"):
            self.ready()

    def test_ambiguous_or_dynamic_metadata_and_api_failures_preserve_the_failure(self):
        for extra in ('  revision SOME_VALUE\n', '  url "other"\n', '  version "1.2.3"\n  version "9.9.9"\n'):
            with self.subTest(extra=extra):
                self.tap.formula = self.formula + extra
                with self.assertRaisesRegex(release.ReleaseError, "Cannot verify"):
                    self.ready()
        with patch.object(self.tap, "api", side_effect=release.APIError(403, "Forbidden")):
            with self.assertRaisesRegex(release.ReleaseError, "Forbidden"):
                self.ready()

    def test_readiness_can_be_retried_after_public_tap_delivery_without_writes(self):
        self.tap.published["assets"] = []
        with self.assertRaises(release.ReleaseError):
            self.ready()
        self.tap.published = FakeTap(self.formula).published
        self.ready()
        self.assertTrue(all(method == "GET" for _, method in self.tap.calls))

    def test_prerelease_cli_does_not_require_or_access_the_stable_tap(self):
        output = self.root / "outputs"
        args = ["release", "homebrew-ready", "--version", "v1.2.3-rc.1",
                "--release-dir", str(self.root), "--github-output", str(output)]
        with patch("sys.argv", args), patch.object(release, "GitHub") as client, contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(release.main(), 0)
        client.assert_not_called()
        self.assertEqual(output.read_text(), "required=false\n")

    def test_status_reports_an_older_formula_as_waiting_without_failure(self):
        self.tap.formula = self.formula.replace("v1.2.3.tar.gz", "v1.2.2.tar.gz")
        output = self.root / "pending-outputs"
        args = ["release", "tap-status", "--version", "v1.2.3",
                "--release-dir", str(self.root), "--github-output", str(output)]
        messages = io.StringIO()
        with patch("sys.argv", args), patch.object(release, "GitHub", return_value=self.tap), contextlib.redirect_stdout(messages):
            self.assertEqual(release.main(), 0)
        self.assertEqual(output.read_text(), "required=true\nready=false\n")
        self.assertNotIn("re-run", json.loads(messages.getvalue())["pending"])
        with self.assertRaises(release.HomebrewPending):
            self.ready()

    def test_status_does_not_hide_a_corrupt_same_version_source_or_api_failure(self):
        args = ["release", "tap-status", "--version", "v1.2.3", "--release-dir", str(self.root)]
        self.tap.formula = self.formula.replace(self.digest, "a" * 64)
        with patch("sys.argv", args), patch.object(release, "GitHub", return_value=self.tap), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(release.main(), 1)
        self.tap.formula = self.formula
        with patch.object(self.tap, "api", side_effect=release.APIError(403, "Forbidden")):
            with self.assertRaisesRegex(release.ReleaseError, "Forbidden") as error:
                self.ready()
        self.assertNotIsInstance(error.exception, release.HomebrewPending)

    def test_missing_bottle_is_pending_but_changed_digest_is_a_failure(self):
        self.tap.published["assets"] = []
        with self.assertRaises(release.HomebrewPending):
            self.ready()
        self.tap.published = FakeTap(self.formula).published
        self.tap.published["assets"][0]["digest"] = "sha256:" + "a" * 64
        with self.assertRaises(release.ReleaseError) as error:
            self.ready()
        self.assertNotIsInstance(error.exception, release.HomebrewPending)


if __name__ == "__main__":
    unittest.main()
