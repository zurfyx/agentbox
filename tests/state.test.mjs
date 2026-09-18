import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  readFileSync,
  symlinkSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { resolve } from "node:path";
import test from "node:test";
import {
  AGENTBOX_VERSION,
  bindArtifacts,
  canonical,
  createVendorDownloads,
  HEX_A,
  manifest,
  sha256,
  writeManifest,
} from "./fixtures.mjs";
import {
  ROOT,
  expectExit,
  run,
  tempDir,
  writeProtocolEngine,
} from "./helpers.mjs";

const STATE = resolve(ROOT, "libexec/state.py");
const VERSION = AGENTBOX_VERSION;
const OTHER_VERSION = VERSION === "0.1.1" ? "0.1.2" : "0.1.1";

function state(args, options) {
  return run("python3", ["-I", STATE, "--expected-version", VERSION, ...args], options);
}

test("strict manifest accepts the complete pinned release contract", (t) => {
  const dir = tempDir(t);
  const path = resolve(dir, "manifest.json");
  writeManifest(path);
  const result = state(["validate-manifest", path]);
  expectExit(result, 0, "valid manifest");
  const output = JSON.parse(result.stdout);
  assert.equal(output.agentbox_version, VERSION);
  assert.match(output.manifest_sha256, /^[0-9a-f]{64}$/);
});

test("manifest accepts safe Codex package layout evolution", (t) => {
  const dir = tempDir(t);
  const path = resolve(dir, "manifest.json");
  const value = manifest();
  value.tools.codex.allowed_members.push(
    "codex-resources/voice/",
    "codex-resources/voice/bin/",
    "codex-resources/voice/bin/codex-voice-host",
  );
  value.tools.codex.allowed_members.sort();
  writeManifest(path, value);
  expectExit(state(["validate-manifest", path]), 0, "safe evolved Codex layout");
});

test("manifest version must match the packaged version authority", (t) => {
  const dir = tempDir(t);
  const path = resolve(dir, "manifest.json");
  writeManifest(path);
  expectExit(
    run("python3", [
      "-I",
      STATE,
      "--expected-version",
      OTHER_VERSION,
      "validate-manifest",
      path,
    ]),
    65,
    "mismatched parent version",
  );
});

test("hostile manifest corpus is rejected", async (t) => {
  const cases = {
    "unknown top-level key": (value) => {
      value.surprise = true;
    },
    "mutable runtime image": (value) => {
      value.runtime.image = "ghcr.io/zurfyx/agentbox-runtime:latest";
    },
    "wrong runtime repository": (value) => {
      value.runtime.image = `ghcr.io/attacker/agentbox-runtime@sha256:${HEX_A}`;
    },
    "missing platform": (value) => {
      value.tools.claude.platforms.pop();
    },
    "non-HTTPS artifact": (value) => {
      value.tools.claude.platforms[0].url = "http://downloads.claude.ai/bad";
    },
    "uppercase digest": (value) => {
      value.tools.codex.platforms[1].sha256 = HEX_A.toUpperCase();
    },
    "version and URL mismatch": (value) => {
      value.tools.codex.version = "0.155.0";
    },
    "wrong Agentbox release version": (value) => {
      value.agentbox_version = OTHER_VERSION;
    },
    "noncanonical artifact URL": (value) => {
      value.tools.codex.platforms[0].url =
        "https://releases.openai.com/codex/releases/0.154.0/%2e%2e/0.154.0/codex-package-aarch64-unknown-linux-musl.tar.gz";
    },
    "unexpected package member": (value) => {
      value.tools.codex.allowed_members.push("outside/unreviewed");
    },
    "missing required package member": (value) => {
      value.tools.codex.allowed_members =
        value.tools.codex.allowed_members.filter((item) => item !== "bin/codex-code-mode-host");
    },
    "oversize artifact": (value) => {
      value.tools.claude.platforms[0].size = 512 * 1024 * 1024 + 1;
    },
    "boolean artifact size": (value) => {
      value.tools.claude.platforms[1].size = true;
    },
  };
  for (const [name, mutate] of Object.entries(cases)) {
    await t.test(name, () => {
      const dir = tempDir(t);
      const path = resolve(dir, "manifest.json");
      const value = manifest();
      mutate(value);
      writeManifest(path, value);
      expectExit(state(["validate-manifest", path]), 65, name);
    });
  }
});

