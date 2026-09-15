import assert from "node:assert/strict";
import {
  chmodSync,
  copyFileSync,
  existsSync,
  mkdirSync,
  readFileSync,
  realpathSync,
  rmSync,
  mkdtempSync,
  writeFileSync,
} from "node:fs";
import { resolve } from "node:path";
import test from "node:test";
import {
  AGENTBOX_VERSION,
  bindArtifacts,
  createVendorDownloads,
  manifest,
  sha256,
  writeManifest,
} from "./fixtures.mjs";
import {
  ROOT,
  expectExit,
  readNul,
  run,
  tempDir,
  writeExecutable,
  writeProtocolEngine,
} from "./helpers.mjs";

const CLI = resolve(ROOT, "bin/agentbox");
const STATE = resolve(ROOT, "libexec/state.py");
const VERSION = AGENTBOX_VERSION;

function bindManagedFiles(value) {
  value.managed_files.runtime_instructions.sha256 = sha256(
    readFileSync(resolve(ROOT, "runtime/instructions.md")),
  );
  value.managed_files.statusline.sha256 = sha256(
    readFileSync(resolve(ROOT, "runtime/statusline.sh")),
  );
  return value;
}

function fixture(t) {
  const dir = tempDir(t);
  const home = resolve(dir, "personal");
  const runtimeRoot = resolve(home, "runtime");
  const artifacts = createVendorDownloads(dir);
  const downloads = artifacts.downloads;
  const value = bindManagedFiles(bindArtifacts(manifest(), artifacts));
  const manifestPath = resolve(dir, "release-manifest.json");
  writeManifest(manifestPath, value);

  const setupEngine = resolve(dir, "setup-engine");
  writeProtocolEngine(setupEngine);
  const prepared = run(
    "python3",
    [
      "-I",
      STATE,
      "--expected-version",
      VERSION,
      "prepare",
      "--root",
      runtimeRoot,
      "--manifest",
      manifestPath,
      "--engine",
      setupEngine,
    ],
    {
      env: {
        AGENTBOX_TEST_MODE: "1",
        AGENTBOX_TEST_DOWNLOAD_DIR: downloads,
      },
    },
  );
  expectExit(prepared, 0, "fixture state preparation");
  return { dir, downloads, home, manifestPath };
}

function cli(args, fixture, engine, env = {}) {
  return run(CLI, args, {
    env: {
      AGENTBOX_TEST_MODE: "1",
      AGENTBOX_TEST_MANIFEST: fixture.manifestPath,
      AGENTBOX_TEST_ENGINE: engine,
      AGENTBOX_HOME: fixture.home,
      GH_TOKEN: "github-secret-value",
      OPENAI_API_KEY: "openai-secret-value",
      ...env,
    },
  });
}

function recordingEngine(dir, exitCode = 0) {
  const path = resolve(dir, `engine-${exitCode}`);
  const argv = resolve(dir, `engine-${exitCode}.argv`);
  const environment = resolve(dir, `engine-${exitCode}.env`);
  writeExecutable(
    path,
    `#!/bin/sh
if [ "$1" = image ] && [ "$2" = inspect ]; then exit 0; fi
printf '%s\\0' "$@" > '${argv}'
env > '${environment}'
exit ${exitCode}
`,
  );
  return { argv, environment, path };
}

test("help and version do not require a manifest or create state", (t) => {
  const dir = tempDir(t);
  const home = resolve(dir, "must-not-exist");
  for (const args of [["--help"], ["-h"], ["help"], ["--version"]]) {
    const result = run(CLI, args, {
      env: {
        AGENTBOX_TEST_MODE: "1",
        AGENTBOX_HOME: home,
        AGENTBOX_TEST_MANIFEST: resolve(dir, "missing.json"),
        AGENTBOX_TEST_ENGINE: resolve(dir, "missing-engine"),
      },
    });
    expectExit(result, 0, args.join(" "));
    assert.equal(existsSync(home), false);
    assert.equal(result.stderr, "");
  }
});

