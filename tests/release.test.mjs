import assert from "node:assert/strict";
import {
  cpSync,
  mkdirSync,
  readFileSync,
  writeFileSync,
} from "node:fs";
import { resolve } from "node:path";
import test from "node:test";
import { ROOT, expectExit, run, tempDir, writeExecutable } from "./helpers.mjs";

const PLANNER = resolve(ROOT, "scripts/plan-release.py");
const LEGACY_SOURCE = "d2a9a8eebcbfa01f3684963998ee1554659c6443";
const SHA_A = "a".repeat(40);
const SHA_B = "b".repeat(40);
const SHA_C = "c".repeat(40);
const SHA_D = "d".repeat(40);
const REPOSITORY = { full_name: "zurfyx/agentbox" };

const LEGACY_ASSETS = [
  {
    name: "agentbox-0.1.0.provenance.json",
    digest: "sha256:9f2f4c6238a5238cdd01aa650d8b1d899cfc41b725a8500433a113eb22c28536",
  },
  {
    name: "agentbox-0.1.0.tar.gz",
    digest: "sha256:e0d8159d80408f38cd0e57434786035b5b83dcb1e1b8a39c1620fa947c36c429",
  },
  {
    name: "agentbox-0.1.0.tar.gz.sha256",
    digest: "sha256:170bc4b8c145204c26b8c23e51416e2abac091198c7ad20c03150c6786f6e8ed",
  },
];

function legacy(overrides = {}) {
  return {
    id: 389422097,
    tag_name: "v0.1.0",
    target_commitish: LEGACY_SOURCE,
    draft: false,
    prerelease: false,
    immutable: false,
    assets: LEGACY_ASSETS,
    ...overrides,
  };
}

function published(version, source, overrides = {}) {
  return {
    tag_name: `v${version}`,
    target_commitish: source,
    draft: false,
    prerelease: false,
    immutable: true,
    assets: [],
    ...overrides,
  };
}

function successfulRun(sha, overrides = {}) {
  return {
    name: "CI",
    path: ".github/workflows/ci.yml",
    event: "push",
    head_branch: "main",
    head_sha: sha,
    status: "completed",
    conclusion: "success",
    head_repository: REPOSITORY,
    repository: REPOSITORY,
    ...overrides,
  };
}

function sourceCommit(sha, overrides = {}) {
  return {
    sha,
    source_sentinel: true,
    dockerfile_sentinel: true,
    formula_sentinel: true,
    ...overrides,
  };
}

function plan(t, { releases, commits, runs, args = [] }) {
  const dir = tempDir(t);
  const paths = {
    releases: resolve(dir, "releases.json"),
    commits: resolve(dir, "commits.json"),
    runs: resolve(dir, "runs.json"),
  };
  writeFileSync(paths.releases, JSON.stringify(releases));
  writeFileSync(paths.commits, JSON.stringify(commits));
  writeFileSync(paths.runs, JSON.stringify(runs));
  const result = run("python3", [
    PLANNER,
    "--releases",
    paths.releases,
    "--commits",
    paths.commits,
    "--ci-runs",
    paths.runs,
    ...args,
  ]);
  return {
    result,
    value: result.status === 0 ? JSON.parse(result.stdout) : undefined,
  };
}

test("planner sorts stable SemVer numerically and ignores malformed and prerelease tags", (t) => {
  const result = plan(t, {
    releases: [
      published("1.10.2", SHA_B),
      { tag_name: "latest", draft: false, prerelease: false },
      published("9.0.0", SHA_D, { prerelease: true }),
      published("1.9.99", SHA_A),
      { tag_name: "v01.10.3", draft: false, prerelease: false },
    ],
    commits: [SHA_A, SHA_B, SHA_C, SHA_D].map((sha) => sourceCommit(sha)),
    runs: [successfulRun(SHA_C), successfulRun(SHA_D)],
  });
  expectExit(result.result, 0, "numeric planner fixture");
  assert.deepEqual(result.value, {
    action: "publish",
    backlog_count: 2,
    oldest_pending_commit: SHA_C,
    oldest_pending_status: "eligible",
    reason: "publish oldest eligible first-parent main commit",
    source_commit: SHA_C,
    version: "1.10.3",
  });
  assert.equal(
    result.result.stdout,
    `${JSON.stringify(result.value)}\n`,
    "planner output must be canonical and deterministic",
  );
});

test("planner accepts only the exact pinned v0.1.0 legacy anchor", async (t) => {
  await t.test("exact anchor", (t) => {
    const result = plan(t, {
      releases: [legacy()],
      commits: [sourceCommit(LEGACY_SOURCE), sourceCommit(SHA_A)],
      runs: [successfulRun(SHA_A)],
    });
    expectExit(result.result, 0, "legacy planner fixture");
    assert.equal(result.value.version, "0.1.1");
    assert.equal(result.value.source_commit, SHA_A);
  });

  for (const [label, release] of [
    ["identity", legacy({ id: 1 })],
    ["source", legacy({ target_commitish: SHA_A })],
    ["immutability", legacy({ immutable: true })],
    ["assets", legacy({ assets: LEGACY_ASSETS.slice(1) })],
  ]) {
    await t.test(`rejects changed ${label}`, (t) => {
      const result = plan(t, {
        releases: [release],
        commits: [sourceCommit(LEGACY_SOURCE), sourceCommit(SHA_A)],
        runs: [successfulRun(SHA_A)],
      });
      expectExit(result.result, 2, `changed legacy ${label}`);
      assert.match(result.result.stderr, /legacy.*v0\.1\.0|v0\.1\.0.*legacy/);
    });
  }
});

