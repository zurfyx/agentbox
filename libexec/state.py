#!/usr/bin/python3
"""Strict Agentbox manifest and managed activation-state helper."""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import re
import resource
import shutil
import stat
import subprocess
import sys
import tempfile
import platform as host_platform
import urllib.request
import unicodedata
import uuid
from pathlib import Path, PurePosixPath
from typing import Any, NoReturn
from urllib.parse import urlparse

STATE_SCHEMA = 1
MANIFEST_SCHEMA = 1
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
VERSION_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$")
IMAGE_RE = re.compile(r"^ghcr\.io/zurfyx/agentbox-runtime@sha256:[0-9a-f]{64}$")
DEV_IMAGE_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
PLATFORMS = ("linux/arm64", "linux/amd64")
MAX_ARTIFACT_SIZE = 512 * 1024 * 1024
EXPECTED_CODEX_MEMBERS = [
    "bin/", "bin/codex", "bin/codex-code-mode-host", "codex-package.json",
    "codex-path/", "codex-path/rg", "codex-resources/", "codex-resources/bwrap",
    "codex-resources/zsh/", "codex-resources/zsh/bin/", "codex-resources/zsh/bin/zsh",
]

class StateError(Exception):
    pass

def fail(message: str) -> NoReturn:
    raise StateError(message)