test("duplicate manifest keys are rejected", (t) => {
  const dir = tempDir(t);
  const path = resolve(dir, "manifest.json");
  const valid = canonical(manifest()).trim();
  writeFileSync(path, valid.replace('"schema_version":1', '"schema_version":1,"schema_version":1') + "\n");
  expectExit(state(["validate-manifest", path]), 65, "duplicate-key manifest");
});

test("noncanonical release manifest encoding is rejected", (t) => {
  const dir = tempDir(t);
  const path = resolve(dir, "manifest.json");
  writeFileSync(path, JSON.stringify(manifest(), null, 2) + "\n");
  expectExit(state(["validate-manifest", path]), 65, "noncanonical manifest");
});

test("manifest validation cannot mix parsed and hashed rename generations", async (t) => {
  const dir = tempDir(t);
  const path = resolve(dir, "manifest.json");
  const first = canonical(manifest());
  const secondValue = manifest();
  secondValue.runtime.image =
    `ghcr.io/zurfyx/agentbox-runtime@sha256:${"b".repeat(64)}`;
  const noncanonicalSecond = JSON.stringify(secondValue, null, 2) + "\n";
  writeFileSync(path, first);
  const expectedDigest = sha256(Buffer.from(first));
  expectExit(state(["validate-manifest", path]), 0, "initial manifest");

  const writerSource = [
    "import os,pathlib,sys,time",
    "path=pathlib.Path(sys.argv[1])",
    "values=[bytes.fromhex(sys.argv[2]),bytes.fromhex(sys.argv[3])]",
    "for index in range(1200):",
    " temporary=path.with_name('.manifest.concurrent')",
    " temporary.write_bytes(values[index%2])",
    " os.replace(temporary,path)",
    " time.sleep(.001)",
  ].join("\n");
  const writer = spawn("python3", [
    "-c",
    writerSource,
    path,
    Buffer.from(first).toString("hex"),
    Buffer.from(noncanonicalSecond).toString("hex"),
  ]);
  let successes = 0;
  for (let index = 0; index < 20; index += 1) {
    const result = state(["validate-manifest", path]);
    if (result.status === 0) {
      successes += 1;
      assert.equal(JSON.parse(result.stdout).manifest_sha256, expectedDigest);
    } else {
      assert.equal(result.status, 65);
    }
  }
  assert.ok(successes > 0);
  await new Promise((resolvePromise, reject) => {
    writer.once("error", reject);
    writer.once("exit", (code) =>
      code === 0 ? resolvePromise() : reject(new Error(`writer exited ${code}`)),
    );
  });
});

test("inspect of absent state is observational", (t) => {
  const dir = tempDir(t);
  const root = resolve(dir, "missing", "runtime");
  const path = resolve(dir, "manifest.json");
  writeManifest(path);
  const result = state(["inspect", "--root", root, "--manifest", path]);
  expectExit(result, 0, "absent state inspection");
  assert.equal(JSON.parse(result.stdout).state, "absent");
  assert.equal(existsSync(root), false);
});

test("managed root rejects symlink ancestry and unsafe ownership modes", (t) => {
  const dir = tempDir(t);
  const actual = resolve(dir, "actual");
  mkdirSync(actual);
  symlinkSync(actual, resolve(dir, "linked"));
  const linked = state(["inspect", "--root", resolve(dir, "linked/runtime")]);
  assert.equal(linked.status, 65);
  assert.match(linked.stderr, /not a plain directory/);

  const shared = resolve(dir, "shared");
  mkdirSync(shared, { mode: 0o777 });
  chmodSync(shared, 0o777);
  const unsafe = state(["inspect", "--root", resolve(shared, "runtime")]);
  assert.equal(unsafe.status, 65);
  assert.match(unsafe.stderr, /writable by another user/);
});