test("planner publishes the oldest sentinel-bearing commit with exact successful main-push CI", (t) => {
  const result = plan(t, {
    releases: [legacy()],
    commits: [
      sourceCommit(LEGACY_SOURCE),
      sourceCommit(SHA_B, {
        source_sentinel: false,
        dockerfile_sentinel: false,
        formula_sentinel: false,
      }),
      sourceCommit(SHA_A),
      sourceCommit(SHA_C),
      sourceCommit(SHA_D),
    ],
    runs: [
      successfulRun(SHA_A, { conclusion: "failure" }),
      successfulRun(SHA_A, { event: "pull_request" }),
      successfulRun(SHA_A, { head_branch: "feature" }),
      successfulRun(SHA_A, {
        head_repository: { full_name: "fork/agentbox" },
      }),
      successfulRun(SHA_B),
      successfulRun(SHA_C, { actor: { login: "dependabot[bot]" } }),
      successfulRun(SHA_D),
    ],
  });
  expectExit(result.result, 0, "eligibility planner fixture");
  assert.equal(result.value.source_commit, SHA_C);
  assert.equal(result.value.action, "publish");
});

test("planner resumes matching partial work and no-ops duplicate or stale wakeups", async (t) => {
  await t.test("matching draft", (t) => {
    const result = plan(t, {
      releases: [
        legacy(),
        published("0.1.1", SHA_A, { draft: true, immutable: false }),
      ],
      commits: [sourceCommit(LEGACY_SOURCE), sourceCommit(SHA_A)],
      runs: [successfulRun(SHA_A)],
    });
    expectExit(result.result, 0, "draft resume");
    assert.equal(result.value.action, "resume");
    assert.equal(result.value.version, "0.1.1");
    assert.equal(result.value.source_commit, SHA_A);
  });

  await t.test("nothing eligible", (t) => {
    const result = plan(t, {
      releases: [legacy()],
      commits: [sourceCommit(LEGACY_SOURCE), sourceCommit(SHA_A)],
      runs: [successfulRun(SHA_A, { conclusion: "cancelled" })],
    });
    expectExit(result.result, 0, "no-op plan");
    assert.deepEqual(result.value, {
      action: "noop",
      backlog_count: 0,
      oldest_pending_commit: SHA_A,
      oldest_pending_status: "awaiting_ci",
      reason: "no eligible unreleased first-parent main commit",
      source_commit: "",
      version: "",
    });
  });

  await t.test("stale recovery", (t) => {
    const result = plan(t, {
      releases: [legacy(), published("0.1.1", SHA_A)],
      commits: [sourceCommit(LEGACY_SOURCE), sourceCommit(SHA_A)],
      runs: [],
      args: ["--recovery-sha", LEGACY_SOURCE],
    });
    expectExit(result.result, 0, "stale recovery");
    assert.equal(result.value.action, "noop");
  });

  await t.test("published downstream repair", (t) => {
    const result = plan(t, {
      releases: [legacy(), published("0.1.1", SHA_A)],
      commits: [sourceCommit(LEGACY_SOURCE), sourceCommit(SHA_A)],
      runs: [],
      args: ["--recovery-sha", SHA_A],
    });
    expectExit(result.result, 0, "published recovery");
    assert.deepEqual(result.value, {
      action: "resume",
      backlog_count: 0,
      oldest_pending_commit: "",
      oldest_pending_status: "none",
      reason: "resume latest published release for downstream repair",
      source_commit: SHA_A,
      version: "0.1.1",
    });
  });
});

test("planner fails closed on conflicting or out-of-order state", async (t) => {
  const fixtures = [
    {
      label: "conflicting draft version",
      releases: [legacy(), published("4.0.0", SHA_A, { draft: true, immutable: false })],
      commits: [sourceCommit(LEGACY_SOURCE), sourceCommit(SHA_A)],
      runs: [successfulRun(SHA_A)],
      args: [],
      error: /draft release conflicts/,
    },
    {
      label: "draft skips oldest source",
      releases: [legacy(), published("0.1.1", SHA_B, { draft: true, immutable: false })],
      commits: [sourceCommit(LEGACY_SOURCE), sourceCommit(SHA_A), sourceCommit(SHA_B)],
      runs: [successfulRun(SHA_A), successfulRun(SHA_B)],
      args: [],
      error: /does not reserve the oldest eligible source/,
    },
    {
      label: "mutable modern release",
      releases: [legacy(), published("0.1.1", SHA_A, { immutable: false })],
      commits: [sourceCommit(LEGACY_SOURCE), sourceCommit(SHA_A)],
      runs: [],
      args: [],
      error: /not immutable/,
    },
    {
      label: "malformed stable release",
      releases: [legacy(), { tag_name: "v0.1.1", prerelease: false }],
      commits: [sourceCommit(LEGACY_SOURCE), sourceCommit(SHA_A)],
      runs: [],
      args: [],
      error: /no boolean draft state/,
    },
    {
      label: "manual source skips queue",
      releases: [legacy()],
      commits: [sourceCommit(LEGACY_SOURCE), sourceCommit(SHA_A), sourceCommit(SHA_B)],
      runs: [successfulRun(SHA_A), successfulRun(SHA_B)],
      args: ["--recovery-sha", SHA_B],
      error: /not the oldest eligible/,
    },
  ];

  for (const fixture of fixtures) {
    await t.test(fixture.label, (t) => {
      const result = plan(t, fixture);
      expectExit(result.result, 2, fixture.label);
      assert.match(result.result.stderr, fixture.error);
    });
  }
});

