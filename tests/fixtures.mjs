import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";

export const HEX_A = "a".repeat(64);
export const HEX_B = "b".repeat(64);
export const AGENTBOX_VERSION = readFileSync(new URL("../VERSION", import.meta.url), "utf8").trim();
export const CODEX_MEMBERS = [
  "bin/",
  "bin/codex",
  "bin/codex-code-mode-host",
  "codex-package.json",
  "codex-path/",
  "codex-path/rg",
  "codex-resources/",
  "codex-resources/bwrap",
  "codex-resources/zsh/",
  "codex-resources/zsh/bin/",
  "codex-resources/zsh/bin/zsh",
];

export function manifest(overrides = {}) {
  const version = overrides.agentbox_version ?? AGENTBOX_VERSION;
  return {
    schema_version: 1,
    agentbox_version: version,
    runtime_protocol_version: 1,
    runtime: {
      image: `ghcr.io/zurfyx/agentbox-runtime@sha256:${HEX_A}`,
    },
    tools: {
      claude: {
        version: "2.1.272",
        kind: "raw-executable",
        platforms: [
          {
            platform: "linux/arm64",
            url: "https://downloads.claude.ai/claude-code-releases/2.1.272/linux-arm64/claude",
            sha256: HEX_A,
            size: 11,
          },
          {
            platform: "linux/amd64",
            url: "https://downloads.claude.ai/claude-code-releases/2.1.272/linux-x64/claude",
            sha256: HEX_B,
            size: 12,
          },
        ],
      },
      codex: {
        version: "0.154.0",
        kind: "tar.gz-package",
        layout_version: 1,
        entrypoint: "bin/codex",
        allowed_members: [...CODEX_MEMBERS],
        platforms: [
          {
            platform: "linux/arm64",
            target: "aarch64-unknown-linux-musl",
            url: "https://releases.openai.com/codex/releases/0.154.0/codex-package-aarch64-unknown-linux-musl.tar.gz",
            sha256: HEX_A,
            size: 21,
          },
          {
            platform: "linux/amd64",
            target: "x86_64-unknown-linux-musl",
            url: "https://releases.openai.com/codex/releases/0.154.0/codex-package-x86_64-unknown-linux-musl.tar.gz",
            sha256: HEX_B,
            size: 22,
          },
        ],
      },
    },
    managed_files: {
      runtime_instructions: {
        path: "/usr/local/share/agentbox/instructions.md",
        sha256: HEX_A,
      },
      statusline: {
        path: "/usr/local/share/agentbox/statusline.sh",
        sha256: HEX_B,
      },
    },
    ...overrides,
  };
}

export function canonical(value) {
  const sort = (item) => {
    if (Array.isArray(item)) return item.map(sort);
    if (item && typeof item === "object") {
      return Object.fromEntries(
        Object.keys(item)
          .sort()
          .map((key) => [key, sort(item[key])]),
      );
    }
    return item;
  };
  return `${JSON.stringify(sort(value))}\n`;
}

export function writeManifest(path, value = manifest()) {
  writeFileSync(path, canonical(value));
  return value;
}

export function sha256(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

export function createVendorDownloads(dir) {
  const downloads = resolve(dir, "downloads");
  const archiveRoot = resolve(dir, "archive");
  mkdirSync(downloads);
  const vendor = (name) => `#!/bin/sh
case "$1" in
  --version) echo "${name} ${name === "claude" ? "2.1.272" : "0.154.0"}" ;;
  --help) echo "fake help" ;;
esac
exit 0
`;
  const claude = Buffer.from(vendor("claude"));
  writeFileSync(resolve(downloads, "claude"), claude);
  const target =
    process.arch === "arm64"
      ? "aarch64-unknown-linux-musl"
      : "x86_64-unknown-linux-musl";
  for (const member of CODEX_MEMBERS) {
    const path = resolve(archiveRoot, member);
    if (member.endsWith("/")) {
      mkdirSync(path, { recursive: true });
      continue;
    }
    mkdirSync(resolve(path, ".."), { recursive: true });
    const content =
      member === "codex-package.json"
        ? JSON.stringify({
            entrypoint: "bin/codex",
            layoutVersion: 1,
            pathDir: "codex-path",
            resourcesDir: "codex-resources",
            target,
            variant: "codex",
            version: "0.154.0",
          })
        : member === "bin/codex"
          ? vendor("codex")
          : "fixture\n";
    writeFileSync(path, content);
  }
  const archive = resolve(downloads, "codex.tar.gz");
  const builder = [
    "import pathlib,sys,tarfile",
    "root,archive=map(pathlib.Path,sys.argv[1:3])",
    "with tarfile.open(archive,'w:gz') as output:",
    " for name in sys.argv[3:]: output.add(root/name.rstrip('/'),arcname=name.rstrip('/'),recursive=False)",
  ].join("\n");
  execFileSync("python3", ["-c", builder, archiveRoot, archive, ...CODEX_MEMBERS]);
  return { claude, codex: readFileSync(archive), downloads };
}

export function bindArtifacts(value, artifacts) {
  for (const item of value.tools.claude.platforms) {
    item.size = artifacts.claude.length;
    item.sha256 = sha256(artifacts.claude);
  }
  for (const item of value.tools.codex.platforms) {
    item.size = artifacts.codex.length;
    item.sha256 = sha256(artifacts.codex);
  }
  return value;
}
