import assert from "node:assert/strict";
import {
  cpSync,
  existsSync,
  mkdirSync,
  readFileSync,
  writeFileSync,
} from "node:fs";
import { resolve } from "node:path";
import test from "node:test";
import {
  ROOT,
  expectExit,
  run,
  tempDir,
  writeExecutable,
} from "./helpers.mjs";
import { CODEX_MEMBERS } from "./fixtures.mjs";

const INSPECTOR = resolve(ROOT, "scripts/inspect-codex-package.py");
// The nested 197-test gate takes about 125 seconds on protected Intel macOS.
const NESTED_FULL_GATE_TIMEOUT_MS = 240_000;
const VERSION = "0.154.0";
const TARGET = "aarch64-unknown-linux-musl";
const METADATA = JSON.stringify({
  entrypoint: "bin/codex",
  layoutVersion: 1,
  pathDir: "codex-path",
  resourcesDir: "codex-resources",
  target: TARGET,
  variant: "codex",
  version: VERSION,
});

function makeArchive(dir, entries, name = "package.tar.gz") {
  const spec = resolve(dir, `${name}.json`);
  const archive = resolve(dir, name);
  writeFileSync(spec, JSON.stringify(entries));
  const builder = [
    "import io,json,pathlib,sys,tarfile",
    "spec=json.loads(pathlib.Path(sys.argv[1]).read_text())",
    "with tarfile.open(sys.argv[2],'w:gz') as out:",
    " for item in spec:",
    "  info=tarfile.TarInfo(item['name'])",
    "  kind=item.get('type','file')",
    "  if kind=='dir': info.type=tarfile.DIRTYPE; info.size=0; out.addfile(info)",
    "  elif kind=='symlink': info.type=tarfile.SYMTYPE; info.linkname=item.get('link','target'); out.addfile(info)",
    "  elif kind=='hardlink': info.type=tarfile.LNKTYPE; info.linkname=item.get('link','target'); out.addfile(info)",
    "  elif kind=='device': info.type=tarfile.CHRTYPE; info.devmajor=1; info.devminor=3; out.addfile(info)",
    "  elif kind=='fifo': info.type=tarfile.FIFOTYPE; out.addfile(info)",
    "  else:",
    "   data=item.get('data','').encode(); info.size=len(data); out.addfile(info,io.BytesIO(data))",
  ].join("\n");
  expectExit(run("python3", ["-c", builder, spec, archive]), 0, "archive builder");
  return archive;
}

function inspect(archive, members = null) {
  const args = [
    INSPECTOR,
    archive,
    "--version",
    VERSION,
    "--target",
    TARGET,
  ];
  if (members !== null) {
    const membersFile = `${archive}.members`;
    writeFileSync(membersFile, members.join("\n") + "\n");
    args.push("--members-file", membersFile);
  }
  return run("python3", args);
}

test("safe package inspector accepts metadata without executing payloads", (t) => {
  const dir = tempDir(t);
  const marker = resolve(dir, "executed");
  const payload = `#!/bin/sh\ntouch '${marker}'\n`;
  const entries = CODEX_MEMBERS.map((name) => ({
    name,
    data: name === "codex-package.json" ? METADATA : name === "bin/codex" ? payload : "fixture",
    type: name.endsWith("/") ? "dir" : "file",
  }));
  const archive = makeArchive(dir, entries);
  const result = inspect(archive, CODEX_MEMBERS);
  expectExit(result, 0, "safe package inspection");
  assert.equal(JSON.parse(result.stdout).members, CODEX_MEMBERS.length);
  assert.equal(existsSync(marker), false);
});

test("safe package inspector discovers canonical package layout evolution", (t) => {
  const dir = tempDir(t);
  const members = [
    ...CODEX_MEMBERS.map((name) => ({
      name,
      data: name === "codex-package.json" ? METADATA : "fixture",
      type: name.endsWith("/") ? "dir" : "file",
    })),
    { name: "codex-resources/voice/", type: "dir" },
    { name: "codex-resources/voice/bin/", type: "dir" },
    { name: "codex-resources/voice/bin/codex-voice-host", data: "voice" },
  ];
  const archive = makeArchive(dir, members);
  const result = inspect(archive);
  expectExit(result, 0, "safe package layout discovery");
  assert.deepEqual(
    JSON.parse(result.stdout).allowed_members,
    members.map((item) => item.name).sort(),
  );

  const outside = makeArchive(
    dir,
    [...members, { name: "unexpected-root/payload", data: "no" }],
    "outside.tar.gz",
  );
  const rejected = inspect(outside);
  assert.notEqual(rejected.status, 0);
  assert.match(rejected.stderr, /outside approved roots/);
});