test("planner validates the complete published source history", async (t) => {
  const fixtures = [
    {
      label: "reused source",
      releases: [legacy(), published("0.1.1", SHA_A), published("0.1.2", SHA_A)],
      commits: [sourceCommit(LEGACY_SOURCE), sourceCommit(SHA_A)],
      error: /reuse source commit/,
    },
    {
      label: "reversed source order",
      releases: [legacy(), published("0.1.1", SHA_B), published("0.1.2", SHA_A)],
      commits: [sourceCommit(LEGACY_SOURCE), sourceCommit(SHA_A), sourceCommit(SHA_B)],
      error: /not strictly increasing/,
    },
    {
      label: "source absent from first-parent main",
      releases: [legacy(), published("0.1.1", SHA_D)],
      commits: [sourceCommit(LEGACY_SOURCE), sourceCommit(SHA_A)],
      error: /source is not on first-parent main/,
    },
    {
      label: "published source missing formula sentinel",
      releases: [legacy(), published("0.1.1", SHA_A)],
      commits: [
        sourceCommit(LEGACY_SOURCE),
        sourceCommit(SHA_A, { formula_sentinel: false }),
      ],
      error: /does not contain every sentinel template/,
    },
  ];

  for (const fixture of fixtures) {
    await t.test(fixture.label, (t) => {
      const result = plan(t, { ...fixture, runs: [] });
      expectExit(result.result, 2, fixture.label);
      assert.match(result.result.stderr, fixture.error);
    });
  }
});

test("planner requires every source, Docker, and formula marker and reports backlog state", async (t) => {
  for (const marker of ["source_sentinel", "dockerfile_sentinel", "formula_sentinel"]) {
    await t.test(`rejects a candidate without ${marker}`, (t) => {
      const result = plan(t, {
        releases: [legacy()],
        commits: [
          sourceCommit(LEGACY_SOURCE),
          sourceCommit(SHA_A, { [marker]: false }),
        ],
        runs: [successfulRun(SHA_A)],
      });
      expectExit(result.result, 2, `missing ${marker}`);
      assert.match(result.result.stderr, /does not contain every sentinel template/);
    });
  }

  await t.test("reports eligible backlog behind an awaiting-CI oldest commit", (t) => {
    const result = plan(t, {
      releases: [legacy()],
      commits: [
        sourceCommit(LEGACY_SOURCE),
        sourceCommit(SHA_A),
        sourceCommit(SHA_B),
        sourceCommit(SHA_C),
      ],
      runs: [successfulRun(SHA_B), successfulRun(SHA_C)],
    });
    expectExit(result.result, 0, "backlog plan");
    assert.equal(result.value.action, "publish");
    assert.equal(result.value.source_commit, SHA_B);
    assert.equal(result.value.backlog_count, 2);
    assert.equal(result.value.oldest_pending_commit, SHA_A);
    assert.equal(result.value.oldest_pending_status, "awaiting_ci");
    assert.deepEqual(Object.keys(result.value).sort(), [
      "action",
      "backlog_count",
      "oldest_pending_commit",
      "oldest_pending_status",
      "reason",
      "source_commit",
      "version",
    ]);
  });
});

test("renderer rejects missing, sentinel, and noncanonical publish versions", () => {
  for (const [args, error] of [
    [["--dry-run"], /--version is required/],
    [["--dry-run", "--version", "0.0.0"], /must not be the 0\.0\.0/],
    [["--dry-run", "--version", "01.2.3"], /canonical X\.Y\.Z/],
    [["--dry-run", "--version", "1.2.3-rc.1"], /canonical X\.Y\.Z/],
  ]) {
    const result = run("bash", ["scripts/release.sh", ...args]);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, error);
  }
});