test("info is read-only and emits stable JSON for absent state", (t) => {
  const dir = tempDir(t);
  const home = resolve(dir, "must-not-exist");
  const manifestPath = resolve(dir, "manifest.json");
  writeManifest(manifestPath);
  const result = run(CLI, ["info", "--json"], {
    env: {
      AGENTBOX_TEST_MODE: "1",
      AGENTBOX_HOME: home,
      AGENTBOX_TEST_MANIFEST: manifestPath,
    },
  });
  expectExit(result, 0, "info --json");
  const value = JSON.parse(result.stdout);
  assert.equal(value.agentbox_version, VERSION);
  assert.equal(value.state, "absent");
  assert.equal(existsSync(home), false);
});

test("doctor reports absent state as unhealthy without creating it", (t) => {
  const dir = tempDir(t);
  const home = resolve(dir, "must-not-exist");
  const manifestPath = resolve(dir, "manifest.json");
  writeManifest(manifestPath);
  const engine = recordingEngine(dir);
  const result = run(CLI, ["doctor", "--json"], {
    env: {
      AGENTBOX_TEST_MODE: "1",
      AGENTBOX_HOME: home,
      AGENTBOX_TEST_MANIFEST: manifestPath,
      AGENTBOX_TEST_ENGINE: engine.path,
    },
  });
  assert.notEqual(result.status, 0);
  assert.equal(JSON.parse(result.stdout).state, "absent");
  assert.equal(existsSync(home), false);
});

test("unknown lifecycle flags fail before touching state", (t) => {
  const dir = tempDir(t);
  const home = resolve(dir, "must-not-exist");
  const manifestPath = resolve(dir, "manifest.json");
  writeManifest(manifestPath);
  for (const args of [
    ["info", "--bogus"],
    ["info", "--json", "extra"],
    ["doctor", "--bogus"],
    ["doctor", "--json", "extra"],
    ["setup", "--bogus"],
    ["--version", "extra"],
  ]) {
    const result = run(CLI, args, {
      env: {
        AGENTBOX_TEST_MODE: "1",
        AGENTBOX_HOME: home,
        AGENTBOX_TEST_MANIFEST: manifestPath,
      },
    });
    assert.notEqual(result.status, 0, args.join(" "));
    assert.equal(existsSync(home), false);
  }
});

test("launch matrix constructs exact protocol and preserves argv", async (t) => {
  const prepared = fixture(t);
  const user = ["argument with spaces", "", "line one\nline two", "--literal"];
  const cases = [
    { input: [], mode: "claude", forwarded: [] },
    { input: user, mode: "claude", forwarded: user },
    { input: ["claude", ...user], mode: "claude", forwarded: user },
    { input: ["--", ...user], mode: "claude", forwarded: user },
    { input: ["clauded", ...user], mode: "clauded", forwarded: user },
    { input: ["codex", ...user], mode: "codex", forwarded: user },
  ];

  for (const entry of cases) {
    await t.test(entry.input[0] || "empty", () => {
      const engine = recordingEngine(prepared.dir, 42);
      const result = cli(entry.input, prepared, engine.path);
      expectExit(result, 42, `agentbox ${entry.mode}`);
      const argv = readNul(engine.argv);
      if (entry.forwarded.length) {
        assert.deepEqual(argv.slice(-entry.forwarded.length), entry.forwarded);
      } else {
        assert.equal(argv.at(-1), "--");
      }
      assert.ok(argv.includes("run"));
      assert.ok(argv.includes("--protocol"));
      assert.ok(argv.includes("1"));
      assert.ok(argv.includes("--mode"));
      assert.ok(argv.includes(entry.mode));
      assert.ok(argv.includes("--release"));
      assert.ok(argv.some((arg) => arg.endsWith("dst=/home/node/runtime,readonly")));
      assert.ok(argv.some((arg) => arg.endsWith(`dst=${prepared.home}/runtime,readonly`)));
      assert.ok(argv.some((arg) => arg.includes("dst=/opt/agentbox/vendor,readonly")));
      assert.equal(argv.includes("-i"), true);
      assert.equal(argv.includes("-t"), false);
      assert.equal(argv.includes("-p"), false);
      assert.equal(argv.includes("github-secret-value"), false);
      assert.equal(argv.includes("openai-secret-value"), false);
      assert.equal(argv.includes("OPENAI_API_KEY"), entry.mode === "codex");
      const engineEnvironment = readFileSync(engine.environment, "utf8");
      assert.equal(engineEnvironment.includes("github-secret-value"), true);
      assert.equal(engineEnvironment.includes("openai-secret-value"), entry.mode === "codex");
      assert.equal(engineEnvironment.includes("AGENTBOX_TEST_"), false);
    });
  }
});