def exact_object(value: Any, keys: set[str], where: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        fail(f"{where} must be an object")
    actual = set(value)
    if actual != keys:
        missing, extra = sorted(keys - actual), sorted(actual - keys)
        details = []
        if missing:
            details.append("missing " + ", ".join(missing))
        if extra:
            details.append("unknown " + ", ".join(extra))
        fail(f"{where}: {'; '.join(details)}")
    return value

def string(value: Any, where: str) -> str:
    if not isinstance(value, str) or not value:
        fail(f"{where} must be a non-empty string")
    return value

def sha256(value: Any, where: str) -> str:
    value = string(value, where)
    if not SHA256_RE.fullmatch(value):
        fail(f"{where} must be a lowercase SHA-256")
    return value

def https_url(value: Any, host: str, prefix: str, where: str) -> str:
    value = string(value, where)
    parsed = urlparse(value)
    if (parsed.scheme != "https" or parsed.hostname != host or parsed.username is not None
            or parsed.password is not None or parsed.port is not None or parsed.query
            or parsed.fragment or not parsed.path.startswith(prefix)):
        fail(f"{where} is not an approved version-addressed HTTPS URL")
    return value

def canonical_bytes(value: Any) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()

def file_hash(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

def validate_platform(name: str, value: Any, tool: str) -> None:
    keys = {"platform", "url", "sha256", "size"}
    if tool == "codex": keys.add("target")
    item = exact_object(value, keys, f"tools.{tool}.platforms.{name}")
    if item["platform"] != name:
        fail(f"tools.{tool}.platforms.{name}.platform does not match its entry")
    if tool == "claude":
        platform_name = "linux-arm64" if name.endswith("arm64") else "linux-x64"
        https_url(item["url"], "downloads.claude.ai", "/claude-code-releases/", f"tools.{tool}.platforms.{name}.url")
        if not item["url"].endswith(f"/{platform_name}/claude"):
            fail(f"tools.{tool}.platforms.{name}.url has the wrong platform")
    else:
        target = "aarch64-unknown-linux-musl" if name.endswith("arm64") else "x86_64-unknown-linux-musl"
        https_url(item["url"], "releases.openai.com", "/codex/releases/", f"tools.{tool}.platforms.{name}.url")
        if item["target"] != target:
            fail(f"tools.{tool}.platforms.{name}.target is not the expected target")
        if not item["url"].endswith(f"/codex-package-{target}.tar.gz"):
            fail(f"tools.{tool}.platforms.{name}.url is not the canonical target package")
    sha256(item["sha256"], f"tools.{tool}.platforms.{name}.sha256")
    if not isinstance(item["size"], int) or isinstance(item["size"], bool) or not 0 < item["size"] <= MAX_ARTIFACT_SIZE:
        fail(f"tools.{tool}.platforms.{name}.size must be between 1 and 512 MiB")

def validate_manifest_data(value: Any, expected_version: str, development: bool = False) -> dict[str, Any]:
    manifest = exact_object(value, {"schema_version", "agentbox_version", "runtime_protocol_version", "runtime", "managed_files", "tools"}, "manifest")
    if manifest["schema_version"] != MANIFEST_SCHEMA:
        fail(f"unsupported manifest schema {manifest['schema_version']!r}")
    version = string(manifest["agentbox_version"], "agentbox_version")
    if version != expected_version:
        fail(f"agentbox_version does not match this launcher ({expected_version})")
    if manifest["runtime_protocol_version"] != 1:
        fail(f"unsupported runtime protocol {manifest['runtime_protocol_version']!r}")
    runtime = exact_object(manifest["runtime"], {"image"}, "runtime")
    image = string(runtime["image"], "runtime.image")
    if development:
        if not DEV_IMAGE_RE.fullmatch(image): fail("runtime.image is not a valid local development image reference")
    elif not IMAGE_RE.fullmatch(image):
        fail("runtime.image must be an immutable ghcr.io digest reference")
    tools = exact_object(manifest["tools"], {"claude", "codex"}, "tools")
    for tool in ("claude", "codex"):
        expected = {"version", "kind", "platforms"}
        if tool == "codex": expected |= {"layout_version", "entrypoint", "allowed_members"}
        spec = exact_object(tools[tool], expected, f"tools.{tool}")
        if spec["kind"] != ("raw-executable" if tool == "claude" else "tar.gz-package"):
            fail(f"tools.{tool}.kind is unsupported")
        if tool == "codex":
            if spec["layout_version"] != 1 or spec["entrypoint"] != "bin/codex":
                fail("tools.codex package layout is unsupported")
            members = spec["allowed_members"]
            if members != EXPECTED_CODEX_MEMBERS:
                fail("tools.codex.allowed_members does not match the reviewed 11-member package layout")
        tool_version = string(spec["version"], f"tools.{tool}.version")
        if not VERSION_RE.fullmatch(tool_version):
            fail(f"tools.{tool}.version is not a semantic version")
        if not isinstance(spec["platforms"], list) or len(spec["platforms"]) != 2:
            fail(f"tools.{tool}.platforms must contain exactly two entries")
        platforms = {entry.get("platform"): entry for entry in spec["platforms"] if isinstance(entry, dict)}
        if set(platforms) != set(PLATFORMS): fail(f"tools.{tool}.platforms must contain exactly {PLATFORMS}")
        for platform in PLATFORMS:
            validate_platform(platform, platforms[platform], tool)
            if tool == "claude":
                artifact = "linux-arm64" if platform == "linux/arm64" else "linux-x64"
                expected_url = f"https://downloads.claude.ai/claude-code-releases/{tool_version}/{artifact}/claude"
            else:
                expected_url = f"https://releases.openai.com/codex/releases/{tool_version}/codex-package-{platforms[platform]['target']}.tar.gz"
            if platforms[platform]["url"] != expected_url:
                fail(f"tools.{tool}.platforms.{platform}.url is not the canonical versioned artifact URL")
    managed = exact_object(manifest["managed_files"], {"runtime_instructions", "statusline"}, "managed_files")
    expected_paths = {"runtime_instructions": "/usr/local/share/agentbox/instructions.md", "statusline": "/usr/local/share/agentbox/statusline.sh"}
    for name, expected_path in expected_paths.items():
        record = exact_object(managed[name], {"path", "sha256"}, f"managed_files.{name}")
        if record["path"] != expected_path: fail(f"managed_files.{name}.path is not the runtime-owned path")
        sha256(record["sha256"], f"managed_files.{name}.sha256")
    return manifest

def load_manifest(path: Path, expected_version: str, development: bool = False) -> tuple[dict[str, Any], str]:
    parsed, raw = load_canonical_json(path, "release manifest")
    value = validate_manifest_data(parsed, expected_version, development)
    return value, hashlib.sha256(raw).hexdigest()

def validate_ref(value: Any, where: str, development: bool = False) -> dict[str, Any]:
    ref = exact_object(value, {"release_id", "agentbox_version", "manifest_sha256", "content_sha256", "validation_sha256", "runtime_image", "release_path"}, where)
    string(ref["release_id"], f"{where}.release_id")
    string(ref["agentbox_version"], f"{where}.agentbox_version")
    sha256(ref["manifest_sha256"], f"{where}.manifest_sha256")
    sha256(ref["content_sha256"], f"{where}.content_sha256")
    sha256(ref["validation_sha256"], f"{where}.validation_sha256")
    image_pattern = DEV_IMAGE_RE if development else IMAGE_RE
    if not image_pattern.fullmatch(string(ref["runtime_image"], f"{where}.runtime_image")):
        fail(f"{where}.runtime_image is invalid")
    path = Path(string(ref["release_path"], f"{where}.release_path"))
    if not path.is_absolute():
        fail(f"{where}.release_path is not absolute")
    return ref

def load_activation(root: Path, development: bool = False) -> dict[str, Any] | None:
    path = root / "activation.json"
    if not path.exists():
        return None
    record, raw = load_canonical_json(path, "activation record")
    record = exact_object(record, {"schema_version", "generation", "current", "previous", "selection", "checksum"}, "activation record")
    if record["schema_version"] != STATE_SCHEMA:
        fail(f"unsupported activation schema {record['schema_version']!r}")
    if not isinstance(record["generation"], int) or isinstance(record["generation"], bool) or record["generation"] < 1:
        fail("activation generation is invalid")
    validate_ref(record["current"], "activation.current", development)
    if record["previous"] is not None:
        validate_ref(record["previous"], "activation.previous", development)
    selection = exact_object(record["selection"], {"mode", "reason"}, "activation.selection")
    if selection == {"mode": "normal", "reason": None}: pass
    elif selection != {"mode": "manual_rollback_hold", "reason": "vendor_state_risk_accepted"}:
        fail("activation selection is invalid")
    checksum = string(record["checksum"], "activation.checksum")
    unsigned = dict(record); del unsigned["checksum"]
    expected = "sha256:" + hashlib.sha256(canonical_bytes(unsigned)).hexdigest()
    if checksum != expected or raw != canonical_bytes(record): fail("activation checksum or canonical encoding is invalid")
    return record

def verify_ref(root: Path, ref: dict[str, Any], development: bool = False) -> set[str]:
    release = Path(ref["release_path"])
    expected_release = root / "releases" / ref["release_id"]
    if release != expected_release or release.name != ref["release_id"] or ".." in release.parts:
        fail("activation release path is not the canonical release identity")
    ensure_directory_no_symlinks(root)
    ensure_directory_no_symlinks(release)
    manifest, digest = load_manifest(release / "manifest.json", ref["agentbox_version"], development)
    if digest != ref["manifest_sha256"]:
        fail("active release manifest hash does not match activation")
    if manifest["agentbox_version"] != ref["agentbox_version"]:
        fail("active release version does not match activation")
    if manifest["runtime"]["image"] != ref["runtime_image"]:
        fail("active runtime image does not match activation")
    content_hash, validation_hash, ready_agents = verify_release_content(release, digest, ref["runtime_image"])
    if content_hash != ref["content_sha256"] or validation_hash != ref["validation_sha256"]:
        fail("active release content or validation receipt does not match activation")
    return ready_agents

def ensure_directory_no_symlinks(path: Path) -> None:
    current = Path(path.anchor)
    for part in path.parts[1:]:
        current /= part
        try: info = current.lstat()
        except FileNotFoundError: fail(f"managed directory is missing: {current}")
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
            fail(f"managed directory is not a plain directory: {current}")

def load_canonical_json(path: Path, where: str) -> tuple[dict[str, Any], bytes]:
    def unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in pairs:
            if key in result: fail(f"{where} contains duplicate key {key!r}")
            result[key] = value
        return result
    try:
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            os.close(fd); fail(f"{where} must be a regular file")
        if info.st_size > 1024 * 1024:
            os.close(fd); fail(f"{where} is too large")
        with os.fdopen(fd, "rb") as handle: raw = handle.read(1024 * 1024 + 1)
        if len(raw) > 1024 * 1024: fail(f"{where} is too large")
        value = json.loads(raw.decode("utf-8"), object_pairs_hook=unique_object)
    except FileNotFoundError: fail(f"{where} does not exist")
    except OSError as exc: fail(f"cannot read {where}: {exc}")
    except (UnicodeDecodeError, json.JSONDecodeError) as exc: fail(f"{where} is not valid JSON: {exc}")
    canonical = canonical_bytes(value)
    if raw != canonical: fail(f"{where} is not canonical JSON")
    return value, raw

def verify_content_ledger(release: Path, manifest_digest: str) -> tuple[str, str, set[str]]:
    content_path = release / "vendor" / "content.json"
    try: content_info = content_path.lstat()
    except OSError as exc: fail(f"cannot inspect content ledger: {exc}")
    if not stat.S_ISREG(content_info.st_mode) or content_info.st_nlink != 1 or stat.S_IMODE(content_info.st_mode) != 0o444:
        fail("content ledger must be one read-only regular file")
    content, content_bytes = load_canonical_json(content_path, "content ledger")
    content = exact_object(content, {"entries", "manifest_sha256", "platform", "schema"}, "content ledger")
    if content["schema"] != 1 or content["manifest_sha256"] != f"sha256:{manifest_digest}" or content["platform"] not in PLATFORMS:
        fail("content ledger identity does not match the release")
    entries = content["entries"]
    if not isinstance(entries, list) or not entries: fail("content ledger entries must be a nonempty array")
    paths: list[str] = []
    folded: set[str] = set()
    for index, raw_entry in enumerate(entries):
        where = f"content ledger entry {index}"
        if not isinstance(raw_entry, dict): fail(f"{where} must be an object")
        entry_type = raw_entry.get("type")
        expected_keys = {"mode", "path", "type"} if entry_type == "directory" else {"mode", "path", "sha256", "size", "type"}
        entry = exact_object(raw_entry, expected_keys, where)
        path_text = string(entry["path"], f"{where}.path")
        pure = PurePosixPath(path_text)
        if (not path_text.startswith("vendor/") or pure.as_posix() != path_text or "\\" in path_text
                or any(part in {"", ".", ".."} for part in pure.parts)
                or unicodedata.normalize("NFC", path_text) != path_text):
            fail(f"{where}.path is not canonical")
        folded_path = path_text.casefold()
        if path_text in paths or folded_path in folded: fail("content ledger contains duplicate or case-fold-colliding paths")
        paths.append(path_text); folded.add(folded_path)
        if not isinstance(entry["mode"], int) or isinstance(entry["mode"], bool): fail(f"{where}.mode is invalid")
        actual = release.joinpath(*pure.parts)
        try: info = actual.lstat()
        except FileNotFoundError: fail(f"managed content is missing: {path_text}")
        if stat.S_IMODE(info.st_mode) != entry["mode"]: fail(f"managed content mode changed: {path_text}")
        if entry_type == "directory":
            if not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode): fail(f"managed directory changed type: {path_text}")
        elif entry_type == "file":
            if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1: fail(f"managed file changed type or link count: {path_text}")
            if not isinstance(entry["size"], int) or isinstance(entry["size"], bool) or entry["size"] != info.st_size:
                fail(f"managed file size changed: {path_text}")
            expected_hash = sha256(entry["sha256"].removeprefix("sha256:"), f"{where}.sha256")
            if file_hash(actual) != expected_hash: fail(f"managed file hash changed: {path_text}")
        else: fail(f"{where}.type is unsupported")
    if paths != sorted(paths, key=lambda value: value.encode()): fail("content ledger entries are not bytewise sorted")
    actual_paths: set[str] = set()
    for parent, directories, files in os.walk(release / "vendor", followlinks=False):
        for name in directories + files:
            item = Path(parent) / name
            relative = item.relative_to(release).as_posix()
            info = item.lstat()
            if stat.S_ISLNK(info.st_mode) or not (stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode)):
                fail(f"managed content contains a special file: {relative}")
            actual_paths.add(relative)
    if actual_paths != set(paths) | {"vendor/content.json"}: fail("managed content has missing or unexpected paths")
    agents: set[str] = set()
    for path_text in paths:
        parts = PurePosixPath(path_text).parts
        if len(parts) < 2 or parts[0] != "vendor" or parts[1] not in {"claude", "codex"}:
            fail(f"content ledger contains an unsupported vendor path: {path_text}")
        agents.add(parts[1])
    content_hash = hashlib.sha256(content_bytes).hexdigest()
    return content_hash, content["platform"], agents

