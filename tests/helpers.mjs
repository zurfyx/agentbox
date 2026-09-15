import assert from "node:assert/strict";
import {
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
if [ "$1" = image ] && [ "$2" = inspect ]; then exit 0; fi
mount_source=
platform=
previous=
for argument in "$@"; do
  if [ "$previous" = --platform ]; then platform="$argument"; fi
  previous="$argument"
  case "$argument" in
    type=bind,src=*,dst=/opt/agentbox-release*)
      mount_source=$(printf '%s' "$argument" | sed 's/^type=bind,src=//;s/,dst=\\/opt\\/agentbox-release.*$//')
      ;;
  esac
done
case " $* " in
  *" prepare --protocol "*)
    exec env AGENTBOX_INTERNAL_TESTING=1 AGENTBOX_TEST_SHARE_ROOT='${share}' \
      '${PYTHON}' '${runtime}' prepare --protocol 1 --platform "$platform" \
      --manifest "$mount_source/manifest.json" --downloads "$mount_source/downloads" \
      --output "$mount_source/vendor"
    ;;
  *" validate --protocol "*)
    ${failValidate ? "exit 23" : ""}
    exec env AGENTBOX_INTERNAL_TESTING=1 AGENTBOX_TEST_SHARE_ROOT='${share}' \
      '${PYTHON}' '${runtime}' validate --protocol 1 --platform "$platform" \
      --manifest "$mount_source/manifest.json" --candidate "$mount_source/vendor"
    ;;
  *" run --protocol 1 --mode "*) exit ${runExit} ;;
esac
exit 0
`,
  );
  return { logPath, path };
}