test("TTY detection maps to Docker stdin and terminal flags", (t) => {
  const prepared = fixture(t);
  const engine = recordingEngine(prepared.dir);
  const wrapper = resolve(prepared.dir, "tty-wrapper");
  writeExecutable(
    wrapper,
    `#!/bin/sh
export AGENTBOX_TEST_MODE=1
export AGENTBOX_TEST_MANIFEST='${prepared.manifestPath}'
export AGENTBOX_TEST_ENGINE='${engine.path}'
export AGENTBOX_HOME='${prepared.home}'
export GH_TOKEN=test
exec '${CLI}' claude tty-check
`,
  );
  const ptyRunner = [
    "import os,pty,sys",
    "pid,fd=pty.fork()",
    "if pid==0: os.execv(sys.argv[1],[sys.argv[1]])",
    "try:",
    " while os.read(fd,8192): pass",
    "except OSError: pass",
    "_,status=os.waitpid(pid,0)",
    "raise SystemExit(os.waitstatus_to_exitcode(status))",
  ].join("\n");
  expectExit(run("python3", ["-c", ptyRunner, wrapper]), 0, "pseudo-terminal launch");
  const argv = readNul(engine.argv);
  assert.ok(argv.includes("-i"));
  assert.ok(argv.includes("-t"));
});

test("non-TTY launches keep piped stdin attached", (t) => {
  const prepared = fixture(t);
  const engine = recordingEngine(prepared.dir, 0);
  const stdinRecord = resolve(prepared.dir, "stdin");
  writeExecutable(
    engine.path,
    `#!/bin/sh
if [ "$1" = image ] && [ "$2" = inspect ]; then exit 0; fi
printf '%s\\0' "$@" > '${engine.argv}'
env > '${engine.environment}'
cat > '${stdinRecord}'
`,
  );
  const result = run(CLI, ["codex", "login", "--with-api-key"], {
    input: "stdin-sentinel\n",
    env: {
      AGENTBOX_TEST_MODE: "1",
      AGENTBOX_TEST_MANIFEST: prepared.manifestPath,
      AGENTBOX_TEST_ENGINE: engine.path,
      AGENTBOX_HOME: prepared.home,
      GH_TOKEN: "test",
    },
  });
  expectExit(result, 0, "piped stdin launch");
  assert.ok(readNul(engine.argv).includes("-i"));
  assert.equal(readFileSync(stdinRecord, "utf8"), "stdin-sentinel\n");
});

test("Codex callback login is rejected before engine access", (t) => {
  const prepared = fixture(t);
  const engine = recordingEngine(prepared.dir);
  const rejected = cli(["codex", "login"], prepared, engine.path);
  assert.notEqual(rejected.status, 0);
  assert.match(rejected.stderr, /device-auth|API.?key/i);
  assert.equal(existsSync(engine.argv), false);

  const acceptedEngine = recordingEngine(prepared.dir, 41);
  expectExit(
    cli(["codex", "login", "--device-auth"], prepared, acceptedEngine.path),
    41,
    "device auth dispatch",
  );
});