def verify_release_content(release: Path, manifest_digest: str, runtime_image: str) -> tuple[str, str, set[str]]:
    content_hash, content_platform, content_agents = verify_content_ledger(release, manifest_digest)
    validation_path = release / "validation.json"
    try: validation_info = validation_path.lstat()
    except OSError as exc: fail(f"cannot inspect validation receipt: {exc}")
    if not stat.S_ISREG(validation_info.st_mode) or validation_info.st_nlink != 1 or stat.S_IMODE(validation_info.st_mode) != 0o444:
        fail("validation receipt must be one read-only regular file")
    validation, validation_bytes = load_canonical_json(validation_path, "validation receipt")
    validation = exact_object(validation, {"assertions", "content_sha256", "manifest_sha256", "platform", "runtime_image", "runtime_protocol", "schema"}, "validation receipt")
    assertions = exact_object(validation["assertions"], {"claude_behavior", "claude_version", "codex_behavior", "codex_layout", "codex_version", "instructions", "runtime_protocol", "status_line"}, "validation assertions")
    if (validation["schema"] != 1 or validation["runtime_protocol"] != 1 or validation["platform"] != content_platform
            or validation["manifest_sha256"] != f"sha256:{manifest_digest}"
            or validation["content_sha256"] != f"sha256:{content_hash}" or validation["runtime_image"] != runtime_image):
        fail("validation receipt does not match the validated release")
    if any(assertions[name] is not True for name in ("instructions", "runtime_protocol", "status_line")):
        fail("validation receipt does not pass shared runtime assertions")
    ready_agents: set[str] = set()
    if assertions["claude_behavior"] is True and assertions["claude_version"] is True:
        ready_agents.add("claude")
    elif assertions["claude_behavior"] is not False or assertions["claude_version"] is not False:
        fail("validation receipt has inconsistent Claude assertions")
    codex_assertions = (assertions["codex_behavior"], assertions["codex_layout"], assertions["codex_version"])
    if all(value is True for value in codex_assertions):
        ready_agents.add("codex")
    elif any(value is not False for value in codex_assertions):
        fail("validation receipt has inconsistent Codex assertions")
    if ready_agents != content_agents:
        fail("validation receipt readiness does not match managed content")
    return content_hash, hashlib.sha256(validation_bytes).hexdigest(), ready_agents