test("renderer coherently and deterministically injects one derived version", (t) => {
  const dir = tempDir(t);
  const tree = resolve(dir, "tree");
  cpSync(ROOT, tree, {
    recursive: true,
    filter: (source) =>
      ![".git", ".audit", "dist", "node_modules"].includes(source.split("/").at(-1)),
  });
  expectExit(run("git", ["init", "-q"], { cwd: tree }), 0, "renderer fixture git init");
  expectExit(run("git", ["add", "."], { cwd: tree }), 0, "renderer fixture git add");
  expectExit(
    run(
      "git",
      ["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-qm", "fixture"],
      { cwd: tree },
    ),
    0,
    "renderer fixture git commit",
  );
  const head = run("git", ["rev-parse", "HEAD"], { cwd: tree }).stdout.trim();
  const fakeBin = resolve(dir, "bin");
  mkdirSync(fakeBin);
  writeExecutable(
    resolve(fakeBin, "tar"),
    `#!/usr/bin/env python3
import gzip
import os
import pathlib
import sys
import tarfile

if sys.argv[1:] == ["--version"]:
    print("tar (GNU tar) test shim")
    raise SystemExit(0)
args = sys.argv[1:]
output = args[args.index("-czf") + 1]
base = pathlib.Path(args[args.index("-C") + 1])
root = args[-1]
epoch_arg = next(value for value in args if value.startswith("--mtime=@"))
epoch = int(epoch_arg.split("@", 1)[1])
with open(output, "wb") as raw:
    with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as compressed:
        with tarfile.open(fileobj=compressed, mode="w", format=tarfile.USTAR_FORMAT) as archive:
            paths = [base / root]
            paths += sorted((base / root).rglob("*"), key=lambda path: path.as_posix())
            for path in paths:
                info = archive.gettarinfo(path, arcname=path.relative_to(base).as_posix())
                info.uid = info.gid = 0
                info.uname = info.gname = ""
                info.mtime = epoch
                if info.isfile():
                    with path.open("rb") as source:
                        archive.addfile(info, source)
                else:
                    archive.addfile(info)
`,
  );

  const version = "12.34.56";
  const digestArgs = [
    "--index-digest",
    `sha256:${"1".repeat(64)}`,
    "--amd64-digest",
    `sha256:${"2".repeat(64)}`,
    "--arm64-digest",
    `sha256:${"3".repeat(64)}`,
  ];
  for (const output of ["dist-a", "dist-b"]) {
    const result = run(
      "bash",
      [
        resolve(ROOT, "scripts/release.sh"),
        "--source-root",
        tree,
        "--version",
        version,
        "--source-commit",
        head,
        ...digestArgs,
        "--output-dir",
        resolve(dir, output),
      ],
      {
        cwd: ROOT,
        env: { PATH: `${fakeBin}:${process.env.PATH}` },
      },
    );
    expectExit(result, 0, `render ${output}`);
  }

  const asset = `agentbox-${version}.tar.gz`;
  assert.deepEqual(
    readFileSync(resolve(dir, "dist-a", asset)),
    readFileSync(resolve(dir, "dist-b", asset)),
  );
  assert.deepEqual(
    readFileSync(resolve(dir, "dist-a", `agentbox-${version}.provenance.json`)),
    readFileSync(resolve(dir, "dist-b", `agentbox-${version}.provenance.json`)),
  );

  const inspect = run(
    "python3",
    [
      "-c",
      [
        "import json,sys,tarfile",
        "with tarfile.open(sys.argv[1], 'r:gz') as archive:",
        " names=archive.getnames()",
        " root=archive.extractfile(sys.argv[2]).read().decode()",
        " share=archive.extractfile(sys.argv[3]).read().decode()",
        " manifest=json.load(archive.extractfile(sys.argv[4]))",
        "print(json.dumps({'names':names,'root':root,'share':share,'manifest':manifest},sort_keys=True))",
      ].join("\n"),
      resolve(dir, "dist-a", asset),
      `agentbox-${version}/VERSION`,
      `agentbox-${version}/share/agentbox/VERSION`,
      `agentbox-${version}/share/agentbox/release-manifest.json`,
    ],
  );
  expectExit(inspect, 0, "rendered archive inspection");
  const rendered = JSON.parse(inspect.stdout);
  assert.equal(rendered.root, `${version}\n`);
  assert.equal(rendered.share, `${version}\n`);
  assert.equal(rendered.manifest.agentbox_version, version);
  assert.equal(
    rendered.manifest.runtime.image,
    `ghcr.io/zurfyx/agentbox-runtime@sha256:${"1".repeat(64)}`,
  );
  const provenance = JSON.parse(
    readFileSync(resolve(dir, "dist-a", `agentbox-${version}.provenance.json`)),
  );
  assert.equal(provenance.agentbox_version, version);
  assert.equal(provenance.source_commit, head);
  assert.equal(provenance.archive, asset);
  assert.equal(readFileSync(resolve(tree, "VERSION"), "utf8"), "0.0.0\n");
  assert.equal(JSON.parse(readFileSync(resolve(tree, "release-inputs.json"))).agentbox_version, "0.0.0");
});

test("trusted renderer rejects every Docker and formula sentinel deviation", async (t) => {
  const cases = [
    {
      label: "Docker value",
      path: "Dockerfile",
      mutate: (text) => text.replace("ARG AGENTBOX_VERSION=0.0.0", "ARG AGENTBOX_VERSION=1.2.3"),
      error: /Dockerfile must contain exactly/,
    },
    {
      label: "duplicate Docker authority",
      path: "Dockerfile",
      mutate: (text) => `${text}\nARG AGENTBOX_VERSION=0.0.0\n`,
      error: /Dockerfile must contain exactly/,
    },
    {
      label: "formula URL",
      path: "Formula/agentbox.rb",
      mutate: (text) => text.replace("releases/download/v0.0.0/agentbox-0.0.0.tar.gz", "releases/download/v1.2.3/agentbox-1.2.3.tar.gz"),
      error: /Formula\/agentbox\.rb must contain exactly/,
    },
    {
      label: "formula version",
      path: "Formula/agentbox.rb",
      mutate: (text) => text.replace('version "0.0.0"', 'version "1.2.3"'),
      error: /Formula\/agentbox\.rb must contain exactly/,
    },
    {
      label: "formula checksum",
      path: "Formula/agentbox.rb",
      mutate: (text) => text.replace(`sha256 "${"0".repeat(64)}"`, `sha256 "${"1".repeat(64)}"`),
      error: /Formula\/agentbox\.rb must contain exactly/,
    },
  ];

  for (const fixture of cases) {
    await t.test(fixture.label, (t) => {
      const dir = tempDir(t);
      const tree = resolve(dir, "source");
      cpSync(ROOT, tree, {
        recursive: true,
        filter: (source) =>
          ![".git", ".audit", "dist", "node_modules"].includes(source.split("/").at(-1)),
      });
      const path = resolve(tree, fixture.path);
      writeFileSync(path, fixture.mutate(readFileSync(path, "utf8")));
      const result = run("bash", [
        "scripts/release.sh",
        "--dry-run",
        "--source-root",
        tree,
        "--source-commit",
        SHA_A,
        "--version",
        "1.2.3",
      ]);
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, fixture.error);
    });
  }
});