test("safe package inspector rejects links, devices, FIFOs, and duplicates", async (t) => {
  const badTypes = ["symlink", "hardlink", "device", "fifo"];
  for (const type of badTypes) {
    await t.test(type, () => {
      const dir = tempDir(t);
      const archive = makeArchive(
        dir,
        [
          { name: "codex-package.json", data: METADATA },
          { name: "bin/codex", type },
        ],
        `${type}.tar.gz`,
      );
      assert.notEqual(inspect(archive, ["codex-package.json", "bin/codex"]).status, 0);
    });
  }

  await t.test("duplicate", () => {
    const dir = tempDir(t);
    const archive = makeArchive(
      dir,
      [
        { name: "codex-package.json", data: METADATA },
        { name: "bin/codex", data: "first" },
        { name: "bin/codex", data: "second" },
      ],
      "duplicate.tar.gz",
    );
    assert.notEqual(inspect(archive, ["codex-package.json", "bin/codex"]).status, 0);
  });

  await t.test("noncanonical path", () => {
    const dir = tempDir(t);
    const archive = makeArchive(
      dir,
      [{ name: "./codex-package.json", data: METADATA }],
      "path.tar.gz",
    );
    assert.notEqual(inspect(archive, ["codex-package.json"]).status, 0);
  });
});

test("safe package inspector rejects an oversized member from metadata alone", (t) => {
  const dir = tempDir(t);
  const archive = resolve(dir, "oversize.tar.gz");
  const builder = [
    "import gzip,sys,tarfile",
    "info=tarfile.TarInfo('oversize')",
    "info.size=512*1024*1024+1",
    "with gzip.open(sys.argv[1],'wb') as out:",
    " out.write(info.tobuf())",
    " out.write(b'\\0'*1024)",
  ].join("\n");
  expectExit(run("python3", ["-c", builder, archive]), 0, "oversize archive builder");
  const result = inspect(archive, ["oversize"]);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /too large|size.*limit/i);
});

test("vendor updater inspects downloads but never executes them", () => {
  const source = readFileSync(resolve(ROOT, "scripts/update-versions.sh"), "utf8");
  assert.match(source, /inspect-codex-package\.py/);
  assert.doesNotMatch(source, /\$tmp_dir\/claude-[^\n]*--version/);
  assert.doesNotMatch(source, /\$tmp_dir\/codex-[^\n]*\/bin\/codex[^\n]*--version/);
});