def agent_content_identity(release: Path, agent: str) -> list[dict[str, Any]]:
    content, _ = load_canonical_json(release / "vendor" / "content.json", "content ledger")
    prefix = f"vendor/{agent}"
    return [entry for entry in content["entries"]
            if entry["path"] == prefix or entry["path"].startswith(prefix + "/")]

def fsync_dir(path: Path) -> None:
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(fd)
    finally:
        os.close(fd)

def atomic_json(path: Path, value: Any) -> None:
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "wb") as handle:
            handle.write(canonical_bytes(value)); handle.flush(); os.fsync(handle.fileno())
        os.replace(temporary, path); fsync_dir(path.parent)
    finally:
        try: os.unlink(temporary)
        except FileNotFoundError: pass

def write_activation(path: Path, value: dict[str, Any]) -> None:
    unsigned = dict(value)
    unsigned.pop("checksum", None)
    value = dict(unsigned)
    value["checksum"] = "sha256:" + hashlib.sha256(canonical_bytes(unsigned)).hexdigest()
    atomic_json(path, value)

def clean_engine_env() -> dict[str, str]:
    return {"PATH": "/usr/bin:/bin", "HOME": "/var/empty", "LC_ALL": "C", "LANG": "C"}

def selected_platform(manifest: dict[str, Any]) -> tuple[str, dict[str, dict[str, Any]]]:
    machine = host_platform.machine().lower()
    name = "linux/arm64" if machine in {"arm64", "aarch64"} else "linux/amd64" if machine in {"x86_64", "amd64"} else ""
    if not name: fail(f"unsupported host architecture {machine}")
    selected = {}
    for tool in ("claude", "codex"):
        selected[tool] = next(item for item in manifest["tools"][tool]["platforms"] if item["platform"] == name)
    return name, selected

def tool_reuse_identity(manifest: dict[str, Any], agent: str, platform_record: dict[str, Any]) -> bytes:
    shared = {key: value for key, value in manifest["tools"][agent].items() if key != "platforms"}
    return canonical_bytes({"platform": platform_record, "tool": shared})

def download_artifact(spec: dict[str, Any], destination: Path, agentbox_version: str) -> None:
    if os.environ.get("AGENTBOX_TEST_MODE") == "1" and os.environ.get("AGENTBOX_TEST_DOWNLOAD_DIR"):
        source = Path(os.environ["AGENTBOX_TEST_DOWNLOAD_DIR"]) / destination.name
        if not source.is_file(): fail(f"test download fixture is missing: {source.name}")
        shutil.copyfile(source, destination)
        if destination.stat().st_size != spec["size"] or file_hash(destination) != spec["sha256"]:
            fail("test artifact size or SHA-256 does not match the release manifest")
        return
    request = urllib.request.Request(spec["url"], headers={"User-Agent": f"agentbox/{agentbox_version}"})
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    digest, total = hashlib.sha256(), 0
    try:
        with opener.open(request, timeout=60) as response, destination.open("xb") as output:
            if response.geturl() != spec["url"]: fail("artifact download redirected away from its pinned URL")
            while True:
                chunk = response.read(min(1024 * 1024, spec["size"] + 1 - total))
                if not chunk: break
                total += len(chunk)
                if total > spec["size"]: fail("artifact exceeds its declared size")
                digest.update(chunk); output.write(chunk)
            output.flush(); os.fsync(output.fileno())
    except OSError as exc: fail(f"artifact download failed: {exc}")
    if total != spec["size"] or digest.hexdigest() != spec["sha256"]:
        fail("artifact size or SHA-256 does not match the release manifest")

