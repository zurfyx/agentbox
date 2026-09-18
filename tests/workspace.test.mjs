import assert from "node:assert/strict";
import {
  existsSync,
  mkdirSync,
  readFileSync,
  realpathSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { basename, resolve } from "node:path";
import test from "node:test";
import {
  ROOT,
  expectExit,
  preparedLaunchFixture,
  readNul,
  recordingEngine,
  run,
  tempDir,
  writeExecutable,
} from "./helpers.mjs";

const CLI = resolve(ROOT, "bin/agentbox");
const GIT = "/usr/bin/git";
const TMP_TMPFS = "/tmp:rw,exec,nosuid,nodev,size=67108864,mode=1777";
const SSH_TMPFS =
  "/home/node/.ssh:rw,noexec,nosuid,nodev,size=1048576,mode=0700,uid=1000,gid=1000";

function launch(prepared, args, engine, cwd, env = {}) {
  return run(CLI, args, {
    cwd,
    env: {
      AGENTBOX_HOME: prepared.home,
      AGENTBOX_TEST_ENGINE: engine.path,
      AGENTBOX_TEST_MANIFEST: prepared.manifestPath,
      AGENTBOX_TEST_MODE: "1",
      GH_TOKEN: "workspace-github-secret",
      HOME: resolve(prepared.dir, "empty-host-home"),
      OPENAI_API_KEY: "workspace-openai-secret",
      USER: "workspace-test-user",
      ...env,
    },
  });
}

function mountValues(argv) {
  const mounts = [];
  for (let index = 0; index < argv.length; index += 1) {
    if (argv[index] === "--mount") mounts.push(argv[index + 1]);
  }
  return mounts;
}

function activation(prepared) {
  return JSON.parse(
    readFileSync(resolve(prepared.runtimeRoot, "activation.json"), "utf8"),
  ).current;
}

function runtimeTail(prepared, mode, forwarded) {
  const current = activation(prepared);
  return [
    current.runtime_image,
    "run",
    "--protocol",
    "1",
    "--mode",
    mode,
    "--release",
    basename(current.release_path),
    "--",
    ...forwarded,
  ];
}

function initializeRepository(path) {
  mkdirSync(path, { recursive: true });
  for (const [args, context] of [
    [["init", path], "git init"],
    [["-C", path, "config", "user.name", "Agentbox Test"], "git user.name"],
    [
      ["-C", path, "config", "user.email", "agentbox@example.invalid"],
      "git user.email",
    ],
  ]) {
    expectExit(run(GIT, args), 0, context);
  }
  writeFileSync(resolve(path, "tracked.txt"), "tracked\n");
  expectExit(run(GIT, ["-C", path, "add", "tracked.txt"]), 0, "git add");
  expectExit(
    run(GIT, ["-C", path, "commit", "-m", "fixture"]),
    0,
    "git commit",
  );
}

test("workspace flag prefix matrix preserves selectors and payload opacity", async (t) => {
  const prepared = preparedLaunchFixture(t);
  const workspace = resolve(prepared.dir, "matrix workspace");
  mkdirSync(workspace);
  let serial = 0;

  for (const flags of [
    ["--workspace-only"],
    ["--workspace-only", "--no-update"],
    ["--no-update", "--workspace-only"],
  ]) {
    for (const selector of ["", "claude", "clauded", "codex"]) {
      const label = `${flags.join(" ")} ${selector || "default"}`;
      await t.test(label, () => {
        const engine = recordingEngine(
          prepared.dir,
          42,
          `prefix-matrix-${serial++}`,
        );
        const payload = ["argument with spaces", "", "line one\nline two"];
        const args = [...flags];
        if (selector) args.push(selector);
        args.push("--", ...payload);
        expectExit(
          launch(prepared, args, engine, workspace),
          42,
          `agentbox ${label}`,
        );
        const argv = readNul(engine.argv);
        const mode = selector || "claude";
        assert.deepEqual(argv.slice(-payload.length), payload);
        assert.deepEqual(
          argv.slice(-runtimeTail(prepared, mode, payload).length),
          runtimeTail(prepared, mode, payload),
        );
        assert.ok(
          mountValues(argv).includes(
            `type=bind,src=${workspace},dst=${workspace}`,
          ),
        );
        assert.ok(argv.includes(TMP_TMPFS));
      });
    }
  }

  const opacityCases = [
    {
      args: ["claude", "--workspace-only", "after-selector"],
      forwarded: ["--workspace-only", "after-selector"],
      workspaceOnly: false,
    },
    {
      args: ["--", "--workspace-only", "after-separator"],
      forwarded: ["--workspace-only", "after-separator"],
      workspaceOnly: false,
    },
    {
      args: ["--resume", "--workspace-only", "after-unknown"],
      forwarded: ["--resume", "--workspace-only", "after-unknown"],
      workspaceOnly: false,
    },
    {
      args: ["codex", "--no-update", "after-selector"],
      forwarded: ["--no-update", "after-selector"],
      workspaceOnly: false,
    },
    {
      args: ["--workspace-only", "claude", "--workspace-only", "opaque"],
      forwarded: ["--workspace-only", "opaque"],
      workspaceOnly: true,
    },
    {
      args: ["--workspace-only", "claude", "--no-update", "opaque"],
      forwarded: ["--no-update", "opaque"],
      workspaceOnly: true,
    },
    {
      args: ["--workspace-only", "--", "--workspace-only", "opaque"],
      forwarded: ["--workspace-only", "opaque"],
      workspaceOnly: true,
    },
  ];
  for (const entry of opacityCases) {
    await t.test(entry.args.join(" "), () => {
      const engine = recordingEngine(
        prepared.dir,
        42,
        `prefix-opacity-${serial++}`,
      );
      expectExit(
        launch(prepared, entry.args, engine, workspace),
        42,
        entry.args.join(" "),
      );
      const argv = readNul(engine.argv);
      assert.deepEqual(argv.slice(-entry.forwarded.length), entry.forwarded);
      assert.equal(argv.includes(TMP_TMPFS), entry.workspaceOnly);
    });
  }
});

test("duplicate global flags and lifecycle combinations fail before state or engine", async (t) => {
  const dir = tempDir(t);
  let serial = 0;
  const cases = [
    ["--workspace-only", "--workspace-only"],
    ["--no-update", "--no-update"],
    ["--workspace-only", "--no-update", "--workspace-only"],
    ["--no-update", "--workspace-only", "--no-update"],
    ...["--workspace-only", "--no-update"].flatMap((flag) =>
      ["setup", "update", "rollback", "doctor", "info"].map((command) => [
        flag,
        command,
      ]),
    ),
  ];
  for (const args of cases) {
    await t.test(args.join(" "), () => {
      const engine = recordingEngine(dir, 0, `parse-rejection-${serial++}`);
      const home = resolve(dir, `must-not-exist-${serial}`);
      const result = run(CLI, args, {
        env: {
          AGENTBOX_HOME: home,
          AGENTBOX_TEST_ENGINE: engine.path,
          AGENTBOX_TEST_MANIFEST: resolve(dir, "missing-manifest.json"),
          AGENTBOX_TEST_MODE: "1",
          GH_TOKEN: "not-for-engine",
          HOME: resolve(dir, "empty-home"),
        },
      });
      assert.notEqual(result.status, 0, args.join(" "));
      assert.match(result.stderr, /usage|applies only|duplicate|once/i);
      assert.equal(existsSync(home), false);
      assert.equal(engine.wasCalled(), false);
    });
  }
});

test("normal launch retains the exact Docker argument vector", (t) => {
  const prepared = preparedLaunchFixture(t);
  const cwd = resolve(prepared.dir, "normal mode cwd");
  mkdirSync(cwd);
  const engine = recordingEngine(prepared.dir, 42, "normal-vector");
  expectExit(
    launch(prepared, ["claude", "payload"], engine, cwd, {
      AGENTBOX_HOST: "bridge.test.invalid",
      AGENTBOX_HOST_USER: "bridge-test-user",
    }),
    42,
    "normal launch",
  );
  const current = activation(prepared);
  const expected = [
    "run",
    "--rm",
    "-i",
    "--mount",
    `type=bind,src=${prepared.home},dst=/home/node`,
    "--mount",
    `type=bind,src=${prepared.runtimeRoot},dst=/home/node/runtime,readonly`,
    "--mount",
    `type=bind,src=${prepared.runtimeRoot},dst=${prepared.runtimeRoot},readonly`,
    "--mount",
    `type=bind,src=${current.release_path}/vendor,dst=/opt/agentbox/vendor,readonly`,
    "--mount",
    `type=bind,src=${current.release_path}/manifest.json,dst=/opt/agentbox/release/manifest.json,readonly`,
  ];
  for (const broad of ["/Users", "/Volumes", "/tmp", "/private/tmp"]) {
    if (existsSync(broad)) {
      expected.push("--mount", `type=bind,src=${broad},dst=${broad}`);
    }
  }
  expected.push(
    "-w",
    realpathSync(cwd),
    "-e",
    "GH_TOKEN",
    "-e",
    "AGENTBOX_HOST=bridge.test.invalid",
    "-e",
    "AGENTBOX_HOST_USER=bridge-test-user",
    ...runtimeTail(prepared, "claude", ["payload"]),
  );
  assert.deepEqual(readNul(engine.argv), expected);
  assert.match(readFileSync(engine.environment, "utf8"), /GH_TOKEN=workspace-github-secret/);
});

test("workspace Docker vector is scoped, ordered, and credential-minimal", async (t) => {
  const prepared = preparedLaunchFixture(t);
  const workspace = resolve(prepared.dir, "scoped project");
  mkdirSync(workspace);
  const current = activation(prepared);

  const claudeEngine = recordingEngine(prepared.dir, 42, "workspace-vector");
  const claudeResult = launch(
    prepared,
    ["--workspace-only", "claude", "payload"],
    claudeEngine,
    workspace,
    {
      AGENTBOX_HOST: "must-not-forward",
      AGENTBOX_HOST_USER: "must-not-forward",
      AWS_SECRET_ACCESS_KEY: "must-not-forward",
      DOCKER_HOST: "must-not-forward",
      SSH_AUTH_SOCK: resolve(prepared.dir, "must-not-forward.sock"),
    },
  );
  expectExit(claudeResult, 42, "workspace Claude launch");
  const expected = [
    "run",
    "--rm",
    "-i",
    "--mount",
    `type=bind,src=${prepared.home},dst=/home/node`,
    "--mount",
    `type=bind,src=${workspace},dst=${workspace}`,
    "--mount",
    `type=bind,src=${prepared.runtimeRoot},dst=/home/node/runtime,readonly`,
    "--mount",
    `type=bind,src=${prepared.runtimeRoot},dst=${prepared.runtimeRoot},readonly`,
    "--mount",
    `type=bind,src=${current.release_path}/vendor,dst=/opt/agentbox/vendor,readonly`,
    "--mount",
    `type=bind,src=${current.release_path}/manifest.json,dst=/opt/agentbox/release/manifest.json,readonly`,
    "--tmpfs",
    TMP_TMPFS,
    "--tmpfs",
    SSH_TMPFS,
    "-w",
    workspace,
    ...runtimeTail(prepared, "claude", ["payload"]),
  ];
  const claudeArgv = readNul(claudeEngine.argv);
  assert.deepEqual(claudeArgv, expected);
  const forbidden = [
    "GH_TOKEN",
    "AGENTBOX_HOST",
    "AGENTBOX_HOST_USER",
    "OPENAI_API_KEY",
    "--privileged",
    "--network=host",
    "/var/run/docker.sock",
  ];
  for (const value of forbidden) assert.equal(claudeArgv.includes(value), false);
  for (const broad of ["/Users", "/Volumes", "/tmp", "/private/tmp"]) {
    assert.equal(
      mountValues(claudeArgv).includes(`type=bind,src=${broad},dst=${broad}`),
      false,
    );
  }
  const claudeEnvironment = readFileSync(claudeEngine.environment, "utf8");
  for (const value of [
    "GH_TOKEN=",
    "OPENAI_API_KEY=",
    "AGENTBOX_HOST=",
    "AGENTBOX_HOST_USER=",
    "AWS_SECRET_ACCESS_KEY=",
    "DOCKER_HOST=",
    "SSH_AUTH_SOCK=",
    "workspace-github-secret",
    "workspace-openai-secret",
    "must-not-forward",
  ]) {
    assert.equal(claudeEnvironment.includes(value), false, value);
  }

  await t.test("Codex retains only its API key", () => {
    const codexEngine = recordingEngine(prepared.dir, 42, "workspace-codex-key");
    expectExit(
      launch(
        prepared,
        ["--workspace-only", "codex", "payload"],
        codexEngine,
        workspace,
      ),
      42,
      "workspace Codex launch",
    );
    const argv = readNul(codexEngine.argv);
    assert.deepEqual(argv.slice(argv.indexOf("-w") + 2, argv.indexOf("-w") + 4), [
      "-e",
      "OPENAI_API_KEY",
    ]);
    assert.equal(argv.includes("GH_TOKEN"), false);
    const environment = readFileSync(codexEngine.environment, "utf8");
    assert.match(environment, /OPENAI_API_KEY=workspace-openai-secret/);
    assert.equal(environment.includes("GH_TOKEN="), false);
    assert.equal(environment.includes("workspace-github-secret"), false);
  });

  await t.test("credential helper lookup is skipped only in workspace mode", () => {
    const brewPrefix = resolve(prepared.dir, "custom homebrew");
    const helper = resolve(brewPrefix, "Cellar/gh/2.98.0/bin/gh");
    mkdirSync(resolve(brewPrefix, "Cellar/gh/2.98.0/bin"), { recursive: true });
    mkdirSync(resolve(brewPrefix, "bin"), { recursive: true });
    symlinkSync("../Cellar/gh/2.98.0/bin/gh", resolve(brewPrefix, "bin/gh"));
    const helperArgv = resolve(prepared.dir, "fixed-gh-candidate.argv");
    writeExecutable(
      helper,
      `#!/bin/sh
printf '%s\\0' "$@" > '${helperArgv}'
printf '%s\\n' 'fixed-path-gh-secret'
`,
    );
    const workspaceEngine = recordingEngine(
      prepared.dir,
      42,
      "workspace-no-gh-lookup",
    );
    const workspaceResult = launch(
      prepared,
      ["--workspace-only", "claude"],
      workspaceEngine,
      workspace,
      { AGENTBOX_TEST_BREW_PREFIX: brewPrefix, GH_TOKEN: null },
    );
    expectExit(
      workspaceResult,
      42,
      "workspace launch without GitHub credential lookup",
    );
    assert.equal(existsSync(helperArgv), false);
    assert.doesNotMatch(workspaceResult.stderr, /no GitHub token/i);
    assert.equal(
      readFileSync(workspaceEngine.environment, "utf8").includes("GH_TOKEN="),
      false,
    );

    const normalEngine = recordingEngine(
      prepared.dir,
      42,
      "normal-gh-lookup",
    );
    expectExit(
      launch(prepared, ["claude"], normalEngine, workspace, {
        AGENTBOX_TEST_BREW_PREFIX: brewPrefix,
        GH_TOKEN: null,
      }),
      42,
      "normal launch through fixed GitHub helper branch",
    );
    assert.deepEqual(readNul(helperArgv), [
      "auth",
      "token",
      "--hostname",
      "github.com",
    ]);
    assert.ok(readNul(normalEngine.argv).includes("GH_TOKEN"));
    assert.match(
      readFileSync(normalEngine.environment, "utf8"),
      /GH_TOKEN=fixed-path-gh-secret/,
    );
  });
});

test("custom Homebrew prefix owns the update command", (t) => {
  const dir = tempDir(t);
  const prefix = resolve(dir, "custom homebrew");
  const brewLog = resolve(dir, "brew.log");
  const agentboxLog = resolve(dir, "agentbox.log");
  mkdirSync(resolve(prefix, "bin"), { recursive: true });
  mkdirSync(resolve(prefix, "opt/agentbox/bin"), { recursive: true });
  writeExecutable(
    resolve(prefix, "bin/brew"),
    `#!/bin/sh
printf '%s\n' "$*" >> '${brewLog}'
if [ "$1" = upgrade ] && [ "$2" = agentbox ]; then exit 0; fi
if [ "$1" = --prefix ] && [ "$2" = agentbox ]; then printf '%s\n' '${prefix}/opt/agentbox'; exit 0; fi
exit 64
`,
  );
  writeExecutable(
    resolve(prefix, "opt/agentbox/bin/agentbox"),
    `#!/bin/sh
printf '%s\n' "$*" > '${agentboxLog}'
`,
  );

  const result = run(CLI, ["update"], {
    env: {
      AGENTBOX_TEST_BREW_PREFIX: prefix,
      AGENTBOX_TEST_MODE: "1",
      HOME: resolve(dir, "home"),
    },
  });
  expectExit(result, 0, "custom-prefix update");
  assert.equal(readFileSync(brewLog, "utf8"), "upgrade agentbox\n--prefix agentbox\n");
  assert.equal(readFileSync(agentboxLog, "utf8"), "setup\n");
});

test("workspace root discovery handles physical, standard Git, and linked worktrees", async (t) => {
  const prepared = preparedLaunchFixture(t);
  let serial = 0;

  await t.test("physical non-Git symlink cwd", () => {
    const physical = resolve(prepared.dir, "physical workspace: with spaces");
    const nested = resolve(physical, "nested");
    const logical = resolve(prepared.dir, "logical-workspace");
    mkdirSync(nested, { recursive: true });
    symlinkSync(nested, logical);
    const engine = recordingEngine(prepared.dir, 42, `scope-${serial++}`);
    expectExit(
      launch(prepared, ["--workspace-only", "claude"], engine, logical),
      42,
      "symlinked non-Git cwd",
    );
    const argv = readNul(engine.argv);
    const canonical = realpathSync(nested);
    assert.ok(
      mountValues(argv).includes(`type=bind,src=${canonical},dst=${canonical}`),
    );
    assert.equal(argv[argv.indexOf("-w") + 1], canonical);
  });

  await t.test("nested standard Git cwd ignores ambient Git controls", () => {
    const repository = resolve(prepared.dir, "standard-repository");
    initializeRepository(repository);
    const nested = resolve(repository, "one", "two");
    mkdirSync(nested, { recursive: true });
    const fakeBin = resolve(prepared.dir, "hostile-path");
    const marker = resolve(prepared.dir, "path-git-called");
    mkdirSync(fakeBin);
    writeExecutable(
      resolve(fakeBin, "git"),
      `#!/bin/sh\nprintf called > '${marker}'\nexit 99\n`,
    );
    const engine = recordingEngine(prepared.dir, 42, `scope-${serial++}`);
    expectExit(
      launch(prepared, ["--workspace-only", "claude"], engine, nested, {
        GIT_CONFIG_GLOBAL: resolve(prepared.dir, "hostile-gitconfig"),
        GIT_DIR: "/",
        GIT_WORK_TREE: "/",
        PATH: `${fakeBin}:/usr/bin:/bin`,
      }),
      42,
      "nested standard Git cwd",
    );
    const mounts = mountValues(readNul(engine.argv));
    assert.equal(existsSync(marker), false);
    assert.equal(
      mounts.filter((mount) => mount === `type=bind,src=${repository},dst=${repository}`)
        .length,
      1,
    );
    assert.equal(
      mounts.some((mount) => mount.includes(`src=${repository}/.git,`)),
      false,
    );
  });

  await t.test("linked worktree adds only its common Git directory", () => {
    const main = resolve(prepared.dir, "main-repository");
    const linked = resolve(prepared.dir, "linked-repository");
    initializeRepository(main);
    expectExit(
      run(GIT, ["-C", main, "worktree", "add", "-b", "linked-test", linked]),
      0,
      "git worktree add",
    );
    const nested = resolve(linked, "nested");
    mkdirSync(nested);
    const engine = recordingEngine(prepared.dir, 42, `scope-${serial++}`);
    expectExit(
      launch(prepared, ["--workspace-only", "claude"], engine, nested),
      42,
      "linked worktree launch",
    );
    const mounts = mountValues(readNul(engine.argv));
    const common = realpathSync(resolve(main, ".git"));
    assert.deepEqual(mounts.slice(0, 3), [
      `type=bind,src=${prepared.home},dst=/home/node`,
      `type=bind,src=${linked},dst=${linked}`,
      `type=bind,src=${common},dst=${common}`,
    ]);
    assert.equal(
      mounts.some((mount) => mount === `type=bind,src=${main},dst=${main}`),
      false,
    );
    assert.equal(
      mounts.some((mount) => mount.includes("/.git/worktrees/")),
      false,
    );
  });
});

test("unsafe workspace scopes fail closed before any engine access", async (t) => {
  const prepared = preparedLaunchFixture(t);
  const controls = [
    resolve(prepared.dir, "comma,dst=malicious"),
    resolve(prepared.dir, "line\nbreak"),
    resolve(prepared.dir, "tab\tbreak"),
  ];
  for (const path of controls) mkdirSync(path);
  const candidates = [
    ["filesystem root", "/"],
    ["account home", realpathSync(homedir())],
    ["Agentbox home ancestor", prepared.dir],
    ["comma mount grammar", controls[0]],
    ["newline mount grammar", controls[1]],
    ["tab mount grammar", controls[2]],
  ];
  for (const broad of ["/Users", "/Volumes", "/tmp", "/private/tmp"]) {
    if (existsSync(broad)) candidates.push([`broad root ${broad}`, realpathSync(broad)]);
  }
  const unique = new Map(candidates.map(([label, path]) => [path, label]));
  let serial = 0;
  for (const [cwd, label] of unique) {
    await t.test(label, () => {
      const engine = recordingEngine(prepared.dir, 0, `unsafe-${serial++}`);
      const result = launch(
        prepared,
        ["--workspace-only", "claude"],
        engine,
        cwd,
      );
      assert.notEqual(result.status, 0, label);
      assert.match(result.stderr, /workspace|scope|unsafe|refus|mount/i);
      assert.equal(engine.wasCalled(), false, label);
    });
  }
});

test("external Git metadata is rejected before engine access", (t) => {
  const prepared = preparedLaunchFixture(t);
  const workspace = resolve(prepared.dir, "external-metadata-workspace");
  const metadata = resolve(prepared.dir, "external-git-metadata");
  mkdirSync(workspace);
  expectExit(
    run(GIT, ["init", `--separate-git-dir=${metadata}`, workspace]),
    0,
    "separate Git directory fixture",
  );
  const engine = recordingEngine(prepared.dir, 0, "external-metadata-engine");
  const result = launch(
    prepared,
    ["--workspace-only", "claude"],
    engine,
    workspace,
  );
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /external|metadata|linked worktree|unsafe/i);
  assert.equal(engine.wasCalled(), false);
});

test("repository core.worktree cannot widen the workspace to an ancestor", (t) => {
  const prepared = preparedLaunchFixture(t);
  const parent = tempDir(t);
  const repository = resolve(parent, "repository");
  initializeRepository(repository);
  writeFileSync(resolve(parent, "outside-repository-sentinel"), "private\n");
  expectExit(
    run(GIT, ["-C", repository, "config", "core.worktree", parent]),
    0,
    "configure ancestor core.worktree",
  );
  const engine = recordingEngine(prepared.dir, 0, "core-worktree-engine");
  const result = launch(
    prepared,
    ["--workspace-only", "claude"],
    engine,
    repository,
  );
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /Git|metadata|worktree|standard|unsafe/i);
  assert.equal(engine.wasCalled(), false);
});