test("explicit development setup uses an isolated local image without pulling", (t) => {
  const dir = tempDir(t);
  const home = resolve(dir, "personal");
  const artifacts = createVendorDownloads(dir);
  const downloads = artifacts.downloads;

  const image = `sha256:${"d".repeat(64)}`;
  const value = bindManagedFiles(
    bindArtifacts(manifest({ runtime: { image } }), artifacts),
  );
  const devManifest = resolve(dir, "dev-manifest.json");
  writeManifest(devManifest, value);

  const engineLog = resolve(dir, "dev-engine.log");
  const engine = resolve(dir, "dev-engine");
  writeProtocolEngine(engine, { logPath: engineLog });
  const result = run(CLI, ["setup"], {
    env: {
      AGENTBOX_DEV_MODE: "1",
      AGENTBOX_DEV_MANIFEST: devManifest,
      AGENTBOX_DEV_IMAGE: "attacker-controlled:latest",
      AGENTBOX_TEST_MODE: "1",
      AGENTBOX_TEST_ENGINE: engine,
      AGENTBOX_TEST_DOWNLOAD_DIR: downloads,
      AGENTBOX_TEST_MANIFEST: resolve(dir, "must-not-win.json"),
      AGENTBOX_HOME: home,
    },
  });
  expectExit(result, 0, "development setup");

  const calls = readFileSync(engineLog, "utf8").trim().split("\n");
  assert.ok(calls.some((line) => line === `image inspect ${image}`));
  assert.equal(calls.some((line) => /(^| )pull( |$)/.test(line)), false);
  const prepareCall = calls.find((line) => line.includes(" prepare --protocol 1 "));
  const validateCall = calls.find((line) => line.includes(" validate --protocol 1 "));
  assert.ok(prepareCall);
  assert.ok(validateCall);
  for (const call of [prepareCall, validateCall]) {
    assert.match(call, /--memory 512m/);
    assert.match(call, /--memory-swap 512m/);
    assert.match(call, /--cpus 1/);
    assert.match(call, /--pids-limit 128/);
  }
  assert.equal(existsSync(resolve(home, "runtime")), false);
  assert.ok(existsSync(resolve(home, "dev-runtime", "activation.json")));
  const activation = JSON.parse(
    readFileSync(resolve(home, "dev-runtime", "activation.json"), "utf8"),
  );
  assert.equal(activation.current.runtime_image, image);
  assert.notEqual(activation.current.runtime_image, "attacker-controlled:latest");

  expectExit(
    run("python3", ["-I", STATE, "--expected-version", VERSION, "--development", "validate-manifest", devManifest]),
    0,
    "development manifest validation",
  );
  expectExit(
    run("python3", ["-I", STATE, "--expected-version", VERSION, "validate-manifest", devManifest]),
    65,
    "stable manifest validation",
  );
});

test("failed lazy setup launches the retained active release", (t) => {
  const prepared = fixture(t);
  const initial = JSON.parse(
    readFileSync(resolve(prepared.home, "runtime", "activation.json"), "utf8"),
  );
  const next = manifest();
  next.tools.claude.version = "2.1.273";
  for (const item of next.tools.claude.platforms) {
    item.url = item.url.replaceAll("2.1.272", "2.1.273");
  }
  const nextManifest = resolve(prepared.dir, "next-manifest.json");
  writeManifest(nextManifest, next);

  const log = resolve(prepared.dir, "fallback-engine.log");
  const engine = resolve(prepared.dir, "fallback-engine");
  writeExecutable(
    engine,
    `#!/bin/sh
printf '%s\\n' "$*" >> '${log}'
case " $* " in
  *" validate --protocol "*) exit 23 ;;
  *" run --protocol 1 --mode claude "*) exit 42 ;;
  *) exit 0 ;;
esac
`,
  );
  const result = run(CLI, ["claude", "fallback-check"], {
    env: {
      AGENTBOX_TEST_MODE: "1",
      AGENTBOX_TEST_MANIFEST: nextManifest,
      AGENTBOX_TEST_ENGINE: engine,
      AGENTBOX_TEST_DOWNLOAD_DIR: prepared.downloads,
      AGENTBOX_HOME: prepared.home,
      GH_TOKEN: "test",
    },
  });
  expectExit(result, 42, "fallback launch");
  assert.match(result.stderr, /continuing|active|previous|retained/i);
  assert.ok(
    readFileSync(log, "utf8").includes(" run --protocol 1 --mode claude "),
  );
  assert.deepEqual(
    JSON.parse(readFileSync(resolve(prepared.home, "runtime", "activation.json"), "utf8")),
    initial,
  );
});