test("reuse identity includes shared tool data and only the selected platform artifact", (t) => {
  const dir = tempDir(t);
  const root = resolve(dir, "home", "runtime");
  const artifacts = createVendorDownloads(dir);
  const bind = (value) => {
    bindArtifacts(value, artifacts);
    value.managed_files.runtime_instructions.sha256 = sha256(
      readFileSync(resolve(ROOT, "runtime/instructions.md")),
    );
    value.managed_files.statusline.sha256 = sha256(
      readFileSync(resolve(ROOT, "runtime/statusline.sh")),
    );
    return value;
  };
  const engine = resolve(dir, "engine");
  writeProtocolEngine(engine);
  const options = {
    env: {
      AGENTBOX_TEST_MODE: "1",
      AGENTBOX_TEST_DOWNLOAD_DIR: artifacts.downloads,
    },
  };
  const firstPath = resolve(dir, "first.json");
  const firstValue = bind(manifest());
  writeManifest(firstPath, firstValue);
  expectExit(state([
    "prepare", "--agent", "claude", "--root", root, "--manifest", firstPath, "--engine", engine,
  ], options), 0, "initial selected-platform prepare");
  const first = JSON.parse(readFileSync(resolve(root, "activation.json"), "utf8"));

  const hostPlatform = process.arch === "arm64" ? "linux/arm64" : "linux/amd64";
  const otherPlatform = hostPlatform === "linux/arm64" ? "linux/amd64" : "linux/arm64";
  const secondValue = structuredClone(firstValue);
  const other = secondValue.tools.claude.platforms.find((item) => item.platform === otherPlatform);
  other.sha256 = "c".repeat(64);
  other.size += 1;
  const secondPath = resolve(dir, "second.json");
  writeManifest(secondPath, secondValue);
  unlinkSync(resolve(artifacts.downloads, "claude"));
  expectExit(state([
    "prepare", "--agent", "claude", "--root", root, "--manifest", secondPath, "--engine", engine,
  ], options), 0, "reuse across non-host platform metadata change");
  const second = JSON.parse(readFileSync(resolve(root, "activation.json"), "utf8"));
  assert.notEqual(second.current.manifest_sha256, first.current.manifest_sha256);
  assert.deepEqual(second.previous, first.current);

  const thirdValue = structuredClone(secondValue);
  const selected = thirdValue.tools.claude.platforms.find((item) => item.platform === hostPlatform);
  selected.sha256 = "d".repeat(64);
  selected.size += 1;
  const thirdPath = resolve(dir, "third.json");
  writeManifest(thirdPath, thirdValue);
  const changedSelected = state([
    "prepare", "--agent", "claude", "--root", root, "--manifest", thirdPath, "--engine", engine,
  ], options);
  expectExit(changedSelected, 65, "changed selected platform is not reused");
  assert.match(changedSelected.stderr, /test download fixture is missing: claude/);
  assert.deepEqual(JSON.parse(readFileSync(resolve(root, "activation.json"), "utf8")), second);
});

test("manual rollback hold stays visible when the requested agent is absent", (t) => {
  const dir = tempDir(t);
  const root = resolve(dir, "home", "runtime");
  const artifacts = createVendorDownloads(dir);
  const bind = (value) => {
    bindArtifacts(value, artifacts);
    value.managed_files.runtime_instructions.sha256 = sha256(
      readFileSync(resolve(ROOT, "runtime/instructions.md")),
    );
    value.managed_files.statusline.sha256 = sha256(
      readFileSync(resolve(ROOT, "runtime/statusline.sh")),
    );
    return value;
  };
  const options = { env: { AGENTBOX_TEST_MODE: "1", AGENTBOX_TEST_DOWNLOAD_DIR: artifacts.downloads } };
  const engine = resolve(dir, "engine");
  const engineLog = resolve(dir, "engine.log");
  writeProtocolEngine(engine, { logPath: engineLog });
  const firstPath = resolve(dir, "first.json");
  writeManifest(firstPath, bind(manifest()));
  expectExit(state([
    "prepare", "--agent", "claude", "--root", root, "--manifest", firstPath, "--engine", engine,
  ], options), 0, "partial rollback target");
  const first = JSON.parse(readFileSync(resolve(root, "activation.json"), "utf8"));

  const secondValue = bind(manifest());
  secondValue.runtime.image = `ghcr.io/zurfyx/agentbox-runtime@sha256:${"b".repeat(64)}`;
  const secondPath = resolve(dir, "second.json");
  writeManifest(secondPath, secondValue);
  expectExit(state([
    "prepare", "--agent", "all", "--root", root, "--manifest", secondPath, "--engine", engine,
  ], options), 0, "full successor");
  expectExit(state([
    "rollback", "--root", root, "--accept-vendor-state-risk",
  ]), 0, "rollback to partial release");
  const held = JSON.parse(readFileSync(resolve(root, "activation.json"), "utf8"));
  assert.deepEqual(held.current, first.current);
  const inspection = JSON.parse(state([
    "inspect", "--agent", "codex", "--root", root, "--manifest", secondPath,
  ]).stdout);
  assert.equal(inspection.state, "manual-rollback-hold");
  assert.deepEqual(inspection.ready_agents, ["claude"]);

  const logBefore = readFileSync(engineLog, "utf8");
  const blocked = state([
    "prepare", "--agent", "codex", "--root", root, "--manifest", secondPath, "--engine", engine,
  ], options);
  expectExit(blocked, 65, "held selective prepare");
  assert.match(blocked.stderr, /manual rollback hold|reset-selector/i);
  assert.equal(readFileSync(engineLog, "utf8"), logBefore);
  assert.deepEqual(JSON.parse(readFileSync(resolve(root, "activation.json"), "utf8")), held);

  expectExit(state([
    "prepare", "--reset-selector", "--agent", "all", "--root", root,
    "--manifest", secondPath, "--engine", engine,
  ], options), 0, "explicit selector reset");
  const reset = JSON.parse(readFileSync(resolve(root, "activation.json"), "utf8"));
  assert.equal(reset.selection.mode, "normal");
  assert.equal(reset.previous, null);
  assert.notEqual(reset.current.release_id, first.current.release_id);
});