test("automatic release workflows encode trusted wakeups and immutable publication", () => {
  const release = readFileSync(resolve(ROOT, ".github/workflows/release.yml"), "utf8");
  const update = readFileSync(resolve(ROOT, ".github/workflows/update.yml"), "utf8");
  const ci = readFileSync(resolve(ROOT, ".github/workflows/ci.yml"), "utf8");
  const releaseJob = (name, next) =>
    release.slice(
      release.indexOf(`  ${name}:`),
      next ? release.indexOf(`\n  ${next}:`) : release.length,
    );
  const updateJob = (name, next) =>
    update.slice(
      update.indexOf(`  ${name}:`),
      next ? update.indexOf(`\n  ${next}:`) : update.length,
    );

  for (const workflow of [release, update]) {
    assert.match(workflow, /cron: "\d+ \d+ \* \* \*"/, "schedule must run daily");
  }
  assert.match(release, /workflow_run:[\s\S]*workflows: \[CI\][\s\S]*types: \[completed\][\s\S]*branches: \[main\]/);
  const planGate = release.slice(release.indexOf("  plan:"), release.indexOf("    runs-on:", release.indexOf("  plan:")));
  for (const contract of [
    /workflow_run\.conclusion == 'success'/,
    /workflow_run\.event == 'push'/,
    /workflow_run\.head_branch == 'main'/,
    /workflow_run\.head_repository\.full_name == github\.repository/,
  ]) {
    assert.match(planGate, contract);
  }
  assert.doesNotMatch(planGate, /actor|author|dependabot|bot/i);
  const dispatch = release.slice(release.indexOf("  workflow_dispatch:"), release.indexOf("\npermissions:"));
  assert.match(dispatch, /recovery_source_commit:/);
  assert.doesNotMatch(dispatch, /^\s+version:/m, "operators must never enter a version");
  for (const workflow of [release, ci]) {
    assert.match(workflow, /concurrency:[\s\S]{0,100}cancel-in-progress: false/);
  }
  assert.match(release, /git rev-list --first-parent --reverse origin\/main/);
  assert.match(release, /actions\/workflows\/ci\.yml\/runs\?branch=main&event=push&status=completed/);
  assert.match(release, /WAKEUP_SHA: \$\{\{ github\.event\.workflow_run\.head_sha \}\}/);
  assert.match(release, /VERSION: \$\{\{ needs\.plan\.outputs\.version \}\}/);
  assert.match(release, /SOURCE_COMMIT: \$\{\{ needs\.plan\.outputs\.source_commit \}\}/);
  assert.match(release, /legacy_tap_only: \$\{\{ steps\.release-plan\.outputs\.legacy_tap_only \}\}/);
  for (const output of ["backlog_count", "oldest_pending_commit", "oldest_pending_status"]) {
    assert.match(release, new RegExp(`${output}: \\$\\{\\{ steps\\.release-plan\\.outputs\\.${output} \\}\\}`));
  }
  assert.match(
    release,
    /\(\[keys\[\]\] \| sort\) == \["action", "backlog_count", "oldest_pending_commit", "oldest_pending_status", "reason", "source_commit", "version"\]/,
  );
  for (const marker of ["source_sentinel", "dockerfile_sentinel", "formula_sentinel"]) {
    assert.match(release, new RegExp(marker));
  }
  assert.match(release, /if \[\[ "\$action" == resume && "\$version" == 0\.1\.0 &&[\s\S]{0,160}"\$source_commit" == d2a9a8eebcbfa01f3684963998ee1554659c6443 \]\]; then[\s\S]{0,80}legacy_tap_only=true/);

  const legacyPreflight = releaseJob("legacy_preflight", "reserve");
  assert.match(legacyPreflight, /if: needs\.plan\.outputs\.legacy_tap_only == 'true'/);
  assert.match(legacyPreflight, /\.id == 389422097/);
  assert.match(legacyPreflight, /\.immutable == false/);
  assert.match(legacyPreflight, /agentbox-0\.1\.0\.tar\.gz": "sha256:e0d8159d/);
  assert.match(legacyPreflight, /git\/ref\/tags\/v0\.1\.0/);
  assert.doesNotMatch(legacyPreflight, /gh release (?:create|edit|upload)|--method (?:DELETE|PATCH|POST)/);

  const reserve = releaseJob("reserve", "build_image");
  const replan = reserve.indexOf("Recompute the complete cursor immediately before reservation");
  const token = reserve.indexOf("Mint isolated release reservation token");
  const mutation = reserve.indexOf("Create or adopt only the exact draft reservation");
  assert.ok(replan >= 0 && replan < token && token < mutation);
  assert.match(reserve, /EXPECTED_CURSOR_DIGEST: \$\{\{ needs\.plan\.outputs\.cursor_digest \}\}/);
  assert.match(reserve, /test "\$actual_cursor_digest" = "\$EXPECTED_CURSOR_DIGEST"/);
  assert.match(reserve, /git -C \/tmp\/repository rev-list --first-parent FETCH_HEAD \| grep -Fx "\$SOURCE_COMMIT"/);
  const tagPrecheck = reserve.indexOf('git/ref/tags/v$VERSION');
  const createDraft = reserve.indexOf('gh api --method POST "repos/$GITHUB_REPOSITORY/releases"');
  assert.ok(tagPrecheck >= 0 && tagPrecheck < createDraft, "draft tag must be checked before reservation");
  assert.doesNotMatch(reserve, /gh release create/);
  assert.match(reserve, /-f target_commitish="\$SOURCE_COMMIT"/);
  assert.match(reserve, /\.\[0\]\.draft == true[\s\S]{0,180}\.\[0\]\.target_commitish == \$source/);

  const buildImage = releaseJob("build_image", "publish_image");
  assert.match(buildImage, /needs: \[plan, reserve\]/);
  assert.match(buildImage, /if: needs\.reserve\.result == 'success'/);
  assert.match(buildImage, /ref: \$\{\{ needs\.plan\.outputs\.source_commit \}\}/);
  assert.match(buildImage, /push: false/);
  assert.match(buildImage, /outputs: type=oci/);

  const publishImage = releaseJob("publish_image", "verify_image");
  assert.match(publishImage, /packages: write/);
  assert.match(publishImage, /Download inert OCI archive/);
  assert.match(publishImage, /Mint scoped draft read token/);
  assert.match(publishImage, /permission-contents: read/);
  assert.match(publishImage, /RELEASE_TOKEN: \$\{\{ steps\.draft-read-token\.outputs\.token \}\}/);
  assert.match(publishImage, /GH_TOKEN="\$RELEASE_TOKEN" gh api[^\n]*releases/);
  assert.match(publishImage, /Verify exact draft reservation before image mutation/);
  assert.match(publishImage, /Recheck exact reservation immediately before registry mutation/);
  assert.match(publishImage, /\(\$drafts\|length\)==1/);
  assert.doesNotMatch(
    publishImage,
    /steps\.draft-state\.outputs\.asset_count|echo "asset_count=/,
    "registry decisions must not consume an initially captured count",
  );
  assert.match(
    publishImage,
    /DRAFT_ASSET_COUNT=\$\(jq '\.assets \| length' <<<"\$release"\)/,
    "asset count must come from the live snapshot fetch",
  );
  assert.equal(
    publishImage.match(/test "\$DRAFT_ASSET_COUNT" = 0/g)?.length,
    4,
    "missing, absent, mismatched, and pre-delete states must reject partial drafts",
  );
  assert.match(publishImage, /partial draft assets require an exact existing runtime before byte verification/);
  assert.match(publishImage, /refusing image replacement until partial draft assets are byte-verified/);
  assert.doesNotMatch(publishImage, /actions\/checkout|scripts\//);

  const renderJob = releaseJob("render", "publish");
  assert.match(renderJob, /Check out selected source as inert payload/);
  assert.match(renderJob, /Check out successful current release tooling separately/);
  assert.match(renderJob, /ref: \$\{\{ needs\.plan\.outputs\.tooling_commit \}\}/);
  assert.match(renderJob, /tooling\/scripts\/release\.sh[\s\S]{0,100}--source-root "\$GITHUB_WORKSPACE\/source"/);
  assert.match(renderJob, /Transfer inert release bundle to fresh publisher/);

  const publishJob = releaseJob("publish", "post_plan");
  assert.match(publishJob, /!cancelled\(\) && needs\.plan\.outputs\.action != 'noop'/);
  assert.match(publishJob, /needs\.plan\.outputs\.tap_repair_only == 'true'/);
  assert.match(publishJob, /needs\.plan\.outputs\.tap_repair_only != 'true'[\s\S]{0,220}needs\.reserve\.result == 'success'[\s\S]{0,220}needs\.render\.result == 'success'/);
  assert.match(publishJob, /Download inert rendered bundle/);
  assert.match(publishJob, /sha256sum --check transfer\.sha256/);
  assert.match(publishJob, /Complete only the exact reserved draft release/);
  assert.match(publishJob, /test "\$VERSION" != 0\.1\.0/);
  assert.match(publishJob, /verify_cursor_and_draft\(\)/);
  assert.match(publishJob, /actual_assets[\s\S]{0,100}expected_assets/);
  assert.match(publishJob, /actual_digest="sha256:\$\(sha256sum "\/tmp\/base-release\/\$asset"/);
  assert.match(publishJob, /\.agentbox_version==\$version and \.source_commit==\$source/);
  const upload = publishJob.indexOf('gh release upload "v$VERSION"');
  const finalTagCheck = publishJob.indexOf("# The tag may have appeared after upload");
  const publishRelease = publishJob.indexOf('gh release edit "v$VERSION" --draft=false');
  assert.ok(upload >= 0 && upload < finalTagCheck && finalTagCheck < publishRelease);
  assert.match(publishJob, /Download exact published assets for tap-only repair/);
  assert.match(publishJob, /actual_digest="sha256:\$\(sha256sum "dist\/\$asset"/);
  assert.match(publishJob, /cp \.\.\/dist\/source-agentbox\.rb Formula\/agentbox\.rb/);

  for (const name of ["plan", "legacy_preflight", "build_image", "verify_image", "render"]) {
    const next = {
      plan: "legacy_preflight",
      legacy_preflight: "reserve",
      build_image: "publish_image",
      verify_image: "render",
      render: "publish",
    }[name];
    const job = releaseJob(name, next);
    const header = job.slice(0, job.indexOf("    steps:"));
    assert.doesNotMatch(header, /(?:contents|packages|actions): write/, `${name} must be read-only`);
    assert.doesNotMatch(job, /AGENTBOX_APP_PRIVATE_KEY/, `${name} must not receive an App key`);
  }
  for (const [name, next] of [
    ["reserve", "build_image"],
    ["publish_image", "verify_image"],
    ["publish", "post_plan"],
  ]) {
    const job = releaseJob(name, next);
    assert.doesNotMatch(job, /ref: \$\{\{ needs\.plan\.outputs\.source_commit \}\}/);
  }

  const resolveJob = updateJob("resolve", "propose");
  const proposeJob = updateJob("propose");
  assert.match(resolveJob, /scripts\/update-versions\.sh --write --verify-downloads/);
  assert.doesNotMatch(resolveJob, /AGENTBOX_APP_PRIVATE_KEY|contents: write/);
  assert.match(proposeJob, /AGENTBOX_APP_PRIVATE_KEY/);
  assert.match(proposeJob, /Validate base, payload, schema, and exact allowed diff inline/);
  assert.doesNotMatch(proposeJob, /scripts\/update-versions\.sh/);

  const postPlanJob = releaseJob("post_plan", "status");
  assert.match(postPlanJob, /if: always\(\)/);
  assert.match(postPlanJob, /permissions:[\s\S]{0,80}actions: read[\s\S]{0,80}contents: read/);
  assert.doesNotMatch(postPlanJob, /(?:actions|contents|packages): write|AGENTBOX_APP_PRIVATE_KEY/);
  assert.match(postPlanJob, /gh api --paginate --slurp "repos\/\$GITHUB_REPOSITORY\/releases\?per_page=100"/);
  assert.match(postPlanJob, /actions\/workflows\/ci\.yml\/runs\?branch=main&event=push&status=completed/);
  assert.match(postPlanJob, /git\/ref\/tags\/\$tag/);
  for (const marker of ["source_sentinel", "dockerfile_sentinel", "formula_sentinel"]) {
    assert.match(postPlanJob, new RegExp(marker));
  }
  assert.match(postPlanJob, /python3 scripts\/plan-release\.py --releases \/tmp\/releases-bound\.json --commits \/tmp\/commits\.json --ci-runs \/tmp\/ci-runs\.json/);
  for (const output of ["action", "reason", "backlog_count", "oldest_pending_commit", "oldest_pending_status"]) {
    assert.match(postPlanJob, new RegExp(`${output}: \\$\\{\\{ steps\\.live-plan\\.outputs\\.${output} \\}\\}`));
  }

  const statusJob = releaseJob("status");
  assert.match(statusJob, /if: always\(\)/);
  assert.match(statusJob, /actions: write/);
  assert.match(statusJob, /post_plan,/);
  assert.match(statusJob, /INITIAL_BACKLOG_COUNT: \$\{\{ needs\.plan\.outputs\.backlog_count \}\}/);
  assert.match(statusJob, /FINAL_ACTION: \$\{\{ needs\.post_plan\.outputs\.action \}\}/);
  assert.match(statusJob, /FINAL_REASON: \$\{\{ needs\.post_plan\.outputs\.reason \}\}/);
  assert.match(statusJob, /FINAL_BACKLOG_COUNT: \$\{\{ needs\.post_plan\.outputs\.backlog_count \}\}/);
  assert.match(statusJob, /OLDEST_PENDING_COMMIT: \$\{\{ needs\.post_plan\.outputs\.oldest_pending_commit \}\}/);
  assert.match(statusJob, /OLDEST_PENDING_STATUS: \$\{\{ needs\.post_plan\.outputs\.oldest_pending_status \}\}/);
  assert.doesNotMatch(statusJob, /^\s+BACKLOG_COUNT: \$\{\{ needs\.plan\.outputs\.backlog_count \}\}/m);
  for (const field of [
    "initial plan",
    "post-run plan",
    "published cursor",
    "live cursor backlog",
    "jobs",
    "OCI",
    "GitHub release",
    "tap",
  ]) {
    assert.match(statusJob, new RegExp(`\\| ${field.replaceAll(" ", "\\s")} \\|`));
  }
  assert.match(statusJob, /if \[\[ "\$PUBLISH_RESULT" == success && "\$POST_PLAN_RESULT" == success && "\$FINAL_BACKLOG_COUNT" =~ \^\[0-9\]\+\$ \]\]; then/);
  assert.match(statusJob, /if \(\(FINAL_BACKLOG_COUNT > 0\)\); then/);
  assert.doesNotMatch(statusJob, /remaining=|remaining - 1|INITIAL_BACKLOG_COUNT[^\n]*workflow run/);
  assert.match(statusJob, /gh workflow run release\.yml --repo "\$GITHUB_REPOSITORY" --ref main/);
  assert.match(release, /IMMUTABLE_RELEASES_ENABLED: \$\{\{ vars\.IMMUTABLE_RELEASES_ENABLED \}\}/);
  assert.match(release, /test "\$IMMUTABLE_RELEASES_ENABLED" = true/);
  assert.doesNotMatch(release, /gh api[^\n]*immutable-releases/);
  assert.match(release, /\.immutable == true/);
  assert.match(release, /org\.opencontainers\.image\.version=\$\{\{ env\.VERSION \}\}/);
  assert.match(release, /--version "\$VERSION"/);
  assert.match(release, /version = os\.environ\["VERSION"\]/);
  assert.match(release, /packages\/container\/agentbox-runtime\/versions\/\$version_id/);
  assert.doesNotMatch(release, /--method DELETE[^\n]*packages\/container\/agentbox-runtime["']?\s*$/m);
});

test("workflow accepts only unique expected draft asset subsets", async (t) => {
  const workflow = readFileSync(resolve(ROOT, ".github/workflows/release.yml"), "utf8");
  const publishImage = workflow.slice(
    workflow.indexOf("  publish_image:"),
    workflow.indexOf("\n  verify_image:"),
  );
  const match = publishImage.match(
    /jq -e --arg source "\$SOURCE_COMMIT" --arg title "Agentbox v\$VERSION" --arg version "\$VERSION" '\n([\s\S]*?)\n\s+' <<<"\$release"/,
  );
  assert.ok(match, "draft asset validation jq must be present in the image publisher");
  const program = match[1];
  const version = "1.2.3";
  const source = SHA_A;
  const expected = [
    `agentbox-${version}.tar.gz`,
    `agentbox-${version}.tar.gz.sha256`,
    `agentbox-${version}.provenance.json`,
  ];
  const validate = (assets) =>
    run(
      "jq",
      [
        "-e",
        "--arg",
        "source",
        source,
        "--arg",
        "title",
        `Agentbox v${version}`,
        "--arg",
        "version",
        version,
        program,
      ],
      {
        input: JSON.stringify({
          draft: true,
          prerelease: false,
          target_commitish: source,
          name: `Agentbox v${version}`,
          assets: assets.map((name) => ({ name })),
        }),
      },
    );

  for (let mask = 0; mask < 1 << expected.length; mask += 1) {
    const subset = expected.filter((_, index) => mask & (1 << index));
    await t.test(`${subset.length} asset subset ${mask}`, () => {
      expectExit(validate(subset), 0, `draft subset ${JSON.stringify(subset)}`);
    });
  }
  await t.test("duplicate expected asset", () => {
    assert.notEqual(validate([expected[0], expected[0]]).status, 0);
  });
  await t.test("unexpected asset", () => {
    assert.notEqual(validate(["attacker.txt"]).status, 0);
  });
});

test("workflow revalidates canonical draft assets at every registry mutation boundary", () => {
  const workflow = readFileSync(resolve(ROOT, ".github/workflows/release.yml"), "utf8");
  const publishImage = workflow.slice(
    workflow.indexOf("  publish_image:"),
    workflow.indexOf("\n  verify_image:"),
  );
  const snapshotProgram = "[.assets[] | {id, name, digest}] | sort_by(.name, .id)";
  const snapshotLiteral = /\[\.assets\[\] \| \{id, name, digest\}\] \| sort_by\(\.name, \.id\)/g;
  assert.equal(
    publishImage.match(snapshotLiteral)?.length,
    4,
    "initial, post-login, registry-decision, and copy checks must canonicalize full asset identity",
  );
  assert.match(publishImage, /asset_snapshot=\$\(jq -cS[\s\S]{0,140}\| base64 -w0\)/);
  assert.match(publishImage, /echo "asset_snapshot=\$asset_snapshot" >>"\$GITHUB_OUTPUT"/);
  assert.equal(
    publishImage.match(/EXPECTED_DRAFT_ASSET_SNAPSHOT: \$\{\{ steps\.draft-state\.outputs\.asset_snapshot \}\}/g)?.length,
    3,
  );

  const postLogin = publishImage.slice(
    publishImage.indexOf("Recheck exact reservation immediately before registry mutation"),
    publishImage.indexOf("Reuse or narrowly replace existing runtime identity"),
  );
  assert.match(postLogin, /GH_TOKEN="\$RELEASE_TOKEN" gh api --paginate --slurp "repos\/\$GITHUB_REPOSITORY\/releases\?per_page=100"/);
  assert.match(postLogin, /test "\$live_snapshot" = "\$EXPECTED_DRAFT_ASSET_SNAPSHOT"/);

  const registryDecision = publishImage.slice(
    publishImage.indexOf("Reuse or narrowly replace existing runtime identity"),
    publishImage.indexOf("Publish transferred OCI archive"),
  );
  assert.match(registryDecision, /verify_draft_snapshot\(\)[\s\S]*release=\$\(GH_TOKEN="\$RELEASE_TOKEN" gh api "repos\/\$GITHUB_REPOSITORY\/releases\/tags\/v\$VERSION"\)/);
  assert.match(registryDecision, /DRAFT_ASSET_COUNT=\$\(jq '\.assets \| length' <<<"\$release"\)/);
  assert.match(registryDecision, /verify_draft_snapshot[\s\S]{0,100}test "\$DRAFT_ASSET_COUNT" = 0[\s\S]{0,180}gh api --method DELETE/);

  const copy = publishImage.slice(publishImage.indexOf("Publish transferred OCI archive"));
  const copySnapshot = copy.indexOf('test "$live_snapshot" = "$EXPECTED_DRAFT_ASSET_SNAPSHOT"');
  const copyEmpty = copy.indexOf(`test "$(jq '.assets | length' <<<"$release")" = 0`);
  const copyMutation = copy.indexOf("skopeo copy --all");
  assert.ok(
    copySnapshot >= 0 && copySnapshot < copyEmpty && copyEmpty < copyMutation,
    "OCI copy must follow a fresh equal and empty draft snapshot",
  );

  const canonical = (assets) => {
    const result = run("jq", ["-cS", snapshotProgram], {
      input: JSON.stringify({ assets }),
    });
    expectExit(result, 0, "draft snapshot canonicalization");
    return result.stdout;
  };
  const assets = [
    { id: 2, name: "b", digest: `sha256:${"2".repeat(64)}` },
    { id: 1, name: "a", digest: `sha256:${"1".repeat(64)}` },
  ];
  assert.equal(canonical(assets), canonical([...assets].reverse()), "ordering must not change identity");
  for (const changed of [
    [{ ...assets[0], id: 3 }, assets[1]],
    [{ ...assets[0], name: "changed" }, assets[1]],
    [{ ...assets[0], digest: `sha256:${"3".repeat(64)}` }, assets[1]],
    [assets[0]],
    [...assets, { id: 4, name: "c", digest: `sha256:${"4".repeat(64)}` }],
  ]) {
    assert.notEqual(canonical(assets), canonical(changed));
  }
});

test("release runbook documents safe rollout, recovery, and durable verification", () => {
  const readme = readFileSync(resolve(ROOT, "README.md"), "utf8");
  const runbook = readme.slice(readme.indexOf("### Release rollout and recovery runbook"));
  assert.match(runbook, /enable \*\*Immutable releases\*\*/);
  assert.match(runbook, /AGENTBOX_APP_ID/);
  assert.match(runbook, /AGENTBOX_APP_PRIVATE_KEY/);
  assert.match(runbook, /protected `main` requires/);
  assert.match(runbook, /rollout commit must become `v0\.1\.1`/);
  assert.match(runbook, /no-input recovery wakeup[\s\S]{0,100}`noop` plan/);
  assert.match(runbook, /recovery_source_commit=/);
  assert.match(runbook, /cannot skip an older eligible commit/);
  assert.match(runbook, /replace_unpublished_image=true/);
  assert.match(runbook, /repairs or resumes the App-owned tap proposal[\s\S]{0,120}dispatch the requested recovery again/);
  assert.match(runbook, /\.immutable == true/);
  assert.match(runbook, /\.runtime_image \| test\("@sha256:/);
  assert.match(runbook, /git\/ref\/tags\/v\$version/);
  assert.match(runbook, /homebrew-tap\/contents\/Formula\/agentbox\.rb/);
});

test("workflow files are valid YAML", () => {
  for (const path of [
    ".github/workflows/ci.yml",
    ".github/workflows/release.yml",
    ".github/workflows/update.yml",
  ]) {
    expectExit(
      run("ruby", ["-e", "require 'yaml'; YAML.parse_file(ARGV.fetch(0))", path]),
      0,
      `${path} YAML parse`,
    );
  }
});