def run_checked(argv: list[str], *, capture: bool = False, timeout: int = 900, cleanup: tuple[Path, str] | None = None) -> bytes:
    def remove_candidate() -> None:
        if cleanup is None: return
        engine, name = cleanup
        try:
            subprocess.run([str(engine), "rm", "-f", name], env=clean_engine_env(), stdin=subprocess.DEVNULL,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30, check=False)
        except (OSError, subprocess.TimeoutExpired): pass

    def limit_output() -> None:
        resource.setrlimit(resource.RLIMIT_FSIZE, (64 * 1024, 64 * 1024))

    try:
        with tempfile.TemporaryFile() as stdout, tempfile.TemporaryFile() as stderr:
            result = subprocess.run(argv, env=clean_engine_env(), stdin=subprocess.DEVNULL,
                                    stdout=stdout if capture else None, stderr=stderr if capture else None,
                                    timeout=timeout, check=False, preexec_fn=limit_output if capture else None)
            if result.returncode != 0:
                remove_candidate()
                fail(f"runtime preparation command failed with status {result.returncode}")
            if not capture:
                return b""
            stdout.seek(0, os.SEEK_END)
            stdout_size = stdout.tell()
            stderr.seek(0, os.SEEK_END)
            if stdout_size > 64 * 1024 or stderr.tell() > 64 * 1024:
                remove_candidate()
                fail("runtime protocol output exceeded 64 KiB")
            stdout.seek(0)
            return stdout.read()
    except subprocess.TimeoutExpired:
        remove_candidate()
        fail(f"runtime preparation command timed out after {timeout} seconds")
    except subprocess.CalledProcessError as exc:
        fail(f"runtime preparation command failed with status {exc.returncode}")
    except OSError as exc:
        fail(f"could not execute runtime engine: {exc}")

def ensure_root(root: Path) -> None:
    qualify_root(root)
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(root, 0o700, follow_symlinks=False)
    for name in ("releases", "staging", "locks"):
        (root / name).mkdir(mode=0o700, exist_ok=True)
        os.chmod(root / name, 0o700, follow_symlinks=False)
    qualify_root(root)

def qualify_root(root: Path) -> None:
    if not root.is_absolute() or any(part in (".", "..") for part in root.parts):
        fail("managed root must be an absolute normalized path")
    current = Path(root.anchor)
    existing = current
    for part in root.parts[1:]:
        current /= part
        try: info = current.lstat()
        except FileNotFoundError: break
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
            fail(f"managed root ancestry is not a plain directory: {current}")
        existing = current
    for managed in (root.parent, root):
        try: info = managed.lstat()
        except FileNotFoundError: continue
        if not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode):
            fail(f"managed root path is not a plain directory: {managed}")
        if info.st_uid != os.getuid():
            fail(f"managed root path is not owned by the invoking user: {managed}")
        if stat.S_IMODE(info.st_mode) & 0o022:
            fail(f"managed root path is writable by another user: {managed}")
    if sys.platform == "darwin":
        try:
            mounts = subprocess.run(["/sbin/mount"], env={"PATH": "/usr/bin:/bin:/sbin", "LC_ALL": "C"},
                                    stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                    text=True, timeout=10, check=True).stdout.splitlines()
            device = existing.stat().st_dev
            candidates: list[tuple[int, str]] = []
            for line in mounts:
                match = re.match(r"^.+ on (.+) \(([^)]*)\)$", line)
                if match is None: continue
                mountpoint, options = match.groups()
                try: mount_device = Path(mountpoint).stat().st_dev
                except OSError: continue
                if mount_device == device: candidates.append((len(mountpoint), options))
            if not candidates: fail("managed root filesystem could not be identified")
            options = max(candidates)[1].split(", ")
            if options[0] != "apfs" or "local" not in options:
                fail("managed root must be on a local APFS filesystem")
        except (OSError, subprocess.SubprocessError) as exc:
            fail(f"managed root filesystem qualification failed: {exc}")

def activate(root: Path, manifest: dict[str, Any], digest: str, release: Path, content_hash: str, validation_hash: str,
             development: bool = False, reset_selector: bool = False) -> dict[str, Any]:
    old = None if reset_selector else load_activation(root, development)
    current = {"release_id": release.name, "agentbox_version": manifest["agentbox_version"], "manifest_sha256": digest,
               "content_sha256": content_hash, "validation_sha256": validation_hash,
               "runtime_image": manifest["runtime"]["image"], "release_path": str(release)}
    if old is not None and old["selection"]["mode"] == "manual_rollback_hold":
        fail("manual rollback hold is active; run `agentbox setup --reset-selector` to validate and select the installed release")
    if old is not None and old["current"] == current:
        verify_ref(root, old["current"], development); return old
    previous = None if old is None else (old["previous"] if old["current"]["manifest_sha256"] == digest else old["current"])
    record = {"schema_version": STATE_SCHEMA, "generation": 1 if old is None else old["generation"] + 1,
              "current": current, "previous": previous,
              "selection": {"mode": "normal", "reason": None}}
    write_activation(root / "activation.json", record)
    return record

def protocol_json(raw: bytes, expected: set[str], where: str) -> dict[str, Any]:
    if len(raw) > 64 * 1024: fail(f"{where} exceeded 64 KiB")
    def unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in pairs:
            if key in result: fail(f"{where} contains duplicate key {key!r}")
            result[key] = value
        return result
    try: value = json.loads(raw.decode("utf-8"), object_pairs_hook=unique_object)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc: fail(f"{where} was not valid JSON: {exc}")
    value = exact_object(value, expected, where)
    if raw != canonical_bytes(value): fail(f"{where} was not canonical JSON")
    return value

def candidate_limits(name: str) -> list[str]:
    return ["--name", name, "--user", f"{os.getuid()}:{os.getgid()}", "--memory", "512m", "--memory-swap", "512m", "--cpus", "1", "--pids-limit", "128"]

