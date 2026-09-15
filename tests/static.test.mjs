import assert from "node:assert/strict";
import {
  chmodSync,
  copyFileSync,
  existsSync,
  mkdirSync,
  readFileSync,
  statSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { resolve } from "node:path";
import test from "node:test";
import { ROOT, expectExit, run, tempDir, writeExecutable } from "./helpers.mjs";

const read = (path) => readFileSync(resolve(ROOT, path), "utf8");
const VERSION = read("VERSION").trim();

test("distribution entry points and hooks are executable", () => {
  for (const path of [
    "bin/agentbox",
    "libexec/host.sh",
    "runtime/runtime",
    ".husky/pre-commit",
    "tests/check-shell.sh",
    "tests/check-format.mjs",
  ]) {
    assert.ok(existsSync(resolve(ROOT, path)), `${path} is missing`);
    assert.ok(statSync(resolve(ROOT, path)).mode & 0o111, `${path} is not executable`);
  }
});

test("launcher resolves the Homebrew bin symlink before locating libexec", (t) => {
  const dir = tempDir(t);
  const keg = resolve(dir, "Cellar/agentbox/0.1.0");
  mkdirSync(resolve(keg, "bin"), { recursive: true });
  mkdirSync(resolve(keg, "libexec/agentbox"), { recursive: true });
  mkdirSync(resolve(keg, "share/agentbox"), { recursive: true });
  mkdirSync(resolve(dir, "bin"), { recursive: true });
  copyFileSync(resolve(ROOT, "bin/agentbox"), resolve(keg, "bin/agentbox"));
  copyFileSync(resolve(ROOT, "libexec/host.sh"), resolve(keg, "libexec/agentbox/host.sh"));
  copyFileSync(resolve(ROOT, "libexec/state.py"), resolve(keg, "libexec/agentbox/state.py"));
  writeFileSync(resolve(keg, "share/agentbox/VERSION"), `${VERSION}\n`);
  symlinkSync("../Cellar/agentbox/0.1.0/bin/agentbox", resolve(dir, "bin/agentbox"));
  const result = run(resolve(dir, "bin/agentbox"), ["--version"]);
  expectExit(result, 0, "Homebrew-style symlink launch");
  assert.equal(result.stdout.trim(), `agentbox ${VERSION}`);
});

test("all authored shell and Python programs parse", () => {
  const shellFiles = [
    "bin/agentbox",
    "libexec/host.sh",
    "agentbox.sh",
    "install.sh",
    "git-credential-ghtoken",
    "onhost",
    "setup-host-bridge.sh",
  ].filter((path) => existsSync(resolve(ROOT, path)));
  for (const path of shellFiles) {
    expectExit(run("bash", ["-n", path]), 0, `bash -n ${path}`);
  }
  for (const path of [
    "libexec/state.py",
    "runtime/runtime",
    "scripts/inspect-codex-package.py",
  ]) {
    if (!existsSync(resolve(ROOT, path))) continue;
    expectExit(
      run("python3", ["-c", "import pathlib,sys; p=pathlib.Path(sys.argv[1]); compile(p.read_bytes(), str(p), 'exec')", path]),
      0,
      `${path} compilation`,
    );
  }
});

test("make help documents the supported developer targets", () => {
  const result = run("make", ["help"]);
  expectExit(result, 0, "make help");
  for (const target of ["check", "test", "lint", "format-check", "docker-build"]) {
    assert.match(result.stdout, new RegExp(`^  ${target}\\s`, "m"));
  }
});

test("one VERSION authority drives source metadata and release packaging", (t) => {
  const rawVersion = read("VERSION");
  const version = rawVersion.trim();
  assert.match(version, /^[0-9]+\.[0-9]+\.[0-9]+$/);
  assert.equal(rawVersion, `${version}\n`);
  assert.equal(JSON.parse(read("release-inputs.json")).agentbox_version, version);
  assert.equal(JSON.parse(read("package.json")).version, version);
  const lock = JSON.parse(read("package-lock.json"));
  assert.equal(lock.version, version);
  assert.equal(lock.packages[""].version, version);

  const cliVersion = run(resolve(ROOT, "bin/agentbox"), ["--version"]);
  expectExit(cliVersion, 0, "source --version");
  assert.equal(cliVersion.stdout, `agentbox ${version}\n`);

  const copy = tempDir(t);
  mkdirSync(resolve(copy, "bin"));
  mkdirSync(resolve(copy, "libexec"));
  for (const path of ["bin/agentbox", "libexec/host.sh", "libexec/state.py"]) {
    copyFileSync(resolve(ROOT, path), resolve(copy, path));
  }
  chmodSync(resolve(copy, "bin/agentbox"), 0o755);
  writeFileSync(resolve(copy, "VERSION"), "9.8.7\n");
  const copiedVersion = run(resolve(copy, "bin/agentbox"), ["--version"]);
  expectExit(copiedVersion, 0, "copied source --version");
  assert.equal(copiedVersion.stdout, "agentbox 9.8.7\n");

  const release = read("scripts/release.sh");
  assert.match(release, /install -m 0444 VERSION "\$root\/VERSION"/);
  assert.match(release, /install -m 0444 VERSION "\$root\/share\/agentbox\/VERSION"/);
  assert.match(release, /--expected-version "\$version" validate-manifest/);
  const dryRun = run("bash", ["scripts/release.sh", "--dry-run"]);
  expectExit(dryRun, 0, "release dry run");
  assert.match(dryRun.stdout, new RegExp(`agentbox-${version}\\.tar\\.gz`));
});

test("host bridge is packaged and derives installed identity and account home", (t) => {
  const bridge = read("setup-host-bridge.sh");
  assert.match(bridge, /"\$AGENTBOX_BIN" info --json/);
  assert.match(bridge, /\.current\.runtime_image/);
  assert.match(bridge, /--dev-image/);
  assert.match(bridge, /image environment overrides are unsupported/);
  assert.doesNotMatch(bridge, /IMAGE="\$\{AGENTBOX_(?:RUNTIME_)?IMAGE/);
  assert.match(bridge, /ACCOUNT_HOME=.*(?:dscl|dscacheutil)/);
  assert.match(bridge, /PERSONAL_HOME="\$ACCOUNT_HOME\/\.agentbox"/);
  assert.match(bridge, /AGENTBOX_HOME is supported only with --dev-image/);

  const dir = tempDir(t);
  const fakeBin = resolve(dir, "bin");
  mkdirSync(fakeBin);
  writeExecutable(resolve(fakeBin, "id"), "#!/bin/sh\nprintf 'fixture-user\\n'\n");
  writeExecutable(
    resolve(fakeBin, "dscl"),
    "#!/bin/sh\nprintf 'NFSHomeDirectory: /os/account\\n'\n",
  );
  const rejected = run("bash", ["setup-host-bridge.sh"], {
    env: {
      AGENTBOX_HOME: resolve(dir, "attacker-home"),
      HOME: resolve(dir, "ambient-home"),
      OSTYPE: "darwin-test",
      PATH: `${fakeBin}:/usr/bin:/bin`,
    },
  });
  assert.notEqual(rejected.status, 0);
  assert.match(rejected.stderr, /AGENTBOX_HOME is supported only with --dev-image/);
  assert.equal(existsSync(resolve(dir, "attacker-home")), false);
  assert.equal(existsSync(resolve(dir, "ambient-home")), false);

  const formula = read("Formula/agentbox.rb");
  assert.match(formula, /setup-host-bridge\.sh/);
  assert.match(formula, /agentbox-host-bridge/);
  const release = read("scripts/release.sh");
  assert.match(release, /required_files=\([\s\S]*setup-host-bridge\.sh/);
  assert.match(release, /install -m 0555 setup-host-bridge\.sh "\$root\/setup-host-bridge\.sh"/);
});

test("host consumes one integrity-checked launch tuple", () => {
  const host = read("libexec/host.sh");
  assert.match(host, /pwd\.getpwuid\(os\.getuid\(\)\)\.pw_dir/);
  assert.doesNotMatch(host, /SOURCE_CHECKOUT == 0[\s\S]{0,300}\$HOME\/\.agentbox/);
  const launch = host.slice(host.indexOf("launch_agent()"), host.indexOf("\nmain()"));
  assert.match(launch, /run_state launch-plan --root "\$root"/);
  assert.doesNotMatch(launch, /current-field/);

  const state = read("libexec/state.py");
  assert.match(state, /timeout\s*=\s*180/);
  assert.match(state, /timeout(?:: int)?\s*=\s*900/);
  assert.match(state, /managed root must be on a local APFS filesystem/);
});

test("release workflow smokes the exact entrypoint with step-scoped tokens", () => {
  const workflow = read(".github/workflows/release.yml");
  assert.match(workflow, /Smoke the exact runtime entrypoint on both platforms/);
  assert.match(
    workflow,
    /docker run --rm --platform linux\/amd64[\s\\]*"\$IMAGE@\$\{\{ steps\.identities\.outputs\.amd64 \}\}" --help/,
  );
  assert.match(
    workflow,
    /docker run --rm --platform linux\/arm64[\s\\]*"\$IMAGE@\$\{\{ steps\.identities\.outputs\.arm64 \}\}" --help/,
  );
  const jobHeader = workflow.slice(
    workflow.indexOf("  publish:"),
    workflow.indexOf("    steps:"),
  );
  assert.doesNotMatch(jobHeader, /GH_TOKEN|GITHUB_TOKEN|APP_PRIVATE_KEY/);
  assert.match(workflow, /GH_TOKEN: \$\{\{ github\.token \}\}/);
  assert.match(workflow, /GH_TOKEN: \$\{\{ steps\.tap-token\.outputs\.token \}\}/);
  assert.match(workflow, /replace_unpublished_image:/);
  assert.match(workflow, /metadata differs beyond revision/);
  assert.match(workflow, /refusing to replace a package that carries another tag/);
  assert.match(workflow, /releases\/tags\/v\$VERSION/);
  assert.match(workflow, /gh api --method DELETE/);
  assert.match(workflow, /\.name == "required" and \.app\.slug == "github-actions"/);
  assert.match(workflow, /--match-head-commit "\$head"/);

  const updater = read(".github/workflows/update.yml");
  assert.match(updater, /\.name == "required" and \.app\.slug == "github-actions"/);
  assert.match(updater, /--match-head-commit "\$head"/);
});

test("the public image is payload-free and non-root", () => {
  const dockerfile = read("Dockerfile");
  assert.doesNotMatch(
    dockerfile,
    /npm\s+(?:i|install).*(?:@anthropic-ai\/claude-code|@openai\/codex)/i,
  );
  assert.doesNotMatch(dockerfile, /COPY\s+.*(?:claude|codex).*(?:\/usr\/local\/bin|\/opt)/i);
  assert.match(dockerfile, /^USER\s+(?!root\b)\S+/m);
  assert.match(dockerfile, /runtime/);
});

test("completions are static data, never launcher execution", () => {
  for (const path of [
    "completions/agentbox.bash",
    "completions/_agentbox",
    "completions/agentbox.fish",
  ]) {
    if (!existsSync(resolve(ROOT, path))) continue;
    const source = read(path);
    assert.doesNotMatch(source, /\$\([^)]*agentbox|`[^`]*agentbox/);
  }
});

test("the fast hook stays local and CI remains the full check", () => {
  const hook = read(".husky/pre-commit");
  assert.match(hook, /npm run precommit/);
  assert.doesNotMatch(hook, /docker|brew|npm ci|format:check/);

  const pkg = JSON.parse(read("package.json"));
  assert.equal(pkg.scripts.prepare, "husky");
  assert.match(pkg.scripts.precommit, /test:unit/);
  assert.match(pkg.scripts.check, /npm run test/);
  assert.match(pkg.scripts.check, /npm run lint/);
  assert.match(pkg.scripts.check, /npm run format:check/);
});

test("workflow actions are immutable when workflows are present", () => {
  const result = run("git", [
    "ls-files",
    "-co",
    "--exclude-standard",
    "--",
    ".github/workflows/*.yml",
    ".github/workflows/*.yaml",
  ]);
  expectExit(result, 0, "workflow listing");
  for (const path of result.stdout.trim().split("\n").filter(Boolean)) {
    for (const line of read(path).split("\n")) {
      const match = line.match(/\buses:\s*[^@\s]+@([^\s#]+)/);
      if (match) assert.match(match[1], /^[0-9a-f]{40}$/, `${path}: ${line.trim()}`);
    }
  }
});
