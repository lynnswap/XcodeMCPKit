"""Run the verification shell entry point against an isolated Homebrew transport."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


BREW = r'''
import json, os, pathlib, sys
root = pathlib.Path(os.environ["BREW_FIXTURE"])
args = sys.argv[1:]
with (root/"calls").open("a") as output:
    output.write(json.dumps(dict(args=args, no_autoremove=os.environ.get("HOMEBREW_NO_AUTOREMOVE"))) + "\n")
installed = root/"installed"
if args[0] == "list":
    sys.exit(0 if installed.exists() else 1)
elif args[0] == "tap-new":
    (root/"tap/Formula").mkdir(parents=True)
elif args[0] == "--repository":
    print(root/"tap")
elif args[0] == "--cache":
    print(root/"cache"/args[1])
elif args[0] == "install":
    if os.environ.get("FAIL_INSTALL"):
        sys.exit(23)
    installed.touch()
elif args[0] == "uninstall":
    installed.unlink()
elif args[0] == "--prefix":
    print(root/"python" if args[1] == "python@3.14" else root/"prefix")
elif args[0] == "bottle" and "--merge" not in args:
    pathlib.Path("xcode-mcpkit--0.0.0-local.arm64_tahoe.bottle.tar.gz").write_bytes(b"bottle")
    pathlib.Path("xcode-mcpkit--0.0.0-local.arm64_tahoe.bottle.json").write_text("{}")
elif args[0] == "info":
    print(json.dumps(dict(formulae=[dict(installed=[dict(version="0.0.0-local", poured_from_bottle=True)])])))
elif args[0] not in ("trust", "untrust", "test", "untap", "bottle"):
    raise SystemExit("Unexpected brew command: " + repr(args))
'''


class HomebrewCleanupTests(unittest.TestCase):
    def run_verification(self, existing=False, fail=False):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        (root/"bin").mkdir()
        brew = root/"bin/brew"
        brew.write_text(f"#!{sys.executable}\n" + BREW)
        brew.chmod(0o755)
        python = root/"python/bin/python3.14"
        python.parent.mkdir(parents=True)
        python.write_text("#!/bin/sh\nexit 0\n")
        python.chmod(0o755)
        assets = root/"release"
        assets.mkdir()
        (assets/"xcode-mcpkit.rb").write_text("fixture recipe")
        (assets/"xcode-mcpkit-0.0.0-local.tar.gz").write_bytes(b"source")
        if existing:
            (root/"installed").touch()
        env = dict(os.environ, PATH=str(root/"bin") + os.pathsep + os.environ["PATH"],
                   BREW_FIXTURE=str(root), HOMEBREW_NO_AUTOREMOVE="0", TMPDIR=str(root))
        if fail:
            env["FAIL_INSTALL"] = "1"
        result = subprocess.run(["bash", str(Path(__file__).resolve().parents[1]/"test-homebrew.sh"), str(assets)],
                                env=env, capture_output=True, text=True)
        return result, root, [json.loads(line) for line in (root/"calls").read_text().splitlines()]

    def test_success_disables_dependency_removal_for_every_brew_command(self):
        result, root, calls = self.run_verification()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((root/"installed").exists())
        self.assertTrue(all(call["no_autoremove"] == "1" for call in calls))
        removals = [call["args"] for call in calls if call["args"][0] == "uninstall"]
        self.assertEqual(removals, [["uninstall", "xcodemcpkit/verification/xcode-mcpkit"],
                                    ["uninstall", "--force", "xcodemcpkit/verification/xcode-mcpkit"]])

    def test_failed_build_untaps_without_removing_unrelated_packages(self):
        result, _, calls = self.run_verification(fail=True)
        self.assertEqual(result.returncode, 23)
        self.assertTrue(all(call["no_autoremove"] == "1" for call in calls))
        self.assertFalse(any(call["args"][0] == "uninstall" for call in calls))
        self.assertEqual(calls[-2]["args"], ["untrust", "--formula", "xcodemcpkit/verification/xcode-mcpkit"])
        self.assertEqual(calls[-1]["args"], ["untap", "xcodemcpkit/verification"])

    def test_existing_installation_is_left_untouched(self):
        result, root, calls = self.run_verification(existing=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((root/"installed").exists())
        self.assertEqual(len(calls), 1)


if __name__ == "__main__":
    unittest.main()
