import assert from "node:assert/strict";
import { existsSync, mkdirSync, readFileSync, unlinkSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import test from "node:test";
import { AGENTBOX_VERSION, canonical, sha256 } from "./fixtures.mjs";
import {
  ROOT,
  expectExit,
  readNul,
  run,
  tempDir,
  writeExecutable,
} from "./helpers.mjs";

const RUNTIME = resolve(ROOT, "runtime/runtime");
const SHARE = resolve(ROOT, "runtime");
const MEMBERS = [
  "bin/",
  "bin/codex",
  "bin/codex-code-mode-host",
  "codex-package.json",
  "codex-path/",
  "codex-path/rg",
  "codex-resources/",
  "codex-resources/bwrap",
  "codex-resources/zsh/",
  "codex-resources/zsh/bin/",
  "codex-resources/zsh/bin/zsh",
];

function runtime(args, options = {}) {
  return run("python3", [RUNTIME, ...args], options);
}

function recordingVendor() {
  return `#!/bin/sh
if [ "$1" = "--version" ]; then
  case "$0" in *claude*) echo "2.1.272 (Claude Code)" ;; *) echo "codex-cli 0.154.0" ;; esac
  exit 0
fi
if [ "$1" = "--help" ]; then echo "fake help"; exit 0; fi
: "$RECORD"
printf '%s\\0' "$@" > "$RECORD.argv"
{
  printf 'HOME=%s\\n' "$HOME"
  printf 'PATH=%s\\n' "$PATH"
  printf 'DISABLE_UPDATES=%s\\n' "$DISABLE_UPDATES"
  printf 'DISABLE_AUTOUPDATER=%s\\n' "$DISABLE_AUTOUPDATER"
} > "$RECORD.env"
exit "$FAKE_EXIT"
`;
}

function makeVendorTree(dir) {
  const root = resolve(dir, "vendor");
  mkdirSync(resolve(root, "claude"), { recursive: true });
  mkdirSync(resolve(root, "codex", "bin"), { recursive: true });
  mkdirSync(resolve(root, "codex", "codex-path"), { recursive: true });
  writeExecutable(resolve(root, "claude", "claude"), recordingVendor());
  writeExecutable(resolve(root, "codex", "bin", "codex"), recordingVendor());
  return root;
}

function protocolManifest(claude, codex) {
  const instructions = readFileSync(resolve(SHARE, "instructions.md"));
  const statusline = readFileSync(resolve(SHARE, "statusline.sh"));
  const artifact = (bytes) => ({ sha256: sha256(bytes), size: bytes.length });
  return {
    schema_version: 1,
    agentbox_version: AGENTBOX_VERSION,
    runtime_protocol_version: 1,
    runtime: {
      image: `ghcr.io/zurfyx/agentbox-runtime@sha256:${"a".repeat(64)}`,
    },
    tools: {
      claude: {
        kind: "raw-executable",
        version: "2.1.272",
        platforms: [
          {
            platform: "linux/arm64",
            url: "https://downloads.claude.ai/claude-code-releases/2.1.272/linux-arm64/claude",
            ...artifact(claude),
          },
          {
            platform: "linux/amd64",
            url: "https://downloads.claude.ai/claude-code-releases/2.1.272/linux-x64/claude",
            ...artifact(claude),
          },
        ],
      },
      codex: {
        kind: "tar.gz-package",
        layout_version: 1,
        entrypoint: "bin/codex",
        allowed_members: MEMBERS,
        version: "0.154.0",
        platforms: [
          {
            platform: "linux/arm64",
            target: "aarch64-unknown-linux-musl",
            url: "https://releases.openai.com/codex/releases/0.154.0/codex-package-aarch64-unknown-linux-musl.tar.gz",
            ...artifact(codex),
          },
          {
            platform: "linux/amd64",
            target: "x86_64-unknown-linux-musl",
            url: "https://releases.openai.com/codex/releases/0.154.0/codex-package-x86_64-unknown-linux-musl.tar.gz",
            ...artifact(codex),
          },
        ],
      },
    },
    managed_files: {
      runtime_instructions: {
        path: "/usr/local/share/agentbox/instructions.md",
        sha256: sha256(instructions),
      },
      statusline: {
        path: "/usr/local/share/agentbox/statusline.sh",
        sha256: sha256(statusline),
      },
    },
  };
}

function makeProtocolFixture(t) {
  const dir = tempDir(t);
  const downloads = resolve(dir, "downloads");
  const archiveRoot = resolve(dir, "archive");
  mkdirSync(downloads);
  for (const member of MEMBERS) {
    const path = resolve(archiveRoot, member);
    if (member.endsWith("/")) {
      mkdirSync(path, { recursive: true });
      continue;
    }
    mkdirSync(resolve(path, ".."), { recursive: true });
    if (member === "bin/codex") writeExecutable(path, recordingVendor());
    else writeFileSync(path, member === "codex-package.json" ? "{}\n" : "fake\n");
  }
  const claude = Buffer.from(recordingVendor());
  writeFileSync(resolve(downloads, "claude"), claude);
  const archive = resolve(downloads, "codex.tar.gz");
  const archiveScript = [
    "import pathlib,sys,tarfile",
    "root,archive=map(pathlib.Path,sys.argv[1:3])",
    "with tarfile.open(archive,'w:gz') as output:",
    " for name in sys.argv[3:]: output.add(root/name.rstrip('/'),arcname=name.rstrip('/'),recursive=False)",
  ].join("\n");
  expectExit(
    run("python3", ["-c", archiveScript, archiveRoot, archive, ...MEMBERS]),
    0,
    "fixture archive",
  );
  const codex = readFileSync(archive);
  const manifest = resolve(dir, "manifest.json");
  writeFileSync(manifest, canonical(protocolManifest(claude, codex)));
  return { dir, downloads, manifest };
}

test("runtime run preserves argv and applies mode policy", async (t) => {
  const dir = tempDir(t);
  const vendor = makeVendorTree(dir);
  const user = ["argument with spaces", "", "line one\nline two", "--literal"];
  const cases = [
    ["claude", []],
    ["clauded", ["--dangerously-skip-permissions"]],
    ["codex", ["--dangerously-bypass-approvals-and-sandbox"]],
  ];

  for (const [mode, required] of cases) {
    await t.test(mode, () => {
      const record = resolve(dir, mode);
      const result = runtime(
        ["run", "--protocol", "1", "--mode", mode, "--release", AGENTBOX_VERSION, "--", ...user],
        {
          env: {
            AGENTBOX_INTERNAL_TESTING: "1",
            AGENTBOX_TEST_RELEASE_ROOT: vendor,
            AGENTBOX_TEST_SHARE_ROOT: SHARE,
            RECORD: record,
            FAKE_EXIT: "37",
          },
        },
      );
      expectExit(result, 37, `runtime ${mode}`);
      const argv = readNul(`${record}.argv`);
      assert.deepEqual(argv.slice(-user.length), user);
      for (const flag of required) assert.ok(argv.includes(flag), `${mode} lacks ${flag}`);
      const environment = readFileSync(`${record}.env`, "utf8");
      assert.match(environment, /^HOME=\/home\/node$/m);
      assert.match(environment, /^DISABLE_UPDATES=1$/m);
      assert.match(environment, /^DISABLE_AUTOUPDATER=1$/m);
      const pathLine = environment.split("\n").find((line) => line.startsWith("PATH="));
      assert.ok(pathLine?.startsWith(`PATH=${vendor}/codex/bin:`));
    });
  }
});

test("runtime rejects vendor updater and unsupported login before exec", (t) => {
  const dir = tempDir(t);
  const vendor = makeVendorTree(dir);
  const env = {
    AGENTBOX_INTERNAL_TESTING: "1",
    AGENTBOX_TEST_RELEASE_ROOT: vendor,
    AGENTBOX_TEST_SHARE_ROOT: SHARE,
    RECORD: resolve(dir, "must-not-run"),
  };
  for (const [mode, args] of [
    ["claude", ["update"]],
    ["clauded", ["install"]],
    ["codex", ["remote-control"]],
    ["codex", ["login"]],
  ]) {
    const result = runtime(
      ["run", "--protocol", "1", "--mode", mode, "--release", AGENTBOX_VERSION, "--", ...args],
      { env },
    );
    expectExit(result, 2, `rejected ${mode} ${args.join(" ")}`);
  }
});

test("prepare verifies bytes, safely extracts, and emits canonical content", (t) => {
  const fixture = makeProtocolFixture(t);
  const candidate = resolve(fixture.dir, "candidate");
  const result = runtime([
    "prepare", "--protocol", "1", "--platform", "linux/arm64",
    "--manifest", fixture.manifest, "--downloads", fixture.downloads, "--output", candidate,
  ]);
  expectExit(result, 0, "runtime prepare");
  const output = JSON.parse(result.stdout);
  assert.deepEqual(Object.keys(output), ["content_sha256", "ok", "protocol"]);
  assert.equal(output.ok, true);
  assert.match(output.content_sha256, /^sha256:[0-9a-f]{64}$/);
  assert.equal(readFileSync(resolve(candidate, "codex", "codex-package.json"), "utf8"), "{}\n");
  assert.equal(readFileSync(resolve(candidate, "content.json"), "utf8").endsWith("\n"), true);
});

test("prepare and validate honor agent scope and can enrich from verified content", (t) => {
  const fixture = makeProtocolFixture(t);
  const claudeOnly = resolve(fixture.dir, "claude-only");
  expectExit(runtime([
    "prepare", "--protocol", "1", "--platform", "linux/arm64", "--agent", "claude",
    "--manifest", fixture.manifest, "--downloads", fixture.downloads, "--output", claudeOnly,
  ]), 0, "Claude-only prepare");
  assert.ok(existsSync(resolve(claudeOnly, "claude/claude")));
  assert.equal(existsSync(resolve(claudeOnly, "codex")), false);
  expectExit(runtime([
    "validate", "--protocol", "1", "--platform", "linux/arm64", "--agent", "claude",
    "--manifest", fixture.manifest, "--candidate", claudeOnly,
  ], { env: { AGENTBOX_INTERNAL_TESTING: "1", AGENTBOX_TEST_SHARE_ROOT: SHARE } }), 0, "Claude-only validate");
  expectExit(runtime([
    "validate", "--protocol", "1", "--platform", "linux/arm64", "--agent", "codex",
    "--manifest", fixture.manifest, "--candidate", claudeOnly,
  ], { env: { AGENTBOX_INTERNAL_TESTING: "1", AGENTBOX_TEST_SHARE_ROOT: SHARE } }), 1, "missing Codex validate");

  unlinkSync(resolve(fixture.downloads, "claude"));
  const enriched = resolve(fixture.dir, "enriched");
  expectExit(runtime([
    "prepare", "--protocol", "1", "--platform", "linux/arm64", "--agent", "all",
    "--manifest", fixture.manifest, "--downloads", fixture.downloads, "--reuse", claudeOnly,
    "--output", enriched,
  ]), 0, "enriched prepare");
  assert.deepEqual(
    readFileSync(resolve(enriched, "claude/claude")),
    readFileSync(resolve(claudeOnly, "claude/claude")),
  );
  assert.ok(existsSync(resolve(enriched, "codex/bin/codex")));
});

test("prepare rejects a digest mismatch without publishing output", (t) => {
  const fixture = makeProtocolFixture(t);
  writeFileSync(resolve(fixture.downloads, "claude"), "tampered");
  const candidate = resolve(fixture.dir, "candidate");
  const result = runtime([
    "prepare", "--protocol", "1", "--platform", "linux/arm64",
    "--manifest", fixture.manifest, "--downloads", fixture.downloads, "--output", candidate,
  ]);
  expectExit(result, 2, "tampered prepare");
  assert.throws(() => readFileSync(resolve(candidate, "content.json")));
});

test("validate checks versions, layout, instructions, and status line", (t) => {
  const fixture = makeProtocolFixture(t);
  const candidate = resolve(fixture.dir, "candidate");
  expectExit(
    runtime([
      "prepare", "--protocol", "1", "--platform", "linux/arm64",
      "--manifest", fixture.manifest, "--downloads", fixture.downloads, "--output", candidate,
    ]),
    0,
    "prepare before validate",
  );
  const result = runtime(
    [
      "validate", "--protocol", "1", "--platform", "linux/arm64",
      "--manifest", fixture.manifest, "--candidate", candidate,
    ],
    {
      env: {
        AGENTBOX_INTERNAL_TESTING: "1",
        AGENTBOX_TEST_SHARE_ROOT: SHARE,
      },
    },
  );
  expectExit(result, 0, "runtime validate");
  const output = JSON.parse(result.stdout);
  assert.equal(output.ok, true);
  assert.deepEqual(Object.values(output.assertions), Array(8).fill(true));
});
