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

const INSPECTOR = resolve(ROOT, "scripts/inspect-codex-package.py");
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

function inspect(archive, members) {
  const membersFile = `${archive}.members`;
  writeFileSync(membersFile, members.join("\n") + "\n");
  return run("python3", [
    INSPECTOR,
    archive,
    "--version",
    VERSION,
    "--target",
    TARGET,
    "--members-file",
    membersFile,
  ]);
}

test("safe package inspector accepts metadata without executing payloads", (t) => {
  const dir = tempDir(t);
  const marker = resolve(dir, "executed");
  const payload = `#!/bin/sh\ntouch '${marker}'\n`;
  const members = ["codex-package.json", "bin/codex"];
  const archive = makeArchive(dir, [
    { name: "codex-package.json", data: METADATA },
    { name: "bin/codex", data: payload },
  ]);
  const result = inspect(archive, members);
  expectExit(result, 0, "safe package inspection");
  assert.equal(JSON.parse(result.stdout).members, 2);
  assert.equal(existsSync(marker), false);
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

test("vendor updater changes exactly the four coherent version files", () => {
  const updater = readFileSync(resolve(ROOT, "scripts/update-versions.sh"), "utf8");
  assert.match(updater, /version_file=VERSION/);
  assert.match(updater, /mv "\$tmp_dir\/release-inputs\.json" "\$input"/);
  assert.match(updater, /mv "\$tmp_dir\/VERSION" "\$version_file"/);
  assert.match(updater, /mv "\$tmp_dir\/package\.json" package\.json/);
  assert.match(updater, /mv "\$tmp_dir\/package-lock\.json" package-lock\.json/);
  const workflow = readFileSync(resolve(ROOT, ".github/workflows/update.yml"), "utf8");
  assert.match(
    workflow,
    /expected=\$'VERSION\\npackage-lock\.json\\npackage\.json\\nrelease-inputs\.json'/,
  );
  assert.match(
    workflow,
    /git add -- VERSION package\.json package-lock\.json release-inputs\.json/,
  );
  assert.match(workflow, /expected_author="\$APP_SLUG\[bot\]"/);
  assert.match(workflow, /headRefOid/);
  assert.match(workflow, /--force-with-lease="refs\/heads\/\$branch:\$remote_oid"/);
});

test("updater --write produces a coherent bumped tree", (t) => {
  if (process.env.AGENTBOX_SKIP_NESTED_GATE === "1") {
    const version = readFileSync(resolve(ROOT, "VERSION"), "utf8").trim();
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
      */claude-code-releases/latest) printf '2.1.273\\n' ;;
      */2.1.273/manifest.json)
        printf '%s\\n' '{"buildDate":"","commit":"","manifestSignatureEnforcement":false,"modsCommit":"","platforms":{"linux-arm64":{"binary":"claude","checksum":"${claudeSha}","size":101},"linux-x64":{"binary":"claude","checksum":"${claudeSha}","size":101}},"sdkCompat":{},"version":"2.1.273"}'
        ;;
      */codex/channels/latest)
        printf '%s\\n' '{"assets":[{"browser_download_url":"https://releases.openai.com/codex/releases/0.155.0/codex-package-aarch64-unknown-linux-musl.tar.gz","digest":"sha256:${codexSha}","name":"codex-package-aarch64-unknown-linux-musl.tar.gz"},{"browser_download_url":"https://releases.openai.com/codex/releases/0.155.0/codex-package-x86_64-unknown-linux-musl.tar.gz","digest":"sha256:${codexSha}","name":"codex-package-x86_64-unknown-linux-musl.tar.gz"}],"tag_name":"rust-v0.155.0"}'
        ;;
      *) exit 22 ;;
    esac
    ;;
esac
`,
  );

  const before = readFileSync(resolve(tree, "VERSION"), "utf8").trim();
  const [major, minor, patch] = before.split(".").map(Number);
  const after = `${major}.${minor}.${patch + 1}`;
  const update = run("bash", ["scripts/update-versions.sh", "--write"], {
    cwd: tree,
    env: { PATH: `${fakeBin}:${process.env.PATH}` },
    timeout: 30_000,
  });
  expectExit(update, 0, "fixture updater write");
  assert.equal(readFileSync(resolve(tree, "VERSION"), "utf8"), `${after}\n`);
  assert.equal(JSON.parse(readFileSync(resolve(tree, "release-inputs.json"))).agentbox_version, after);
  assert.equal(JSON.parse(readFileSync(resolve(tree, "package.json"))).version, after);
  const lock = JSON.parse(readFileSync(resolve(tree, "package-lock.json")));
  assert.equal(lock.version, after);
  assert.equal(lock.packages[""].version, after);

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
      timeout: 120_000,
    });
    expectExit(gate, 0, "bumped-tree full gate");
    assert.match(gate.stdout + gate.stderr, /ℹ tests \d+/);
    assert.match(gate.stdout, /npm run lint/);
    assert.match(gate.stdout, /npm run format:check/);
  }
});
