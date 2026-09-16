#!/usr/bin/env python3
"""Deterministically select the next Agentbox release source and version."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any, NoReturn


SHA_RE = re.compile(r"^[0-9a-f]{40}$")
TAG_RE = re.compile(r"^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
LEGACY_VERSION = (0, 1, 0)
LEGACY_RELEASE_ID = 389422097
LEGACY_SOURCE = "d2a9a8eebcbfa01f3684963998ee1554659c6443"
LEGACY_ASSETS = {
    "agentbox-0.1.0.provenance.json": "sha256:9f2f4c6238a5238cdd01aa650d8b1d899cfc41b725a8500433a113eb22c28536",
    "agentbox-0.1.0.tar.gz": "sha256:e0d8159d80408f38cd0e57434786035b5b83dcb1e1b8a39c1620fa947c36c429",
    "agentbox-0.1.0.tar.gz.sha256": "sha256:170bc4b8c145204c26b8c23e51416e2abac091198c7ad20c03150c6786f6e8ed",
}
TEMPLATE_MARKERS = ("source_sentinel", "dockerfile_sentinel", "formula_sentinel")


class PlanError(Exception):
    pass


def fail(message: str) -> NoReturn:
    raise PlanError(message)


def read_json(path: Path, label: str) -> Any:
    try:
        with path.open(encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, json.JSONDecodeError) as error:
        fail(f"cannot read {label} JSON from {path}: {error}")


def flatten_pages(value: Any, key: str | None, label: str) -> list[Any]:
    if key is not None and isinstance(value, dict):
        value = value.get(key)
    if not isinstance(value, list):
        fail(f"{label} JSON must be an array")
    result: list[Any] = []
    for item in value:
        if isinstance(item, list):
            result.extend(item)
        else:
            result.append(item)
    return result


def source_of(value: dict[str, Any], label: str) -> str:
    source = value.get("source_commit", value.get("target_commitish"))
    if not isinstance(source, str) or not SHA_RE.fullmatch(source):
        fail(f"{label} must identify a 40-character lowercase source commit")
    return source


def parse_commits(value: Any) -> list[dict[str, Any]]:
    raw = (
        flatten_pages(value, "commits", "commits")
        if isinstance(value, dict)
        else flatten_pages(value, None, "commits")
    )
    commits: list[dict[str, Any]] = []
    seen: set[str] = set()
    for index, item in enumerate(raw):
        if not isinstance(item, dict):
            fail(f"commit {index} must be an object with all template markers")
        sha = item.get("sha", item.get("oid"))
        if not isinstance(sha, str) or not SHA_RE.fullmatch(sha):
            fail(f"commit {index} must identify a 40-character lowercase SHA")
        markers: dict[str, bool] = {}
        for marker in TEMPLATE_MARKERS:
            if not isinstance(item.get(marker), bool):
                fail(f"commit {index} must contain boolean {marker}")
            markers[marker] = item[marker]
        if sha in seen:
            fail(f"commits contain duplicate SHA {sha}")
        seen.add(sha)
        commits.append({"sha": sha, **markers})
    if not commits:
        fail("commits JSON must not be empty")
    return commits


def parse_runs(value: Any) -> list[dict[str, Any]]:
    if isinstance(value, dict):
        raw = flatten_pages(value, "workflow_runs", "CI runs")
    else:
        pages = flatten_pages(value, None, "CI runs")
        raw = []
        for page in pages:
            if isinstance(page, dict) and "workflow_runs" in page:
                runs = page["workflow_runs"]
                if not isinstance(runs, list):
                    fail("CI runs page workflow_runs must be an array")
                raw.extend(runs)
            else:
                raw.append(page)
    runs: list[dict[str, Any]] = []
    for index, item in enumerate(raw):
        if not isinstance(item, dict):
            fail(f"CI run {index} must be an object")
        runs.append(item)
    return runs


def is_successful_main_push(run: dict[str, Any], sha: str) -> bool:
    if run.get("head_sha") != sha:
        return False
    if run.get("event") != "push" or run.get("head_branch") != "main":
        return False
    if (
        run.get("status") not in (None, "completed")
        or run.get("conclusion") != "success"
    ):
        return False
    if run.get("name") not in (None, "CI"):
        return False
    if run.get("path") not in (None, ".github/workflows/ci.yml"):
        return False
    head_repository = run.get("head_repository")
    repository = run.get("repository")
    if isinstance(head_repository, dict) and isinstance(repository, dict):
        if head_repository.get("full_name") != repository.get("full_name"):
            return False
    return True


def parse_release_version(release: dict[str, Any]) -> tuple[int, int, int] | None:
    tag = release.get("tag_name")
    if not isinstance(tag, str):
        return None
    match = TAG_RE.fullmatch(tag)
    if match is None:
        return None
    return tuple(int(part) for part in match.groups())  # type: ignore[return-value]


def validate_legacy(release: dict[str, Any]) -> None:
    if (
        release.get("id") != LEGACY_RELEASE_ID
        or source_of(release, "legacy v0.1.0 release") != LEGACY_SOURCE
    ):
        fail("v0.1.0 does not match the pinned legacy release identity")
    if release.get("immutable") is not False:
        fail("v0.1.0 legacy release must be the sole mutable anchor")
    assets = release.get("assets")
    if not isinstance(assets, list):
        fail("v0.1.0 legacy release is missing its pinned assets")
    observed: dict[str, str] = {}
    for asset in assets:
        if (
            not isinstance(asset, dict)
            or not isinstance(asset.get("name"), str)
            or not isinstance(asset.get("digest"), str)
        ):
            fail("v0.1.0 legacy release has malformed asset metadata")
        if asset["name"] in observed:
            fail(f"v0.1.0 legacy release repeats asset {asset['name']}")
        observed[asset["name"]] = asset["digest"]
    if observed != LEGACY_ASSETS:
        fail("v0.1.0 legacy release assets do not match the pinned provenance tuple")


def inspect_releases(
    value: Any,
) -> tuple[list[tuple[tuple[int, int, int], dict[str, Any]]], dict[str, Any] | None]:
    raw = (
        flatten_pages(value, "releases", "releases")
        if isinstance(value, dict)
        else flatten_pages(value, None, "releases")
    )
    published: dict[tuple[int, int, int], dict[str, Any]] = {}
    drafts: list[tuple[tuple[int, int, int], dict[str, Any]]] = []
    for index, item in enumerate(raw):
        if not isinstance(item, dict):
            fail(f"release {index} must be an object")
        version = parse_release_version(item)
        if version is None or item.get("prerelease") is True:
            continue
        if version == (0, 0, 0):
            fail("v0.0.0 is the non-publishable source sentinel")
        draft = item.get("draft")
        if not isinstance(draft, bool):
            fail(
                f"stable release v{'.'.join(map(str, version))} has no boolean draft state"
            )
        if draft:
            drafts.append((version, item))
            continue
        if version in published:
            fail(f"multiple published releases use v{'.'.join(map(str, version))}")
        if version == LEGACY_VERSION:
            validate_legacy(item)
        elif item.get("immutable") is not True:
            fail(f"published release v{'.'.join(map(str, version))} is not immutable")
        published[version] = item
    if not published:
        fail("no published stable release establishes the version cursor")
    ordered_published = sorted(published.items())
    latest_version = ordered_published[-1][0]
    next_version = (latest_version[0], latest_version[1], latest_version[2] + 1)
    matching_drafts = [
        release for version, release in drafts if version == next_version
    ]
    conflicting_drafts = [version for version, _ in drafts if version != next_version]
    if conflicting_drafts:
        tags = ", ".join(
            f"v{'.'.join(map(str, version))}" for version in sorted(conflicting_drafts)
        )
        fail(f"stable draft release conflicts with the next version cursor: {tags}")
    if len(matching_drafts) > 1:
        fail(f"multiple drafts reserve v{'.'.join(map(str, next_version))}")
    return ordered_published, matching_drafts[0] if matching_drafts else None


def render_version(version: tuple[int, int, int]) -> str:
    return ".".join(map(str, version))


def result(
    action: str,
    version: str,
    source_commit: str,
    reason: str,
    backlog_count: int,
    oldest_pending_commit: str,
    oldest_pending_status: str,
) -> dict[str, str | int]:
    return {
        "action": action,
        "version": version,
        "source_commit": source_commit,
        "reason": reason,
        "backlog_count": backlog_count,
        "oldest_pending_commit": oldest_pending_commit,
        "oldest_pending_status": oldest_pending_status,
    }


def make_plan(
    releases_value: Any,
    commits_value: Any,
    runs_value: Any,
    recovery_sha: str | None,
    allow_orphan_recovery: bool,
) -> dict[str, str | int]:
    if recovery_sha is not None and not SHA_RE.fullmatch(recovery_sha):
        fail("--recovery-sha must be 40 lowercase hexadecimal characters")
    if allow_orphan_recovery and recovery_sha is None:
        fail("--allow-orphan-recovery requires --recovery-sha")

    published, draft = inspect_releases(releases_value)
    commits = parse_commits(commits_value)
    runs = parse_runs(runs_value)
    positions = {commit["sha"]: index for index, commit in enumerate(commits)}

    published_sources: set[str] = set()
    previous_position = -1
    for version, release in published:
        version_text = render_version(version)
        source = source_of(release, f"published release v{version_text}")
        if source in published_sources:
            fail(f"published stable releases reuse source commit {source}")
        if source not in positions:
            fail(
                f"published release v{version_text} source is not on first-parent main"
            )
        position = positions[source]
        if position <= previous_position:
            fail(
                "published stable release sources are not strictly increasing on first-parent main"
            )
        if version != LEGACY_VERSION and not all(
            commits[position][marker] for marker in TEMPLATE_MARKERS
        ):
            fail(
                f"published release v{version_text} source does not contain every sentinel template"
            )
        published_sources.add(source)
        previous_position = position

    latest_version, latest_release = published[-1]
    latest_source = source_of(
        latest_release, f"published release v{render_version(latest_version)}"
    )
    cursor = positions[latest_source]

    pending: list[dict[str, Any]] = []
    templates_started = latest_version != LEGACY_VERSION
    for commit in commits[cursor + 1 :]:
        markers = [commit[marker] for marker in TEMPLATE_MARKERS]
        if all(markers):
            templates_started = True
            pending.append(commit)
        elif any(markers) or templates_started:
            fail(f"commit {commit['sha']} does not contain every sentinel template")

    def eligible(commit: dict[str, Any]) -> bool:
        return any(is_successful_main_push(run, commit["sha"]) for run in runs)

    candidates = [commit["sha"] for commit in pending if eligible(commit)]
    oldest_pending_commit = pending[0]["sha"] if pending else ""
    oldest_pending_status = "none"
    if pending:
        oldest_pending_status = "eligible" if eligible(pending[0]) else "awaiting_ci"
    backlog_count = len(candidates)
    next_tuple = (latest_version[0], latest_version[1], latest_version[2] + 1)
    next_version = render_version(next_tuple)

    if draft is not None:
        draft_source = source_of(draft, f"draft release v{next_version}")
        if draft_source not in positions or positions[draft_source] <= cursor:
            fail(f"draft v{next_version} source is stale or not on first-parent main")
        if not all(
            commits[positions[draft_source]][marker] for marker in TEMPLATE_MARKERS
        ) or not eligible(commits[positions[draft_source]]):
            fail(
                f"draft v{next_version} source lacks sentinel templates or successful main-push CI"
            )
        if not candidates or candidates[0] != draft_source:
            fail(f"draft v{next_version} does not reserve the oldest eligible source")
        if recovery_sha is not None and recovery_sha != draft_source:
            fail(f"--recovery-sha conflicts with draft v{next_version}")
        reason = f"resume draft v{next_version} reserved for oldest eligible source"
        if allow_orphan_recovery:
            reason += " with explicit orphan recovery"
        return result(
            "resume",
            next_version,
            draft_source,
            reason,
            backlog_count,
            oldest_pending_commit,
            oldest_pending_status,
        )

    if recovery_sha is not None:
        if recovery_sha not in positions:
            fail("--recovery-sha is not on ordered first-parent main")
        if allow_orphan_recovery and positions[recovery_sha] <= cursor:
            fail("--allow-orphan-recovery applies only to an unpublished source")
        if positions[recovery_sha] < cursor:
            return result(
                "noop",
                "",
                "",
                "recovery source is older than the latest published release",
                backlog_count,
                oldest_pending_commit,
                oldest_pending_status,
            )
        if positions[recovery_sha] == cursor:
            return result(
                "resume",
                render_version(latest_version),
                latest_source,
                "resume latest published release for downstream repair",
                backlog_count,
                oldest_pending_commit,
                oldest_pending_status,
            )
        if not all(
            commits[positions[recovery_sha]][marker] for marker in TEMPLATE_MARKERS
        ) or not eligible(commits[positions[recovery_sha]]):
            fail("--recovery-sha lacks sentinel templates or successful main-push CI")
        if not candidates or candidates[0] != recovery_sha:
            fail("--recovery-sha is not the oldest eligible unreleased source")

    if not candidates:
        return result(
            "noop",
            "",
            "",
            "no eligible unreleased first-parent main commit",
            backlog_count,
            oldest_pending_commit,
            oldest_pending_status,
        )

    source = recovery_sha or candidates[0]
    reason = "publish oldest eligible first-parent main commit"
    if allow_orphan_recovery:
        reason += " with explicit orphan recovery"
    return result(
        "publish",
        next_version,
        source,
        reason,
        backlog_count,
        oldest_pending_commit,
        oldest_pending_status,
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--releases", required=True, type=Path, help="GitHub releases JSON"
    )
    parser.add_argument(
        "--commits",
        required=True,
        type=Path,
        help="oldest-to-newest first-parent main JSON",
    )
    parser.add_argument(
        "--ci-runs", required=True, type=Path, help="GitHub CI workflow-runs JSON"
    )
    parser.add_argument(
        "--recovery-sha", help="optional exact source for manual recovery"
    )
    parser.add_argument(
        "--allow-orphan-recovery",
        action="store_true",
        help="record explicit orphan-image recovery intent",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        plan = make_plan(
            read_json(args.releases, "releases"),
            read_json(args.commits, "commits"),
            read_json(args.ci_runs, "CI runs"),
            args.recovery_sha,
            args.allow_orphan_recovery,
        )
    except PlanError as error:
        print(f"plan-release: {error}", file=sys.stderr)
        return 2
    print(json.dumps(plan, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