test("vendor updater and workflow allowlist only release-inputs.json", () => {
  const updater = readFileSync(resolve(ROOT, "scripts/update-versions.sh"), "utf8");
  assert.match(updater, /mv "\$tmp_dir\/release-inputs\.json" "\$input"/);
  assert.doesNotMatch(updater, /mv .*\b(?:VERSION|package\.json|package-lock\.json)\b/);
  assert.match(updater, /Claude channel moved backwards/);
  assert.match(updater, /Codex channel moved backwards/);
  assert.match(updater, /metadata changed without a version change/);
  assert.match(updater, /Codex package member sets differ across Linux platforms/);
  assert.match(updater, /\.tools\.codex\.allowed_members = \$codex_members/);
  const workflow = readFileSync(resolve(ROOT, ".github/workflows/update.yml"), "utf8");
  assert.match(workflow, /\(\(\$\{#changed\[@\]\} != 1\)\)/);
  assert.match(workflow, /"\$\{changed\[0\]\}" != release-inputs\.json/);
  assert.match(workflow, /git add -- release-inputs\.json/);
  assert.match(workflow, /branch=automation\/vendor-update/);
  assert.equal(workflow.match(/gh pr list --head "\$branch" --state open/g)?.length, 2);
  assert.doesNotMatch(workflow, /--head "\$GITHUB_REPOSITORY_OWNER:\$branch"/);
  assert.match(workflow, /expected_author="\$APP_SLUG\[bot\]"/);
  assert.match(workflow, /headRefOid/);
  assert.match(workflow, /--force-with-lease="refs\/heads\/\$branch:\$remote_oid"/);
  assert.match(workflow, /del result\["tools"\]\["codex"\]\["allowed_members"\]/);
});

test("updater --write changes only vendor inputs and retains source sentinels", (t) => {
  if (process.env.AGENTBOX_SKIP_NESTED_GATE === "1") {
    const version = readFileSync(resolve(ROOT, "VERSION"), "utf8").trim();
    assert.equal(version, "0.0.0");
    assert.equal(JSON.parse(readFileSync(resolve(ROOT, "release-inputs.json"))).agentbox_version, version);
    assert.equal(JSON.parse(readFileSync(resolve(ROOT, "package.json"))).version, version);
    const lock = JSON.parse(readFileSync(resolve(ROOT, "package-lock.json")));
    assert.equal(lock.version, version);
    assert.equal(lock.packages[""].version, version);
    return;
  }
  const dir = tempDir(t);
  const tree = resolve(dir, "tree");
  cpSync(ROOT, tree, {
    recursive: true,
    filter: (source) =>
      ![".git", ".audit", "dist", "node_modules"].includes(source.split("/").at(-1)),
  });
  const fakeBin = resolve(dir, "bin");
  mkdirSync(fakeBin);
  const curl = resolve(fakeBin, "curl");
  const claudeSha = "1".repeat(64);
  const codexSha = "2".repeat(64);
  const storedInputs = JSON.parse(readFileSync(resolve(tree, "release-inputs.json")));
  const nextPatch = (version) => {
    const parts = version.split(".").map(Number);
    parts[2] += 1;
    return parts.join(".");
  };
  const claudeVersion = nextPatch(storedInputs.tools.claude.version);
  const codexVersion = nextPatch(storedInputs.tools.codex.version);
  writeExecutable(
    curl,
    `#!/bin/bash
url="\${!#}"
case " $* " in
  *" --head "*)
    case "$url" in
      *claude*) size=101 ;;
      *) size=202 ;;
    esac
    printf 'HTTP/2 200\\r\\ncontent-length: %s\\r\\n\\r\\n' "$size"
    ;;
  *)
    case "$url" in
      */claude-code-releases/latest) printf '${claudeVersion}\\n' ;;
      */${claudeVersion}/manifest.json)
        printf '%s\\n' '{"buildDate":"","commit":"","manifestSignatureEnforcement":false,"modsCommit":"","platforms":{"linux-arm64":{"binary":"claude","checksum":"${claudeSha}","size":101},"linux-x64":{"binary":"claude","checksum":"${claudeSha}","size":101}},"sdkCompat":{},"version":"${claudeVersion}"}'
        ;;
      */codex/channels/latest)
        printf '%s\\n' '{"assets":[{"browser_download_url":"https://releases.openai.com/codex/releases/${codexVersion}/codex-package-aarch64-unknown-linux-musl.tar.gz","digest":"sha256:${codexSha}","name":"codex-package-aarch64-unknown-linux-musl.tar.gz"},{"browser_download_url":"https://releases.openai.com/codex/releases/${codexVersion}/codex-package-x86_64-unknown-linux-musl.tar.gz","digest":"sha256:${codexSha}","name":"codex-package-x86_64-unknown-linux-musl.tar.gz"}],"tag_name":"rust-v${codexVersion}"}'
        ;;
      *) exit 22 ;;
    esac
    ;;
esac
`,
  );

  const sourceFiles = ["VERSION", "package.json", "package-lock.json", "Formula/agentbox.rb"];
  const before = new Map(
    sourceFiles.map((path) => [path, readFileSync(resolve(tree, path))]),
  );
  const update = run("bash", ["scripts/update-versions.sh", "--write"], {
    cwd: tree,
    env: { PATH: `${fakeBin}:${process.env.PATH}` },
    timeout: 30_000,
  });
  expectExit(update, 0, "fixture updater write");
  for (const [path, contents] of before) {
    assert.deepEqual(readFileSync(resolve(tree, path)), contents, `${path} changed`);
  }
  const inputs = JSON.parse(readFileSync(resolve(tree, "release-inputs.json")));
  assert.equal(inputs.agentbox_version, "0.0.0");
  assert.equal(inputs.tools.claude.version, claudeVersion);
  assert.equal(inputs.tools.codex.version, codexVersion);
  assert.equal(JSON.parse(readFileSync(resolve(tree, "package.json"))).version, "0.0.0");
  const lock = JSON.parse(readFileSync(resolve(tree, "package-lock.json")));
  assert.equal(lock.version, "0.0.0");
  assert.equal(lock.packages[""].version, "0.0.0");

  if (process.env.AGENTBOX_SKIP_NESTED_GATE !== "1") {
    expectExit(run("git", ["init", "-q"], { cwd: tree }), 0, "fixture git init");
    expectExit(run("git", ["add", "."], { cwd: tree }), 0, "fixture git add");
    expectExit(
      run("git", ["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-qm", "fixture"], { cwd: tree }),
      0,
      "fixture git commit",
    );
    expectExit(run("npm", ["ci", "--ignore-scripts"], { cwd: tree, timeout: 30_000 }), 0, "fixture npm ci");
    const gate = run("make", ["check"], {
      cwd: tree,
      env: {
        AGENTBOX_SKIP_NESTED_GATE: "1",
        NODE_TEST_CONTEXT: null,
      },
      timeout: NESTED_FULL_GATE_TIMEOUT_MS,
    });
    expectExit(gate, 0, "bumped-tree full gate");
    assert.match(gate.stdout + gate.stderr, /ℹ tests \d+/);
    assert.match(gate.stdout, /npm run lint/);
    assert.match(gate.stdout, /npm run format:check/);
  }
});

test("updater fails closed on vendor downgrades and same-version record drift", async (t) => {
  for (const fixture of [
    {
      label: "downgrade",
      claude: "2.1.271",
      codex: "0.153.0",
      error: /channel moved backwards/,
    },
    {
      label: "same-version drift",
      error: /metadata changed without a version change/,
    },
  ]) {
    await t.test(fixture.label, (t) => {
      const dir = tempDir(t);
      const tree = resolve(dir, "tree");
      cpSync(ROOT, tree, {
        recursive: true,
        filter: (source) =>
          ![".git", ".audit", "dist", "node_modules"].includes(source.split("/").at(-1)),
      });
      const stored = JSON.parse(readFileSync(resolve(tree, "release-inputs.json")));
      const claudeVersion = fixture.claude ?? stored.tools.claude.version;
      const codexVersion = fixture.codex ?? stored.tools.codex.version;
      const storedClaudeSha = stored.tools.claude.platforms[0].sha256;
      const driftSha = storedClaudeSha === "1".repeat(64) ? "4".repeat(64) : "1".repeat(64);
      const fakeBin = resolve(dir, "bin");
      mkdirSync(fakeBin);
      writeExecutable(
        resolve(fakeBin, "curl"),
        `#!/bin/bash
url="\${!#}"
case " $* " in
  *" --head "*)
    case "$url" in *claude*) size=101 ;; *) size=202 ;; esac
    printf 'HTTP/2 200\\r\\ncontent-length: %s\\r\\n\\r\\n' "$size"
    ;;
  *)
    case "$url" in
      */claude-code-releases/latest) printf '${claudeVersion}\\n' ;;
      */${claudeVersion}/manifest.json)
        printf '%s\\n' '{"buildDate":"","commit":"","manifestSignatureEnforcement":false,"modsCommit":"","platforms":{"linux-arm64":{"binary":"claude","checksum":"${driftSha}","size":101},"linux-x64":{"binary":"claude","checksum":"${driftSha}","size":101}},"sdkCompat":{},"version":"${claudeVersion}"}'
        ;;
      */codex/channels/latest)
        printf '%s\\n' '{"assets":[{"browser_download_url":"https://releases.openai.com/codex/releases/${codexVersion}/codex-package-aarch64-unknown-linux-musl.tar.gz","digest":"sha256:${"2".repeat(64)}","name":"codex-package-aarch64-unknown-linux-musl.tar.gz"},{"browser_download_url":"https://releases.openai.com/codex/releases/${codexVersion}/codex-package-x86_64-unknown-linux-musl.tar.gz","digest":"sha256:${"2".repeat(64)}","name":"codex-package-x86_64-unknown-linux-musl.tar.gz"}],"tag_name":"rust-v${codexVersion}"}'
        ;;
      *) exit 22 ;;
    esac
    ;;
esac
`,
      );
      const inputPath = resolve(tree, "release-inputs.json");
      const before = readFileSync(inputPath);
      const result = run("bash", ["scripts/update-versions.sh", "--write"], {
        cwd: tree,
        env: { PATH: `${fakeBin}:${process.env.PATH}` },
      });
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, fixture.error);
      assert.deepEqual(readFileSync(inputPath), before);
    });
  }
});
