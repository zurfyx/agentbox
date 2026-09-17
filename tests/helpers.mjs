import assert from "node:assert/strict";
import {
  existsSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import {
  AGENTBOX_VERSION,
  bindArtifacts,
  createVendorDownloads,
  manifest,
  sha256,
  writeManifest,
} from "./fixtures.mjs";

export const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
export const PYTHON = spawnSync("/bin/sh", ["-c", "command -v python3"], {
  encoding: "utf8",
}).stdout.trim();

export function run(command, args = [], options = {}) {
  const environment = { ...process.env, ...options.env };
  for (const [name, value] of Object.entries(options.env ?? {})) {
    if (value === null || value === undefined) delete environment[name];
  }
  return spawnSync(command, args, {
    cwd: options.cwd ?? ROOT,
    encoding: "utf8",
    env: environment,
    input: options.input,
    timeout: options.timeout ?? 30_000,
  });
}

export function expectExit(result, status, context = "command") {
  assert.equal(
    result.error,
    undefined,
    `${context} failed to start: ${result.error?.message}`,
  );
  assert.equal(
    result.status,
    status,
    `${context} exited ${result.status}\nstdout:\n${result.stdout}\nstderr:\n${result.stderr}`,
  );
}

export function tempDir(t) {
  const path = realpathSync(mkdtempSync(resolve(tmpdir(), "agentbox-test-")));
  t.after(() => rmSync(path, { recursive: true, force: true }));
  return path;
}

export function writeExecutable(path, source) {
  writeFileSync(path, source, { mode: 0o755 });
}

export function readNul(path) {
  const bytes = readFileSync(path);
  assert.equal(bytes.at(-1), 0, "record must end in NUL");
  return bytes.subarray(0, -1).toString().split("\0");
}

export function writeProtocolEngine(
  path,
  { failValidate = false, logPath = `${path}.log`, runExit = 0 } = {},
) {
  const runtime = resolve(ROOT, "runtime/runtime");
  const share = resolve(ROOT, "runtime");
  writeExecutable(
    path,
    `#!/bin/sh
printf '%s\\n' "$*" >> '${logPath}'
if [ "$1" = pull ]; then exit 0; fi
if [ "$1" = version ]; then exit 0; fi
if [ "$1" = image ] && [ "$2" = inspect ]; then exit 0; fi
mount_source=
platform=
agent=all
reuse=
previous=
for argument in "$@"; do
  if [ "$previous" = --platform ]; then platform="$argument"; fi
  if [ "$previous" = --agent ]; then agent="$argument"; fi
  if [ "$previous" = --reuse ]; then reuse="$argument"; fi
  previous="$argument"
  case "$argument" in
    type=bind,src=*,dst=/opt/agentbox-release*)
      mount_source=$(printf '%s' "$argument" | sed 's/^type=bind,src=//;s/,dst=\\/opt\\/agentbox-release.*$//')
      ;;
  esac
done
case " $* " in
  *" prepare --protocol "*)
    reuse_args=
    if [ -n "$reuse" ]; then reuse_args="--reuse $mount_source/reuse"; fi
    exec env AGENTBOX_INTERNAL_TESTING=1 AGENTBOX_TEST_SHARE_ROOT='${share}' \
      '${PYTHON}' '${runtime}' prepare --protocol 1 --platform "$platform" \
      --agent "$agent" $reuse_args \
      --manifest "$mount_source/manifest.json" --downloads "$mount_source/downloads" \
      --output "$mount_source/vendor"
    ;;
  *" validate --protocol "*)
    ${failValidate ? "exit 23" : ""}
    exec env AGENTBOX_INTERNAL_TESTING=1 AGENTBOX_TEST_SHARE_ROOT='${share}' \
      '${PYTHON}' '${runtime}' validate --protocol 1 --platform "$platform" \
      --agent "$agent" \
      --manifest "$mount_source/manifest.json" --candidate "$mount_source/vendor"
    ;;
  *" run --protocol 1 --mode "*) exit ${runExit} ;;
esac
exit 0
`,
  );
  return { logPath, path };
}

export function preparedLaunchFixture(t) {
  const dir = tempDir(t);
  const home = resolve(dir, "personal");
  const runtimeRoot = resolve(home, "runtime");
  const artifacts = createVendorDownloads(dir);
  const value = bindArtifacts(manifest(), artifacts);
  value.managed_files.runtime_instructions.sha256 = sha256(
    readFileSync(resolve(ROOT, "runtime/instructions.md")),
  );
  value.managed_files.statusline.sha256 = sha256(
    readFileSync(resolve(ROOT, "runtime/statusline.sh")),
  );
  const manifestPath = resolve(dir, "release-manifest.json");
  writeManifest(manifestPath, value);

  const setupEngine = resolve(dir, "setup-engine");
  writeProtocolEngine(setupEngine);
  const prepared = run(
    "python3",
    [
      "-I",
      resolve(ROOT, "libexec/state.py"),
      "--expected-version",
      AGENTBOX_VERSION,
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
        AGENTBOX_TEST_DOWNLOAD_DIR: artifacts.downloads,
      },
    },
  );
  expectExit(prepared, 0, "fixture state preparation");
  return {
    dir,
    downloads: artifacts.downloads,
    home,
    manifestPath,
    runtimeRoot,
  };
}

export function recordingEngine(dir, exitCode = 0, name = `engine-${exitCode}`) {
  const path = resolve(dir, name);
  const argv = `${path}.argv`;
  const calls = `${path}.calls`;
  const environment = `${path}.env`;
  writeExecutable(
    path,
    `#!/bin/sh
printf '%s\\n' "$*" >> '${calls}'
if [ "$1" = image ] && [ "$2" = inspect ]; then exit 0; fi
if [ "$1" = version ]; then exit 0; fi
printf '%s\\0' "$@" > '${argv}'
env > '${environment}'
exit ${exitCode}
`,
  );
  return {
    argv,
    calls,
    environment,
    path,
    wasCalled: () => existsSync(calls),
  };
}
