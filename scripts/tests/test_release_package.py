"""Package a pinned source revision and detect damaged release transfers."""
import gzip
import hashlib
import io
import json
from unittest.mock import patch
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import package_release as packaging


class ReleasePackageTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.source = self.root / "source"
        self.source.mkdir()
        self.git("init", "--quiet")
        self.git("config", "user.email", "tests@example.invalid")
        self.git("config", "user.name", "tests")
        (self.source / "Package.swift").write_text("approved source")
        (self.source / "Package.resolved").write_text("locked dependencies")
        mirrors = self.source / ".swiftpm/configuration/mirrors.json"
        mirrors.parent.mkdir(parents=True)
        mirrors.write_text("locked mirrors")
        (self.source / "build.sh").write_text("#!/bin/sh\nexit 0\n")
        (self.source / "build.sh").chmod(0o755)
        (self.source / "source-link").symlink_to("Package.swift")
        template = self.source / "Homebrew/xcode-mcpkit.rb.in"
        template.parent.mkdir()
        template.write_text((Path(packaging.__file__).parent.parent / "Homebrew/xcode-mcpkit.rb.in").read_text())
        self.engine = b'printf "shared installer: %s\\n" "$@"\n'
        self.pin = {"revision": "a" * 40, "sha256": hashlib.sha256(self.engine).hexdigest()}
        pin = self.source / "Homebrew/installer.json"
        pin.parent.mkdir(exist_ok=True)
        pin.write_text(json.dumps(self.pin))
        download = patch.object(packaging.urllib.request, "urlopen", side_effect=lambda *a, **kw: io.BytesIO(self.engine))
        self.download = download.start()
        self.addCleanup(download.stop)
        self.git("add", ".")
        self.git("-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "fixture")
        self.commit = self.git("rev-parse", "HEAD").strip()
        self.output = self.root / "release"

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.source), *args], text=True)

    def package(self):
        packaging.package(self.source, self.commit, "v1.2.3", "lynnswap/XcodeMCPKit", self.output)

    def test_packages_approved_commit_instead_of_current_files(self):
        (self.source / "Package.swift").write_text("unapproved edit")
        self.package()
        packaging.verify(self.output, "v1.2.3")
        archive = self.output / packaging.asset_names("v1.2.3")[0]
        with tarfile.open(fileobj=io.BytesIO(gzip.decompress(archive.read_bytes()))) as source:
            self.assertEqual(source.extractfile("xcode-mcpkit-1.2.3/Package.swift").read(), b"approved source")
            self.assertIn("xcode-mcpkit-1.2.3/Package.resolved", source.getnames())
            self.assertFalse(any("/.git/" in name for name in source.getnames()))
        formula = (self.output / "xcode-mcpkit.rb").read_text()
        self.assertIn("/archive/refs/tags/v1.2.3.tar.gz", formula)
        self.assertIn(packaging.sha256(archive), formula)
        first = archive.read_bytes()
        self.package()
        self.assertEqual(archive.read_bytes(), first)

    def public_archive(self):
        archive = self.root / "public-tag.tar.gz"
        data = subprocess.check_output([
            "git", "-C", str(self.source), "archive", "--format=tar",
            "--prefix=XcodeMCPKit-1.2.3/", self.commit])
        archive.write_bytes(gzip.compress(data, mtime=1))
        return archive

    def test_public_archive_bytes_are_preserved_after_verifying_the_approved_tree(self):
        source = self.public_archive()
        packaging.package(self.source, self.commit, "v1.2.3", "lynnswap/XcodeMCPKit",
                          self.output, source)
        archive = self.output / packaging.asset_names("v1.2.3")[0]
        self.assertEqual(archive.read_bytes(), source.read_bytes())
        self.assertIn(packaging.sha256(source), (self.output / "xcode-mcpkit.rb").read_text())
        packaging.verify(self.output, "v1.2.3")

    def test_public_archive_with_changed_files_modes_or_symlinks_is_rejected(self):
        for name, action in (("Package.resolved", "contents"), ("build.sh", "mode"),
                             ("source-link", "link"), (".swiftpm/configuration/mirrors.json", "remove")):
            with self.subTest(name=name, action=action):
                source = self.public_archive()
                changed = io.BytesIO()
                with tarfile.open(source) as original, tarfile.open(fileobj=changed, mode="w") as output:
                    for entry in original:
                        data = original.extractfile(entry).read() if entry.isfile() else b""
                        if entry.name.endswith("/" + name):
                            if action == "remove":
                                continue
                            if action == "contents":
                                data = b"unapproved dependencies"
                                entry.size = len(data)
                            elif action == "mode":
                                entry.mode = 0o644
                            else:
                                entry.linkname = "unapproved.swift"
                        output.addfile(entry, io.BytesIO(data) if entry.isfile() else None)
                source.write_bytes(gzip.compress(changed.getvalue()))
                with self.assertRaisesRegex(ValueError, "differs from the approved"):
                    packaging.package(self.source, self.commit, "v1.2.3", "lynnswap/XcodeMCPKit",
                                      self.output, source)
                self.assertFalse((self.output / "xcode-mcpkit.rb").exists())

    def test_source_archive_cannot_use_an_extraction_parent_as_its_root(self):
        data = subprocess.check_output([
            "git", "-C", str(self.source), "archive", "--format=tar", "--prefix=../", self.commit])
        with self.assertRaisesRegex(ValueError, "one root directory"):
            packaging.archive_contents(data)

    def test_checksums_protect_both_source_and_formula(self):
        for name in packaging.asset_names("v1.2.3")[:-1]:
            with self.subTest(name=name):
                self.package()
                (self.output / name).write_bytes(b"damaged transfer")
                with self.assertRaisesRegex(ValueError, "checksum mismatch"):
                    packaging.verify(self.output, "v1.2.3")

    def test_publication_checksums_are_bound_to_verified_job(self):
        self.package()
        trusted = packaging.sha256(self.output / "SHA256SUMS.txt")
        packaging.verify(self.output, "v1.2.3", trusted)
        formula = self.output / "xcode-mcpkit.rb"
        formula.write_text("substituted formula")
        checksums = self.output / "SHA256SUMS.txt"
        lines = checksums.read_text().splitlines()
        lines[1] = f"{packaging.sha256(formula)}  xcode-mcpkit.rb"
        checksums.write_text("\n".join(lines) + "\n")
        with self.assertRaisesRegex(ValueError, "Transferred checksums"):
            packaging.verify(self.output, "v1.2.3", trusted)

    def test_prerelease_keeps_its_full_homebrew_version(self):
        formula = packaging.render_formula("v1.2.3-rc.1", "lynnswap/XcodeMCPKit", "a" * 64)
        self.assertIn('  version "1.2.3-rc.1"', formula)
        self.assertNotIn("__EXPLICIT_VERSION__", formula)
        stable = packaging.render_formula("v1.2.3", "lynnswap/XcodeMCPKit", "a" * 64)
        self.assertNotIn('  version "1.2.3"', stable)

    def test_installer_uses_the_approved_pin_and_runs_from_a_pipe(self):
        (self.source / "Homebrew/installer.json").write_text(json.dumps({"revision": "b" * 40}))
        self.package()
        self.assertIn("/" + "a" * 40 + "/", self.download.call_args.args[0])
        script = self.output / "install.sh"
        result = subprocess.run(["/bin/sh", "-s", "--", "--dry-run", "path with ' quotes"],
                                input=script.read_text(), text=True, capture_output=True, check=True)
        self.assertIn("xcode-mcpkit", result.stdout)
        self.assertIn("path with ' quotes", result.stdout)
        self.assertTrue(script.stat().st_mode & 0o111)

    def test_installer_download_must_match_approved_checksum(self):
        self.download.side_effect = lambda *a, **kw: io.BytesIO(b"substituted script")
        with self.assertRaisesRegex(ValueError, "installer checksum mismatch"):
            self.package()
        self.assertFalse((self.output / "SHA256SUMS.txt").exists())

    def test_version_classification(self):
        for tag, value in (("v1.2.3", False), ("v1.2.3-rc.1", True)):
            self.assertEqual(packaging.is_prerelease(tag), value)
        with self.assertRaises(ValueError):
            packaging.is_prerelease("v1.2")


if __name__ == "__main__":
    unittest.main()