test("activation is coherent, idempotent, and retains last good on failure", async (t) => {
  const dir = tempDir(t);
  const root = resolve(dir, "home", "runtime");
  const opaque = resolve(dir, "home", ".claude", "settings.json");
  mkdirSync(resolve(dir, "home", ".claude"), { recursive: true });
  writeFileSync(opaque, '{"owned":"vendor"}\n');

  const artifacts = createVendorDownloads(dir);
  const downloads = artifacts.downloads;
  const withArtifacts = (value) => {
    bindArtifacts(value, artifacts);
    value.managed_files.runtime_instructions.sha256 = sha256(
      readFileSync(resolve(ROOT, "runtime/instructions.md")),
    );
    value.managed_files.statusline.sha256 = sha256(
      readFileSync(resolve(ROOT, "runtime/statusline.sh")),
    );
    return value;
  };
  const stateEnv = {
    env: {
      AGENTBOX_TEST_MODE: "1",
      AGENTBOX_TEST_DOWNLOAD_DIR: downloads,
    },
  };
  const first = resolve(dir, "first.json");
  writeManifest(first, withArtifacts(manifest()));
  const goodEngine = resolve(dir, "good-engine");
  writeProtocolEngine(goodEngine);

  expectExit(
    state(["prepare", "--root", root, "--manifest", first, "--engine", goodEngine], stateEnv),
    0,
    "initial prepare",
  );
  const initial = JSON.parse(readFileSync(resolve(root, "activation.json"), "utf8"));
  assert.equal(initial.generation, 1);
  assert.equal(initial.previous, null);

  expectExit(
    state(["prepare", "--root", root, "--manifest", first, "--engine", goodEngine], stateEnv),
    0,
    "idempotent prepare",
  );
  assert.deepEqual(
    JSON.parse(readFileSync(resolve(root, "activation.json"), "utf8")),
    initial,
  );

  const secondValue = withArtifacts(manifest());
  secondValue.runtime.image = `ghcr.io/zurfyx/agentbox-runtime@sha256:${"b".repeat(64)}`;
  const second = resolve(dir, "second.json");
  writeManifest(second, secondValue);
  expectExit(
    state(["prepare", "--root", root, "--manifest", second, "--engine", goodEngine], stateEnv),
    0,
    "second prepare",
  );
  const advanced = JSON.parse(readFileSync(resolve(root, "activation.json"), "utf8"));
  assert.equal(advanced.generation, 2);
  assert.notEqual(advanced.current.manifest_sha256, initial.current.manifest_sha256);
  assert.deepEqual(advanced.previous, initial.current);
  assert.equal(advanced.selection.mode, "normal");
  assert.equal(readFileSync(resolve(root, "activation.json"), "utf8"), canonical(advanced));
  const unsignedAdvanced = { ...advanced };
  delete unsignedAdvanced.checksum;
  assert.equal(advanced.checksum, `sha256:${sha256(canonical(unsignedAdvanced))}`);

  const unsignedAlternate = {
    ...advanced,
    generation: advanced.generation + 1,
    current: initial.current,
    previous: advanced.current,
  };
  delete unsignedAlternate.checksum;
  const alternate = {
    ...unsignedAlternate,
    checksum: `sha256:${sha256(canonical(unsignedAlternate))}`,
  };
  const writerSource = [
    "import os,pathlib,sys,time",
    "path=pathlib.Path(sys.argv[1])",
    "values=[bytes.fromhex(sys.argv[2]),bytes.fromhex(sys.argv[3])]",
    "for index in range(1500):",
    " temporary=path.with_name('.activation.concurrent')",
    " temporary.write_bytes(values[index%2])",
    " os.replace(temporary,path)",
    " time.sleep(.001)",
  ].join("\n");
  const writer = spawn("python3", [
    "-c",
    writerSource,
    resolve(root, "activation.json"),
    Buffer.from(canonical(advanced)).toString("hex"),
    Buffer.from(canonical(alternate)).toString("hex"),
  ]);
  const coherent = new Set([
    `${advanced.current.release_path}\0${advanced.current.runtime_image}`,
    `${alternate.current.release_path}\0${alternate.current.runtime_image}`,
  ]);
  for (let index = 0; index < 20; index += 1) {
    const result = state(["launch-plan", "--root", root]);
    expectExit(result, 0, "concurrent launch plan");
    const current = JSON.parse(result.stdout).current;
    assert.ok(coherent.has(`${current.release_path}\0${current.runtime_image}`));
  }
  await new Promise((resolvePromise, reject) => {
    writer.once("error", reject);
    writer.once("exit", (code) =>
      code === 0 ? resolvePromise() : reject(new Error(`writer exited ${code}`)),
    );
  });
  writeFileSync(resolve(root, "activation.json"), canonical(advanced));
  chmodSync(resolve(root, "activation.json"), 0o600);

  expectExit(
    state(["rollback", "--root", root]),
    65,
    "rollback without risk acceptance",
  );
  const rolledBackResult = state([
    "rollback",
    "--root",
    root,
    "--accept-vendor-state-risk",
  ]);
  expectExit(rolledBackResult, 0, "rollback");
  const rolledBack = JSON.parse(readFileSync(resolve(root, "activation.json"), "utf8"));
  assert.equal(rolledBack.generation, 3);
  assert.deepEqual(rolledBack.current, initial.current);
  assert.deepEqual(rolledBack.previous, advanced.current);
  assert.deepEqual(rolledBack.selection, {
    mode: "manual_rollback_hold",
    reason: "vendor_state_risk_accepted",
  });
  const heldForCodex = JSON.parse(
    state(["inspect", "--agent", "codex", "--root", root, "--manifest", second]).stdout,
  );
  assert.equal(heldForCodex.state, "manual-rollback-hold");
  assert.deepEqual(heldForCodex.ready_agents, ["claude", "codex"]);

  const heldPrepare = state(
    ["prepare", "--root", root, "--manifest", second, "--engine", goodEngine],
    stateEnv,
  );
  expectExit(heldPrepare, 65, "prepare under rollback hold");
  assert.match(heldPrepare.stderr, /manual rollback hold|reset-selector/i);
  assert.deepEqual(
    JSON.parse(readFileSync(resolve(root, "activation.json"), "utf8")),
    rolledBack,
  );
  expectExit(
    state([
      "prepare",
      "--reset-selector",
      "--root",
      root,
      "--manifest",
      second,
      "--engine",
      goodEngine,
    ], stateEnv),
    0,
    "selector reset",
  );
  const reset = JSON.parse(readFileSync(resolve(root, "activation.json"), "utf8"));
  assert.deepEqual(reset.current, advanced.current);
  assert.equal(reset.previous, null);
  assert.deepEqual(reset.selection, { mode: "normal", reason: null });

  const thirdValue = withArtifacts(manifest());
  thirdValue.runtime.image = `ghcr.io/zurfyx/agentbox-runtime@sha256:${"c".repeat(64)}`;
  const third = resolve(dir, "third.json");
  writeManifest(third, thirdValue);
  const failedEngine = resolve(dir, "failed-engine");
  writeProtocolEngine(failedEngine, { failValidate: true });
  assert.notEqual(
    state(["prepare", "--root", root, "--manifest", third, "--engine", failedEngine], stateEnv).status,
    0,
  );
  assert.deepEqual(
    JSON.parse(readFileSync(resolve(root, "activation.json"), "utf8")),
    reset,
  );
  assert.equal(readFileSync(opaque, "utf8"), '{"owned":"vendor"}\n');
});
