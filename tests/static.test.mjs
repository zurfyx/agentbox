import assert from "node:assert/strict";
import { createHash } from "node:crypto";
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
import { dirname, resolve } from "node:path";
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

test("README presents trusted install and direct first use", () => {
  const readme = read("README.md");
  const gettingStarted = readme.slice(
    readme.indexOf("## Install and run"),
    readme.indexOf("## Learn more"),
  );
  const trust = gettingStarted.indexOf("brew trust zurfyx/tap");
  const install = gettingStarted.indexOf("brew install zurfyx/tap/agentbox");
  const claude = gettingStarted.indexOf("agentbox claude", install);
  const codex = gettingStarted.indexOf("agentbox codex", install);

  assert.ok(trust >= 0, "README must document trusting the tap");
  assert.ok(install > trust, "tap trust must precede installation");
  assert.match(
    gettingStarted,
    /```sh\nbrew trust zurfyx\/tap\nbrew install zurfyx\/tap\/agentbox\n```[\s\S]*```sh\nagentbox claude\nagentbox codex\n```/,
    "fresh install must resolve the trusted tap before direct agent launch",
  );
  assert.doesNotMatch(gettingStarted, /^brew install agentbox$/m);
  assert.ok(claude > install, "Claude must be directly launchable after installation");
  assert.ok(codex > install, "Codex must be directly launchable after installation");
  assert.doesNotMatch(gettingStarted, /agentbox (?:setup|doctor)/);
  assert.doesNotMatch(readme, /npm ci|scripts\/dev\.sh|Release rollout and recovery runbook/);
});