test("failed first setup never launches an agent", (t) => {
  const dir = tempDir(t);
  const home = resolve(dir, "personal");
  const manifestPath = resolve(dir, "manifest.json");
  writeManifest(manifestPath);
  const downloads = resolve(dir, "downloads");
  mkdirSync(downloads);
  writeFileSync(resolve(downloads, "claude"), "wrong bytes");
  writeFileSync(resolve(downloads, "codex.tar.gz"), "wrong bytes");
  const log = resolve(dir, "engine.log");
  const engine = resolve(dir, "engine");
  writeExecutable(
    engine,
    `#!/bin/sh
printf '%s\\n' "$*" >> '${log}'
exit 0
`,
  );
  const result = run(CLI, ["claude", "must-not-launch"], {
    env: {
      AGENTBOX_TEST_MODE: "1",
      AGENTBOX_TEST_MANIFEST: manifestPath,
      AGENTBOX_TEST_ENGINE: engine,
      AGENTBOX_TEST_DOWNLOAD_DIR: downloads,
      AGENTBOX_HOME: home,
      GH_TOKEN: "test",
    },
  });
  assert.notEqual(result.status, 0);
  const calls = existsSync(log) ? readFileSync(log, "utf8") : "";
  assert.doesNotMatch(calls, / run --protocol 1 --mode /);
  assert.equal(existsSync(resolve(home, "runtime", "activation.json")), false);
});

test("managed-content mutation fails closed until explicit setup repairs it", (t) => {
  const prepared = fixture(t);
  const activationPath = resolve(prepared.home, "runtime", "activation.json");
  const activation = JSON.parse(readFileSync(activationPath, "utf8"));
  const executable = resolve(activation.current.release_path, "vendor/claude/claude");
  chmodSync(executable, 0o755);
  writeFileSync(executable, "tampered\n", { mode: 0o555 });
  chmodSync(executable, 0o555);

  const observeEngine = recordingEngine(prepared.dir);
  const common = {
    AGENTBOX_TEST_MODE: "1",
    AGENTBOX_TEST_MANIFEST: prepared.manifestPath,
    AGENTBOX_TEST_ENGINE: observeEngine.path,
    AGENTBOX_HOME: prepared.home,
    GH_TOKEN: "test",
  };
  assert.notEqual(run(CLI, ["info", "--json"], { env: common }).status, 0);
  assert.notEqual(run(CLI, ["doctor", "--json"], { env: common }).status, 0);
  assert.notEqual(run(CLI, ["--no-update", "claude"], { env: common }).status, 0);
  const observed = existsSync(observeEngine.argv) ? readNul(observeEngine.argv) : [];
  assert.equal(observed.includes("--mode"), false);

  const repairEngine = resolve(prepared.dir, "repair-engine");
  writeProtocolEngine(repairEngine);
  expectExit(
    run(CLI, ["setup"], {
      env: {
        ...common,
        AGENTBOX_TEST_ENGINE: repairEngine,
        AGENTBOX_TEST_DOWNLOAD_DIR: prepared.downloads,
      },
    }),
    0,
    "explicit repair",
  );
  const repairedInfo = run(CLI, ["info", "--json"], { env: common });
  expectExit(repairedInfo, 0, "repaired info");
  assert.equal(JSON.parse(repairedInfo.stdout).state, "ready");
  assert.notEqual(readFileSync(executable, "utf8"), "tampered\n");
});

