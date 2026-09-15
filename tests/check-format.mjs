#!/usr/bin/env node
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { format } from "@wasm-fmt/shfmt";

const listing = spawnSync(
  "git",
  [
    "ls-files",
    "-co",
    "--exclude-standard",
    "--",
    "*.sh",
    "bin/*",
    "libexec/*.sh",
    "runtime/*",
    "scripts/*.sh",
  ],
  { encoding: "utf8" },
);
if (listing.status !== 0) {
  process.stderr.write(listing.stderr);
  process.exit(listing.status ?? 1);
}

const write = process.argv.includes("--write");
let changed = false;
for (const path of listing.stdout.trim().split("\n").filter(Boolean)) {
  if (!existsSync(path)) continue;
  // This file is a byte-pinned external payload, not repository-owned source.
  if (path === "runtime/statusline.sh") continue;
  const source = readFileSync(path, "utf8");
  if (!path.endsWith(".sh") && !/^#!.*(?:ba|z|k)?sh/.test(source.slice(0, 256))) {
    continue;
  }
  const formatted = format(source, path, {
    indent: 2,
    simplify: true,
    spaceRedirects: true,
    switchCaseIndent: true,
  });
  if (formatted === source) continue;
  changed = true;
  if (write) {
    writeFileSync(path, formatted);
  } else {
    process.stderr.write(`${path} is not shfmt-formatted\n`);
  }
}
if (changed && !write) process.exit(1);