def candidate_tmpfs(path: str, size: str, *, executable: bool = False) -> str:
    options = ["rw", "nosuid", "nodev", f"size={size}", f"uid={os.getuid()}", f"gid={os.getgid()}", "mode=0700"]
    if not executable:
        options.append("noexec")
    return f"{path}:{','.join(options)}"

def validate_release(engine: Path, image: str, platform_name: str, release: Path, manifest: dict[str, Any], agent: str) -> dict[str, bool]:
    name = f"agentbox-validate-{uuid.uuid4().hex}"
    raw = run_checked([str(engine), "run", "--rm", *candidate_limits(name), "--network", "none", "--read-only", "--tmpfs", candidate_tmpfs("/tmp", "16m"),
                       "--tmpfs", candidate_tmpfs("/home/node", "64m", executable=True), "--tmpfs", candidate_tmpfs("/run", "4m"),
                       "--mount", f"type=bind,src={release},dst=/opt/agentbox-release,readonly", image, "validate", "--protocol", "1",
                       "--platform", platform_name, "--manifest", "/opt/agentbox-release/manifest.json", "--agent", agent,
                       "--candidate", "/opt/agentbox-release/vendor"],
                      capture=True, timeout=180, cleanup=(engine, name))
    result = protocol_json(raw, {"assertions", "claude_version", "codex_version", "ok", "protocol"}, "runtime validation result")
    assertions = exact_object(result["assertions"], {"claude_behavior", "claude_version", "codex_behavior", "codex_layout", "codex_version", "instructions", "runtime_protocol", "status_line"}, "runtime validation assertions")
    requested = {"claude", "codex"} if agent == "all" else {agent}
    required = {"instructions", "runtime_protocol", "status_line"}
    if "claude" in requested: required |= {"claude_behavior", "claude_version"}
    if "codex" in requested: required |= {"codex_behavior", "codex_layout", "codex_version"}
    if (result["ok"] is not True or result["protocol"] != 1 or any(assertions[name] is not True for name in required)
            or ("claude" in requested and result["claude_version"] != manifest["tools"]["claude"]["version"])
            or ("codex" in requested and result["codex_version"] != manifest["tools"]["codex"]["version"])):
        fail("runtime validation did not pass every required assertion")
    return assertions

def create_validation_receipt(release: Path, manifest: dict[str, Any], digest: str, image: str,
                              platform_name: str, prepare_result: dict[str, Any], assertions: dict[str, bool]) -> tuple[str, str]:
    content_hash, _, _ = verify_content_ledger(release, digest)
    if prepare_result["content_sha256"] != f"sha256:{content_hash}": fail("runtime prepare receipt does not match content.json")
    receipt = {"assertions": assertions, "content_sha256": f"sha256:{content_hash}", "manifest_sha256": f"sha256:{digest}",
               "platform": platform_name, "runtime_image": image, "runtime_protocol": 1, "schema": 1}
    path = release / "validation.json"
    with path.open("xb") as handle:
        os.fchmod(handle.fileno(), 0o444); handle.write(canonical_bytes(receipt)); handle.flush(); os.fsync(handle.fileno())
    return content_hash, file_hash(path)