test("workspace-only documentation states the exact grammar and remaining authority", () => {
  const readme = read("README.md");
  const usage = read("docs/usage.md");
  const security = read("docs/security.md");
  const instructions = read("runtime/instructions.md");
  const publicDocs = `${readme}\n${usage}\n${security}`;

  assert.match(
    usage,
    /agentbox \[--workspace-only\] \[--no-update\] \[claude\|clauded\|codex\] \[--\] \[ARG \.\.\.\]/,
  );
  assert.match(usage, /Each may appear at most once, and they may appear in either order/);
  assert.match(usage, /selector, `--`, or the first unknown[\s\S]*forwarded unchanged/);
  assert.match(usage, /agentbox codex --workspace-only` passes the flag to\s+Codex/);
  assert.match(usage, /Global Agentbox flags do not apply\s+to lifecycle commands/);
  assert.match(usage, /`help`, `-h`, `--help`, and `--version` are\s+early-exit exceptions/);
  assert.match(usage, /accepted after either or both global options/);

  for (const expected of [
    "agentbox --workspace-only claude",
    "agentbox --workspace-only codex",
    "canonical Git worktree",
    "physical current directory",
    "standard linked worktree",
    "common Git directory",
    "external object alternates",
    "submodule selected as the workspace root",
    "persistent vendor home",
    "OPENAI_API_KEY",
    "network access",
    "hostile-code sandbox",
  ]) {
    assert.match(publicDocs, new RegExp(expected.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
  }

  assert.match(security, /objects, refs, hooks, configuration, and sibling-worktree metadata/);
  assert.match(security, /not[\s\S]{0,40}broadly mounted/);
  assert.match(security, /neither obtain nor receive this token/);
  assert.match(security, /Launches without the\s+flag retain the normal behavior/);
  assert.match(instructions, /Workspace-only sessions omit the broad host mounts/);
  assert.match(instructions, /still have network access/);
  assert.match(instructions, /persistent vendor home/);
  assert.match(instructions, /`OPENAI_API_KEY`[\s\S]*including in workspace-only mode/);
  assert.match(instructions, /unavailable in[\s\S]*workspace-only mode/);

  const host = read("libexec/host.sh");
  assert.match(
    host,
    /usage: agentbox \[--workspace-only\] \[--no-update\] \[claude\|clauded\|codex\] \[--\] \[ARG \.\.\.\]/,
  );

  const help = run(resolve(ROOT, "bin/agentbox"), ["--help"]);
  expectExit(help, 0, "workspace-only help");
  for (const concept of [
    /--workspace-only/,
    /canonical Git worktree/,
    /physical current directory outside Git/,
    /persistent vendor home remains writable/,
    /Network remains enabled/,
    /Codex OPENAI_API_KEY remain available/,
    /Broad host roots, GH_TOKEN,[\s\S]*onhost bridge are omitted/,
    /not\s+a hostile-code sandbox/,
  ]) {
    assert.match(help.stdout, concept);
  }

  for (const args of [
    ["--workspace-only", "help"],
    ["--no-update", "-h"],
    ["--workspace-only", "--no-update", "--help"],
    ["--no-update", "--workspace-only", "--help"],
  ]) {
    const result = run(resolve(ROOT, "bin/agentbox"), args);
    expectExit(result, 0, `global early-exit help ${args.join(" ")}`);
    assert.equal(result.stdout, help.stdout);
  }
  const version = run(resolve(ROOT, "bin/agentbox"), ["--workspace-only", "--version"]);
  expectExit(version, 0, "global early-exit version");
  assert.equal(version.stdout, `agentbox ${VERSION}\n`);
});

test("reviewed runtime instruction hashes match every build input", () => {
  const digest = createHash("sha256").update(read("runtime/instructions.md")).digest("hex");
  const releaseInputs = JSON.parse(read("release-inputs.json"));
  const dockerfile = read("Dockerfile");
  const dockerDigest = dockerfile.match(/^ARG INSTRUCTIONS_SHA256=([0-9a-f]{64})$/m)?.[1];

  assert.equal(releaseInputs.managed_files.runtime_instructions.sha256, digest);
  assert.equal(dockerDigest, digest);
});

test("local Markdown links resolve and detailed docs are packaged", () => {
  const markdown = [
    "README.md",
    "docs/development.md",
    "docs/release.md",
    "docs/security.md",
    "docs/usage.md",
  ];
  for (const path of markdown) {
    const source = read(path);
    for (const match of source.matchAll(/!?\[[^\]]*\]\(([^)\s]+)(?:\s+["'][^"']*["'])?\)/g)) {
      const target = match[1];
      if (/^(?:[a-z]+:|#)/i.test(target)) continue;
      const [localPath, fragment] = target.split("#", 2);
      const resolvedTarget = resolve(dirname(resolve(ROOT, path)), localPath);
      assert.ok(
        existsSync(resolvedTarget),
        `${path} links to missing ${target}`,
      );
      if (fragment) {
        const headings = [...readFileSync(resolvedTarget, "utf8").matchAll(/^#{1,6}\s+(.+)$/gm)].map(
          ([, heading]) =>
            heading
              .toLowerCase()
              .replace(/[^a-z0-9 _-]/g, "")
              .trim()
              .replace(/\s+/g, "-"),
        );
        assert.ok(headings.includes(fragment), `${path} links to missing heading ${target}`);
      }
    }
  }

  const formula = read("Formula/agentbox.rb");
  const release = read("scripts/release.sh");
  const formulaDocs = formula.slice(
    formula.indexOf('(pkgshare/"docs").install('),
    formula.indexOf("\n    )", formula.indexOf('(pkgshare/"docs").install(')) + 6,
  );
  assert.deepEqual(
    [...formulaDocs.matchAll(/"(docs\/[^"]+)"/g)].map((match) => match[1]),
    markdown.slice(1),
    "Homebrew must install only the documentation allowlist",
  );
  for (const path of markdown.slice(1)) {
    assert.match(release, new RegExp(path.replace(/[./]/g, "\\$&")));
  }
  assert.match(formula, /\(pkgshare\/"docs"\)\.install\(/);
  assert.doesNotMatch(formula, /pkgshare\.install[^\n]*"docs"/);
  assert.match(release, /packaged_docs=\([\s\S]*docs\/usage\.md[\s\S]*docs\/release\.md[\s\S]*\)/);
  assert.match(release, /git -C "\$source_root" ls-files --error-unmatch -- "\$path"/);
  assert.match(release, /install -m 0444 "\$source_root\/\$path" "\$root\/\$path"/);
  assert.doesNotMatch(release, /cp -R[^\n]*docs/);
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
    "scripts/plan-release.py",
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

test("source metadata uses the non-publishable version sentinel", (t) => {
  const rawVersion = read("VERSION");
  const version = rawVersion.trim();
  assert.equal(rawVersion, "0.0.0\n");
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
  assert.match(release, /printf '%s\\n' "\$version" > "\$root\/VERSION"/);
  assert.match(release, /printf '%s\\n' "\$version" > "\$root\/share\/agentbox\/VERSION"/);
  assert.match(release, /--expected-version "\$version" validate-manifest/);
  const dryRun = run("bash", ["scripts/release.sh", "--dry-run", "--version", "9.8.7"]);
  expectExit(dryRun, 0, "release dry run");
  assert.match(dryRun.stdout, /agentbox-9\.8\.7\.tar\.gz/);
  assert.equal(read("VERSION"), rawVersion, "dry run must not mutate the source sentinel");
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
  assert.match(
    release,
    /install -m 0555 "\$source_root\/setup-host-bridge\.sh" "\$root\/setup-host-bridge\.sh"/,
  );
});

test("host consumes one integrity-checked launch tuple", () => {
  const host = read("libexec/host.sh");
  assert.match(host, /pwd\.getpwuid\(os\.getuid\(\)\)\.pw_dir/);
  assert.doesNotMatch(host, /SOURCE_CHECKOUT == 0[\s\S]{0,300}\$HOME\/\.agentbox/);
  const launch = host.slice(host.indexOf("launch_agent()"), host.indexOf("\nmain()"));
  assert.match(launch, /run_state launch-plan --agent "\$requested_agent" --root "\$root"/);
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
    /docker run --rm --platform linux\/amd64[\s\\]*"\$IMAGE@\$\{\{ needs\.publish_image\.outputs\.amd64 \}\}" --help/,
  );
  assert.match(
    workflow,
    /docker run --rm --platform linux\/arm64[\s\\]*"\$IMAGE@\$\{\{ needs\.publish_image\.outputs\.arm64 \}\}" --help/,
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
  assert.match(workflow, /gh pr list --repo "\$repo" --head "\$branch" --state open/);
  assert.match(workflow, /cp \.\.\/dist\/source-agentbox\.rb Formula\/agentbox\.rb/);

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

test("completions are static data and preserve the global-prefix boundary", async (t) => {
  const paths = [
    "completions/agentbox.bash",
    "completions/_agentbox",
    "completions/agentbox.fish",
  ];
  for (const path of paths) {
    if (!existsSync(resolve(ROOT, path))) continue;
    const source = read(path);
    assert.doesNotMatch(source, /\$\([^)]*agentbox|`[^`]*agentbox/);
    assert.match(source, /--no-update/);
    assert.match(source, /--workspace-only/);
  }
  const fishSource = read("completions/agentbox.fish");
  assert.doesNotMatch(fishSource, /__fish_seen_subcommand_from/);
  assert.match(fishSource, /function __agentbox_is_lifecycle/);
  assert.match(fishSource, /test "\$words\[1\]" = "\$expected"/);
  assert.match(fishSource, /function __agentbox_in_closed_command/);
  assert.match(fishSource, /complete -c agentbox -f -n '__agentbox_in_closed_command'/);
  assert.match(fishSource, /__agentbox_is_lifecycle setup/);
  assert.match(fishSource, /__agentbox_is_lifecycle rollback/);
  assert.match(fishSource, /__agentbox_is_report_lifecycle/);

  const zshSource = read("completions/_agentbox");
  for (const array of ["after_no_update", "after_workspace_only", "after_both"]) {
    const definition = zshSource.match(new RegExp(`${array}=\\([\\s\\S]*?\\n  \\)`))?.[0];
    assert.ok(definition, `${array} completion definition is missing`);
    for (const metaAction of ["help:", "-h:", "--help:", "--version:"]) {
      assert.match(definition, new RegExp(metaAction.replace(/-/g, "\\-")), `${array}: ${metaAction}`);
    }
  }
  assert.match(zshSource, /claude \| clauded \| codex \| --\) _files/);
  assert.match(zshSource, /\*\) _files/);

  expectExit(run("bash", ["-n", "completions/agentbox.bash"]), 0, "Bash completion parse");

  const complete = (...words) => {
    const script = [
      'source "$1"',
      "shift",
      'COMP_WORDS=(agentbox "$@")',
      "COMP_CWORD=$((${#COMP_WORDS[@]} - 1))",
      "_agentbox_complete",
      '((${#COMPREPLY[@]} == 0)) || printf \'%s\\n\' "${COMPREPLY[@]}"',
    ].join("\n");
    const result = run("bash", [
      "-c",
      script,
      "agentbox-completion-test",
      resolve(ROOT, "completions/agentbox.bash"),
      ...words,
    ]);
    expectExit(result, 0, `Bash completion for ${JSON.stringify(words)}`);
    return result.stdout.trim().split("\n").filter(Boolean);
  };

  const root = complete("");
  assert.ok(root.includes("--workspace-only"));
  assert.ok(root.includes("--no-update"));
  assert.ok(root.includes("setup"));

  for (const [first, second] of [
    ["--workspace-only", "--no-update"],
    ["--no-update", "--workspace-only"],
  ]) {
    const afterFirst = complete(first, "");
    assert.ok(afterFirst.includes(second));
    assert.ok(afterFirst.includes("claude"));
    assert.ok(afterFirst.includes("codex"));
    assert.ok(afterFirst.includes("--"));
    assert.ok(afterFirst.includes("help"));
    assert.ok(afterFirst.includes("-h"));
    assert.ok(afterFirst.includes("--help"));
    assert.ok(afterFirst.includes("--version"));
    assert.ok(!afterFirst.includes(first));
    assert.ok(!afterFirst.includes("setup"));

    const afterBoth = complete(first, second, "");
    assert.deepEqual(afterBoth, [
      "claude",
      "clauded",
      "codex",
      "--",
      "help",
      "-h",
      "--help",
      "--version",
    ]);
  }

  assert.deepEqual(complete("claude", "--w"), []);
  assert.deepEqual(complete("codex", "--workspace-only", ""), []);
  assert.deepEqual(complete("--", "--w"), []);
  assert.deepEqual(complete("--resume", "--w"), []);

  const zshLookup = run("/bin/sh", ["-c", "command -v zsh"]);
  const zsh = zshLookup.status === 0 ? zshLookup.stdout.trim() : "";
  await t.test(
    "zsh parsing and dynamic boundary checks",
    { skip: zsh ? false : "zsh is unavailable; unconditional static zsh assertions still ran" },
    () => {
      expectExit(run(zsh, ["-n", "completions/_agentbox"]), 0, "zsh completion parse");
      const zshComplete = (...words) => {
        const script = [
          "completion=$1",
          "shift",
          'words=(agentbox "$@")',
          "CURRENT=${#words[@]}",
          'function _describe { local name=${argv[-1]}; print -l -- "${(@P)name}"; }',
          'function _files { print "FILES"; }',
          'source "$completion"',
        ].join("\n");
        const result = run(zsh, [
          "-c",
          script,
          "agentbox-completion-test",
          resolve(ROOT, "completions/_agentbox"),
          ...words,
        ]);
        expectExit(result, 0, `zsh completion for ${JSON.stringify(words)}`);
        return result.stdout.trim().split("\n").filter(Boolean);
      };
      const zshAfterGlobal = zshComplete("--workspace-only", "");
      for (const expected of ["--no-update", "help", "-h", "--help", "--version"]) {
        assert.ok(zshAfterGlobal.some((entry) => entry.startsWith(`${expected}:`)), expected);
      }
      assert.deepEqual(zshComplete("claude", "setup", ""), ["FILES"]);
      assert.deepEqual(zshComplete("--", "doctor", ""), ["FILES"]);
      assert.deepEqual(zshComplete("--resume", "rollback", ""), ["FILES"]);
    },
  );

  const fishLookup = run("/bin/sh", ["-c", "command -v fish"]);
  const fish = fishLookup.status === 0 ? fishLookup.stdout.trim() : "";
  await t.test(
    "Fish parsing and dynamic boundary checks",
    { skip: fish ? false : "Fish is unavailable; unconditional static Fish assertions still ran" },
    () => {
      const cwd = tempDir(t);
      writeFileSync(resolve(cwd, "forwarded-file"), "fixture\n");
      const fishComplete = (line) => {
        const result = run(
          fish,
          [
            "-c",
            "source $argv[1]; cd $argv[2]; complete -C $argv[3]",
            resolve(ROOT, "completions/agentbox.fish"),
            cwd,
            line,
          ],
        );
        expectExit(result, 0, `Fish completion for ${JSON.stringify(line)}`);
        return result.stdout
          .trim()
          .split("\n")
          .filter(Boolean)
          .map((entry) => entry.split("\t", 1)[0]);
      };

      const afterGlobal = fishComplete("agentbox --workspace-only ");
      for (const expected of [
        "--no-update",
        "claude",
        "codex",
        "help",
        "-h",
        "--help",
        "--version",
      ]) {
        assert.ok(afterGlobal.includes(expected), expected);
      }
      assert.ok(fishComplete("agentbox setup --").includes("--reset-selector"));
      assert.ok(fishComplete("agentbox doctor --").includes("--json"));

      for (const line of [
        "agentbox claude setup f",
        "agentbox codex doctor f",
        "agentbox -- setup f",
        "agentbox --resume rollback f",
      ]) {
        const result = fishComplete(line);
        assert.ok(result.includes("forwarded-file"), line);
        assert.ok(!result.includes("--reset-selector"), line);
        assert.ok(!result.includes("--accept-vendor-state-risk"), line);
        assert.ok(!result.includes("--json"), line);
      }
    },
  );
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