test("installed layout rejects home override and ignores ambient/source-only overrides", (t) => {
  const dir = tempDir(t);
  const prefix = resolve(dir, "prefix");
  for (const path of ["bin", "libexec/agentbox", "share/agentbox"]) {
    mkdirSync(resolve(prefix, path), { recursive: true });
  }
  copyFileSync(resolve(ROOT, "bin/agentbox"), resolve(prefix, "bin/agentbox"));
  copyFileSync(resolve(ROOT, "libexec/host.sh"), resolve(prefix, "libexec/agentbox/host.sh"));
  copyFileSync(resolve(ROOT, "libexec/state.py"), resolve(prefix, "libexec/agentbox/state.py"));
  copyFileSync(resolve(ROOT, "VERSION"), resolve(prefix, "share/agentbox/VERSION"));
  const installedManifest = resolve(prefix, "share/agentbox/release-manifest.json");
  writeManifest(installedManifest);
  const home = resolve(dir, "home");
  const installed = resolve(prefix, "bin/agentbox");
  const rejected = run(installed, ["info", "--json"], {
    env: {
      AGENTBOX_HOME: home,
    },
  });
  assert.notEqual(rejected.status, 0);
  assert.match(rejected.stderr, /source-checkout-only override|rejected by the installed/i);
  assert.equal(existsSync(home), false);

  const result = run(installed, ["info", "--json"], {
    env: {
      HOME: home,
      AGENTBOX_TEST_MODE: "1",
      AGENTBOX_TEST_MANIFEST: resolve(dir, "attacker-test.json"),
      AGENTBOX_TEST_ENGINE: resolve(dir, "attacker-engine"),
      AGENTBOX_DEV_MODE: "1",
      AGENTBOX_DEV_MANIFEST: resolve(dir, "attacker-dev.json"),
    },
  });
  expectExit(result, 0, "installed info");
  const output = JSON.parse(result.stdout);
  assert.equal(output.manifest, realpathSync(installedManifest));
  assert.equal(output.launcher, realpathSync(resolve(prefix, "bin/agentbox")));
  assert.doesNotMatch(output.manifest, /\/\.\.\//);
  assert.doesNotMatch(output.launcher, /\/\.\.\//);
  assert.equal(output.development, false);
  assert.equal(existsSync(home), false);
});

test("physical /tmp working directory is mounted at its resolved path", (t) => {
  const prepared = fixture(t);
  const logical = mkdtempSync("/tmp/agentbox-cwd-");
  t.after(() => rmSync(logical, { recursive: true, force: true }));
  const physical = realpathSync(logical);
  const physicalTmp = realpathSync("/tmp");
  const engine = recordingEngine(prepared.dir, 42);
  const result = run(CLI, ["claude", "physical-cwd"], {
    cwd: logical,
    env: {
      ...process.env,
      AGENTBOX_TEST_MODE: "1",
      AGENTBOX_TEST_MANIFEST: prepared.manifestPath,
      AGENTBOX_TEST_ENGINE: engine.path,
      AGENTBOX_HOME: prepared.home,
      GH_TOKEN: "test",
    },
  });
  expectExit(result, 42, "physical cwd launch");
  const argv = readNul(engine.argv);
  const workdir = argv.indexOf("-w");
  assert.notEqual(workdir, -1);
  assert.equal(argv[workdir + 1], physical);
  assert.ok(
    argv.some((arg) => arg === `type=bind,src=${physicalTmp},dst=${physicalTmp}`),
  );
});