def prepare(root: Path, manifest_path: Path, engine: Path, expected_version: str, development: bool = False,
            reset_selector: bool = False, agent: str = "all") -> None:
    manifest, digest = load_manifest(manifest_path, expected_version, development)
    ensure_root(root)
    lock_path = root / "locks" / "prepare.lock"
    lock_fd = os.open(lock_path, os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0), 0o600)
    with os.fdopen(lock_fd, "r+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        requested = {"claude", "codex"} if agent == "all" else {agent}
        reusable: set[str] = set()
        reuse_identities: dict[str, list[dict[str, Any]]] = {}
        reusable_release: Path | None = None
        old = load_activation(root, development)
        if old is not None and old["selection"]["mode"] == "manual_rollback_hold" and not reset_selector:
            fail("manual rollback hold is active; run `agentbox setup --reset-selector` to validate and select the installed release")
        if old is not None:
            try:
                old_ready = verify_ref(root, old["current"], development)
                old_manifest, _ = load_manifest(Path(old["current"]["release_path"]) / "manifest.json",
                                                old["current"]["agentbox_version"], development)
                old_platform, old_artifacts = selected_platform(old_manifest)
                new_platform, new_artifacts = selected_platform(manifest)
                if old_platform == new_platform:
                    reusable = {name for name in old_ready
                                if tool_reuse_identity(old_manifest, name, old_artifacts[name])
                                == tool_reuse_identity(manifest, name, new_artifacts[name])}
                    reusable_release = Path(old["current"]["release_path"])
                    reuse_identities = {name: agent_content_identity(reusable_release, name) for name in reusable}
            except (StateError, OSError):
                reusable = set()
                reuse_identities = {}
                reusable_release = None
        desired = requested | reusable
        scope = "all" if desired == {"claude", "codex"} else next(iter(desired))
        release_id = f"{manifest['agentbox_version']}-{digest[:16]}-{scope}"
        release = root / "releases" / release_id
        quarantine: Path | None = None
        if release.exists():
            try:
                existing, existing_hash = load_manifest(release / "manifest.json", expected_version, development)
                if existing_hash != digest or canonical_bytes(existing) != canonical_bytes(manifest):
                    fail("an immutable release directory has conflicting content")
                content_hash, validation_hash, ready_agents = verify_release_content(release, digest, manifest["runtime"]["image"])
                if not desired <= ready_agents:
                    fail("immutable release is missing requested agent content")
            except (StateError, OSError):
                quarantine = root / "staging" / f"repair-{release_id}-{uuid.uuid4().hex}"
                os.replace(release, quarantine)
                fsync_dir(root / "releases")
            else:
                image = manifest["runtime"]["image"]
                platform_name, _ = selected_platform(manifest)
                if development: run_checked([str(engine), "image", "inspect", image])
                else: run_checked([str(engine), "pull", image])
                validate_release(engine, image, platform_name, release, manifest, scope)
                activate(root, manifest, digest, release, content_hash, validation_hash, development, reset_selector); return
        staging = Path(tempfile.mkdtemp(prefix=f"{release_id}.", dir=root / "staging"))
        os.chmod(staging, 0o700)
        try:
            manifest_out = staging / "manifest.json"
            with manifest_out.open("xb") as handle:
                os.fchmod(handle.fileno(), 0o600); handle.write(canonical_bytes(manifest)); handle.flush(); os.fsync(handle.fileno())
            image = manifest["runtime"]["image"]
            if development: run_checked([str(engine), "image", "inspect", image])
            else: run_checked([str(engine), "pull", image])
            platform_name, artifacts = selected_platform(manifest)
            downloads = staging / "downloads"; downloads.mkdir(mode=0o700)
            reused = desired & reusable
            reuse_path: Path | None = None
            if reused and reusable_release is not None:
                reuse_path = staging / "reuse"
                reuse_path.mkdir(mode=0o700)
                for name in sorted(reused):
                    # Preserve any raced-in symlink so the runtime inventory
                    # rejects it instead of following it into user content.
                    shutil.copytree(reusable_release / "vendor" / name, reuse_path / name, symlinks=True)
            if "claude" in desired and "claude" not in reused:
                download_artifact(artifacts["claude"], downloads / "claude", expected_version)
            if "codex" in desired and "codex" not in reused:
                download_artifact(artifacts["codex"], downloads / "codex.tar.gz", expected_version)
            prepare_name = f"agentbox-prepare-{uuid.uuid4().hex}"
            prepare_raw = run_checked([str(engine), "run", "--rm", *candidate_limits(prepare_name), "--network", "none", "--read-only", "--tmpfs", candidate_tmpfs("/tmp", "16m"),
                                       "--tmpfs", candidate_tmpfs("/home/node", "64m", executable=True), "--mount", f"type=bind,src={staging},dst=/opt/agentbox-release", image,
                                       "prepare", "--protocol", "1", "--platform", platform_name, "--manifest", "/opt/agentbox-release/manifest.json",
                                       "--agent", scope, "--downloads", "/opt/agentbox-release/downloads", "--output", "/opt/agentbox-release/vendor",
                                       *(["--reuse", "/opt/agentbox-release/reuse"] if reuse_path is not None else [])],
                                      capture=True, timeout=180, cleanup=(engine, prepare_name))
            prepare_result = protocol_json(prepare_raw, {"content_sha256", "ok", "protocol"}, "runtime prepare result")
            if prepare_result["ok"] is not True or prepare_result["protocol"] != 1:
                fail("runtime prepare result was unsuccessful")
            sha256(string(prepare_result["content_sha256"], "runtime prepare content_sha256").removeprefix("sha256:"), "runtime prepare content_sha256")
            verify_content_ledger(staging, digest)
            for name in reused:
                if agent_content_identity(staging, name) != reuse_identities[name]:
                    fail(f"reused {name} content changed while creating the enriched release")
            assertions = validate_release(engine, image, platform_name, staging, manifest, scope)
            shutil.rmtree(downloads)
            if reuse_path is not None: shutil.rmtree(reuse_path)
            if file_hash(manifest_out) != digest:
                fail("runtime modified the immutable release manifest")
            content_hash, validation_hash = create_validation_receipt(staging, manifest, digest, image, platform_name, prepare_result, assertions)
            verify_release_content(staging, digest, image)
            os.chmod(manifest_out, 0o444, follow_symlinks=False)
            fsync_dir(staging); os.replace(staging, release); fsync_dir(root / "releases")
            activate(root, manifest, digest, release, content_hash, validation_hash, development, reset_selector)
        except BaseException:
            if quarantine is not None and quarantine.exists() and not release.exists():
                os.replace(quarantine, release)
                fsync_dir(root / "releases")
            raise
        finally:
            if staging.exists(): shutil.rmtree(staging, ignore_errors=True)
        if quarantine is not None and quarantine.exists(): shutil.rmtree(quarantine, ignore_errors=True)

def inspect(root: Path, manifest_path: Path | None, expected_version: str, development: bool = False,
            agent: str = "all") -> dict[str, Any]:
    result: dict[str, Any] = {"schema_version": STATE_SCHEMA, "development": development, "state": "absent", "current": None, "previous": None}
    installed_hash = None
    if manifest_path is not None:
        manifest, installed_hash = load_manifest(manifest_path, expected_version, development)
        result["installed"] = {"agentbox_version": manifest["agentbox_version"], "manifest_sha256": installed_hash,
                               "runtime_image": manifest["runtime"]["image"], "runtime_protocol": manifest["runtime_protocol_version"],
                               "claude_version": manifest["tools"]["claude"]["version"], "codex_version": manifest["tools"]["codex"]["version"]}
    record = load_activation(root, development)
    if record is None: return result
    ready_agents = verify_ref(root, record["current"], development)
    requested = {"claude", "codex"} if agent == "all" else {agent}
    result.update({"state": "ready" if requested <= ready_agents else "partial", "ready_agents": sorted(ready_agents),
                   "generation": record["generation"], "current": record["current"], "previous": record["previous"],
                   "selection": record["selection"]})
    if record["selection"]["mode"] == "manual_rollback_hold":
        result["state"] = "manual-rollback-hold"
    elif installed_hash is not None and record["current"]["manifest_sha256"] != installed_hash:
        result["state"] = "different-installed-release"
    return result

def rollback(root: Path, development: bool = False) -> dict[str, Any]:
    if not root.exists(): fail("Agentbox has no managed release to roll back")
    lock_path = root / "locks" / "prepare.lock"
    lock_fd = os.open(lock_path, os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0), 0o600)
    with os.fdopen(lock_fd, "r+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        record = load_activation(root, development)
        if record is None or record["previous"] is None: fail("Agentbox has no previous managed release to roll back to")
        verify_ref(root, record["current"], development)
        verify_ref(root, record["previous"], development)
        updated = {"schema_version": STATE_SCHEMA, "generation": record["generation"] + 1,
                   "current": record["previous"], "previous": record["current"],
                   "selection": {"mode": "manual_rollback_hold", "reason": "vendor_state_risk_accepted"}}
        write_activation(root / "activation.json", updated)
        return updated

def main() -> int:
    parser = argparse.ArgumentParser(prog="state.py")
    parser.add_argument("--development", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--expected-version", help=argparse.SUPPRESS)
    sub = parser.add_subparsers(dest="command", required=True)
    validate = sub.add_parser("validate-manifest"); validate.add_argument("manifest", type=Path)
    show = sub.add_parser("inspect"); show.add_argument("--root", required=True, type=Path); show.add_argument("--manifest", type=Path); show.add_argument("--agent", choices=("claude", "codex", "all"), default="all")
    current = sub.add_parser("current-field"); current.add_argument("--root", required=True, type=Path); current.add_argument("field", choices=("release_path", "runtime_image", "manifest_sha256", "agentbox_version"))
    plan = sub.add_parser("launch-plan"); plan.add_argument("--root", required=True, type=Path); plan.add_argument("--agent", choices=("claude", "codex", "all"), default="all")
    prep = sub.add_parser("prepare"); prep.add_argument("--root", required=True, type=Path); prep.add_argument("--manifest", required=True, type=Path); prep.add_argument("--engine", required=True, type=Path)
    prep.add_argument("--reset-selector", action="store_true")
    prep.add_argument("--agent", choices=("claude", "codex", "all"), default="all")
    rollback_parser = sub.add_parser("rollback"); rollback_parser.add_argument("--root", required=True, type=Path); rollback_parser.add_argument("--accept-vendor-state-risk", action="store_true")
    locked = sub.add_parser("exec-locked"); locked.add_argument("--root", required=True, type=Path); locked.add_argument("argv", nargs=argparse.REMAINDER)
    execute = sub.add_parser("exec-engine"); execute.add_argument("argv", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if hasattr(args, "root"):
        qualify_root(args.root)
    if args.command in {"validate-manifest", "inspect", "current-field", "launch-plan", "prepare", "rollback"}:
        if not isinstance(args.expected_version, str) or not VERSION_RE.fullmatch(args.expected_version):
            fail("a valid --expected-version is required for state and manifest operations")
    if args.command == "validate-manifest":
        manifest, digest = load_manifest(args.manifest, args.expected_version, args.development); print(json.dumps({"agentbox_version": manifest["agentbox_version"], "manifest_sha256": digest}, sort_keys=True))
    elif args.command == "inspect": print(json.dumps(inspect(args.root, args.manifest, args.expected_version, args.development, args.agent), sort_keys=True))
    elif args.command == "current-field":
        record = load_activation(args.root, args.development)
        if record is None: fail("Agentbox has not been set up")
        verify_ref(args.root, record["current"], args.development); print(record["current"][args.field])
    elif args.command == "launch-plan":
        record = load_activation(args.root, args.development)
        if record is None: fail("Agentbox has not been set up")
        ready_agents = verify_ref(args.root, record["current"], args.development)
        requested = {"claude", "codex"} if args.agent == "all" else {args.agent}
        if not requested <= ready_agents: fail(f"active release is not prepared for {args.agent}")
        print(json.dumps({"generation": record["generation"], "runtime_root": str(args.root), "current": record["current"]}, sort_keys=True))
    elif args.command == "prepare":
        if not args.root.is_absolute() or not args.manifest.is_absolute() or not args.engine.is_absolute(): fail("prepare paths must be absolute")
        prepare(args.root, args.manifest, args.engine, args.expected_version, args.development, args.reset_selector, args.agent)
    elif args.command == "rollback":
        if not args.accept_vendor_state_risk: fail("rollback requires --accept-vendor-state-risk")
        print(json.dumps(rollback(args.root, args.development), sort_keys=True))
    elif args.command == "exec-locked":
        if not args.argv or args.argv[0] != "--" or len(args.argv) == 1: fail("exec-locked requires -- COMMAND [ARG ...]")
        ensure_root(args.root)
        fd = os.open(args.root / "locks" / "auth.lock", os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0), 0o600)
        with os.fdopen(fd, "r+") as lock:
            try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError: fail("another Agentbox authentication operation is running")
            child_env = clean_engine_env(); child_env["GH_TOKEN"] = os.environ.get("GH_TOKEN", "")
            if os.environ.get("OPENAI_API_KEY"): child_env["OPENAI_API_KEY"] = os.environ["OPENAI_API_KEY"]
            return subprocess.run(args.argv[1:], env=child_env).returncode
    elif args.command == "exec-engine":
        if not args.argv or args.argv[0] != "--" or len(args.argv) == 1: fail("exec-engine requires -- COMMAND [ARG ...]")
        child_env = clean_engine_env(); child_env["GH_TOKEN"] = os.environ.get("GH_TOKEN", "")
        if os.environ.get("OPENAI_API_KEY"): child_env["OPENAI_API_KEY"] = os.environ["OPENAI_API_KEY"]
        os.execve(args.argv[1], args.argv[1:], child_env)
    return 0

if __name__ == "__main__":
    try: raise SystemExit(main())
    except StateError as exc:
        print(f"agentbox: {exc}", file=sys.stderr); raise SystemExit(65)
