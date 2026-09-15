#!/usr/bin/env python3
"""Inspect a Codex package tarball without extracting or executing its contents."""

from __future__ import annotations

import argparse
import json
import re
import stat
import sys
import tarfile
from pathlib import Path, PurePosixPath
from typing import Any, NoReturn

MAX_ARCHIVE_SIZE = 512 * 1024 * 1024
MAX_MEMBER_SIZE = 512 * 1024 * 1024
MAX_EXPANDED_SIZE = 1024 * 1024 * 1024
MAX_METADATA_SIZE = 64 * 1024
MAX_MEMBERS = 128
METADATA_KEYS = {
    "entrypoint",
    "layoutVersion",
    "pathDir",
    "resourcesDir",
    "target",
    "variant",
    "version",
}


class InspectionError(Exception):
    pass


def fail(message: str) -> NoReturn:
    raise InspectionError(message)


def unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            fail(f"codex-package.json contains duplicate key {key!r}")
        result[key] = value
    return result


def canonical_member(member: tarfile.TarInfo) -> str:
    name = member.name
    if not name or len(name.encode("utf-8")) > 256:
        fail("archive member name is empty or too long")
    if "\\" in name or name.startswith("/") or name.startswith("./"):
        fail(f"archive member has a noncanonical path: {name!r}")
    path = PurePosixPath(name)
    if any(part in {"", ".", ".."} for part in path.parts):
        fail(f"archive member has an unsafe path: {name!r}")
    canonical = path.as_posix()
    if name.rstrip("/") != canonical:
        fail(f"archive member has a noncanonical path: {name!r}")
    return f"{canonical}/" if member.isdir() else canonical


def load_expected(path: Path) -> set[str]:
    values = path.read_text(encoding="utf-8").splitlines()
    if not values or len(values) > MAX_MEMBERS or len(values) != len(set(values)):
        fail("expected member list must be nonempty and unique")
    return set(values)


def inspect(args: argparse.Namespace) -> dict[str, Any]:
    info = args.archive.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        fail("archive must be one regular, unlinked file")
    if not 0 < info.st_size <= MAX_ARCHIVE_SIZE:
        fail("archive size is outside the allowed range")

    expected = load_expected(args.members_file)
    seen: set[str] = set()
    expanded_size = 0
    metadata_bytes: bytes | None = None
    member_count = 0
    with tarfile.open(args.archive, mode="r:gz") as archive:
        for member in archive:
            member_count += 1
            if member_count > MAX_MEMBERS:
                fail("archive member count exceeds the limit")
            name = canonical_member(member)
            if name in seen:
                fail(f"archive contains duplicate member {name!r}")
            seen.add(name)
            if member.isdir():
                if member.size != 0:
                    fail(f"directory member has data: {name!r}")
                continue
            if not member.isfile() or member.issparse():
                fail(f"archive member is not a regular file or directory: {name!r}")
            if not 0 <= member.size <= MAX_MEMBER_SIZE:
                fail(f"archive member is too large: {name!r}")
            expanded_size += member.size
            if expanded_size > MAX_EXPANDED_SIZE:
                fail("archive expanded size exceeds the limit")
            if name == "codex-package.json":
                if member.size > MAX_METADATA_SIZE:
                    fail("codex-package.json is too large")
                stream = archive.extractfile(member)
                if stream is None:
                    fail("codex-package.json cannot be read")
                metadata_bytes = stream.read(MAX_METADATA_SIZE + 1)

    if member_count == 0:
        fail("archive is empty")
    if seen != expected:
        missing = sorted(expected - seen)
        extra = sorted(seen - expected)
        fail(f"archive member set changed (missing={missing!r}, extra={extra!r})")
    if metadata_bytes is None:
        fail("codex-package.json is missing")
    try:
        metadata = json.loads(metadata_bytes, object_pairs_hook=unique_object)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"codex-package.json is invalid JSON: {error}")
    if not isinstance(metadata, dict) or set(metadata) != METADATA_KEYS:
        fail("codex-package.json has an unexpected schema")
    expected_metadata = {
        "layoutVersion": 1,
        "version": args.version,
        "target": args.target,
        "variant": "codex",
        "entrypoint": "bin/codex",
        "resourcesDir": "codex-resources",
        "pathDir": "codex-path",
    }
    if metadata != expected_metadata:
        fail("codex-package.json does not match the requested version and target")
    return {
        "archive_size": info.st_size,
        "expanded_size": expanded_size,
        "members": member_count,
        "target": args.target,
        "version": args.version,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("--version", required=True)
    parser.add_argument("--target", required=True)
    parser.add_argument("--members-file", required=True, type=Path)
    args = parser.parse_args()
    try:
        if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", args.version):
            fail("version must be a stable semantic version")
        if args.target not in {
            "aarch64-unknown-linux-musl",
            "x86_64-unknown-linux-musl",
        }:
            fail("target is not an allowed Linux target")
        result = inspect(args)
    except (InspectionError, OSError, tarfile.TarError) as error:
        print(f"inspect-codex-package: {error}", file=sys.stderr)
        return 1
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
