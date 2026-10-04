#!/usr/bin/env python3
"""Package approved source and a Homebrew formula; verify transferred release assets."""

import argparse
import gzip
import hashlib
import io
from pathlib import Path
import re
import subprocess
import sys
import tarfile


def is_prerelease(tag):
    if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?", tag):
        raise ValueError("Release tag must look like v1.2.3 or v1.2.3-beta.1.")
    return "-" in tag


def asset_names(tag):
    is_prerelease(tag)
    return (f"xcode-mcpkit-{tag.removeprefix('v')}.tar.gz", "xcode-mcpkit.rb", "SHA256SUMS.txt")


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def render_formula(tag, repository, source_digest, template=None):
    if template is None:
        template = (Path(__file__).resolve().parent.parent / "Homebrew/xcode-mcpkit.rb.in").read_text()
    version = tag.removeprefix("v")
    explicit_version = "" if re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version) else f'  version "{version}"\n'
    return (template.replace("__EXPLICIT_VERSION__\n", explicit_version)
            .replace("__VERSION__", version)
            .replace("__REPOSITORY__", repository).replace("__SHA256__", source_digest))


def archive_contents(data):
    with tarfile.open(fileobj=io.BytesIO(data)) as archive:
        entries = archive.getmembers()
        if not entries:
            return []
        root = entries[0].name.rstrip("/")
        if root in ("", ".", "..") or "/" in root:
            raise ValueError("Source archive must have one root directory.")
        contents = []
        for entry in entries:
            if entry.name != root and not entry.name.startswith(root + "/"):
                raise ValueError("Source archive must have one root directory.")
            contents.append((entry.name[len(root):].lstrip("/"),
                             entry.mode & 0o111 if entry.isfile() else 0,
                             entry.type, entry.linkname,
                             archive.extractfile(entry).read() if entry.isfile() else b""))
        return sorted(contents)


def package(source, commit, tag, repository, output, source_archive=None):
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("Use the full lowercase 40-character source commit SHA.")
    if not re.fullmatch(r"[\w.-]+/[\w.-]+", repository):
        raise ValueError("Use an owner/repository name.")
    output.mkdir(parents=True, exist_ok=True)
    archive_name, formula_name, checksums_name = asset_names(tag)
    prefix = f"xcode-mcpkit-{tag.removeprefix('v')}/"
    source_tar = subprocess.check_output([
        "git", "-C", str(source), "archive", "--format=tar", f"--prefix={prefix}", commit,
    ])
    archive = output / archive_name
    if source_archive is None:
        data = gzip.compress(source_tar, mtime=0)
    else:
        data = source_archive.read_bytes()
        if archive_contents(data) != archive_contents(source_tar):
            raise ValueError("Public source archive differs from the approved Git commit.")
    archive.write_bytes(data)
    template = subprocess.check_output([
        "git", "-C", str(source), "show", f"{commit}:Homebrew/xcode-mcpkit.rb.in",
    ], text=True)
    (output / formula_name).write_text(render_formula(tag, repository, sha256(archive), template))
    (output / checksums_name).write_text("".join(
        f"{sha256(output / name)}  {name}\n" for name in (archive_name, formula_name)
    ))


def verify(directory, tag, checksums_digest=None):
    archive, formula, checksums_name = asset_names(tag)
    checksums = directory / checksums_name
    if checksums_digest is not None and sha256(checksums) != checksums_digest:
        raise ValueError("Transferred checksums differ from the verified release job.")
    expected = {}
    for line in checksums.read_text().splitlines():
        digest, name = line.split("  ", 1)
        if name in expected or not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise ValueError("Invalid release checksums.")
        expected[name] = digest
    if set(expected) != {archive, formula}:
        raise ValueError("Checksums must cover the source archive and Formula.")
    for name, digest in expected.items():
        if sha256(directory / name) != digest:
            raise ValueError(f"Release checksum mismatch: {name}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    create = commands.add_parser("create")
    create.add_argument("--source-root", type=Path, required=True)
    create.add_argument("--commit", required=True)
    create.add_argument("--repo", required=True)
    create.add_argument("--output-dir", type=Path, required=True)
    create.add_argument("--source-archive", type=Path,
                        help="Use the public tag archive after verifying its approved Git contents")
    check = commands.add_parser("verify")
    check.add_argument("--release-dir", type=Path, required=True)
    check.add_argument("--checksums-sha256")
    for command in (create, check):
        command.add_argument("--version", required=True)
    args = parser.parse_args()
    try:
        is_prerelease(args.version)
        if args.command == "create":
            package(args.source_root, args.commit, args.version, args.repo, args.output_dir,
                    args.source_archive)
        else:
            verify(args.release_dir, args.version, args.checksums_sha256)
    except (OSError, ValueError, tarfile.TarError, subprocess.CalledProcessError) as error:
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
