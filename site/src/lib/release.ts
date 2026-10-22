// Release facts shown on the page, resolved once per build.
//
// The Homebrew tap is what `brew install` actually serves, so its formula
// decides the version. The release's provenance record names the runtime image
// and the source commit, and release-inputs.json at that commit is the exact
// tool record the release manifest was rendered from. None of these requests
// use the rate-limited GitHub API.

export const REPOSITORY = "zurfyx/agentbox";
export const REPOSITORY_URL = `https://github.com/${REPOSITORY}`;

export interface Artifact {
  platform: string;
  size: number;
  sha256: string;
  url: string;
}

export interface Tool {
  version: string;
  platforms: Artifact[];
}

export interface Release {
  /** False when the build fell back to the committed snapshot. */
  live: boolean;
  version: string;
  runtimeImage: string;
  sourceCommit: string;
  claude: Tool;
  codex: Tool;
}

const FORMULA_URL = "https://raw.githubusercontent.com/zurfyx/homebrew-tap/main/Formula/agentbox.rb";
const TIMEOUT_MS = 10_000;

const VERSION = /^\d+\.\d+\.\d+$/;
const SHA256 = /^[0-9a-f]{64}$/;
const COMMIT = /^[0-9a-f]{40}$/;
const IMAGE = /^ghcr\.io\/zurfyx\/agentbox-runtime@sha256:[0-9a-f]{64}$/;

function fail(message: string): never {
  throw new Error(message);
}

function matching(pattern: RegExp, value: unknown, name: string): string {
  if (typeof value !== "string" || !pattern.test(value)) fail(`bad ${name}`);
  return value;
}

function httpsUrl(value: unknown, name: string): string {
  let url: URL | undefined;
  try {
    url = new URL(value as string);
  } catch {}
  if (url?.protocol !== "https:" || !url.host) fail(`${name}: bad url`);
  return url.href;
}

function tool(value: unknown, name: string): Tool {
  const record = value as { version?: unknown; platforms?: unknown } | undefined;
  if (typeof record?.version !== "string" || !VERSION.test(record.version)) fail(`${name}: bad version`);
  if (!Array.isArray(record.platforms) || record.platforms.length === 0) fail(`${name}: no platforms`);
  const platforms = record.platforms.map((entry: Record<string, unknown>) => {
    const { platform, size, sha256, url } = entry;
    if (platform !== "linux/arm64" && platform !== "linux/amd64") fail(`${name}: bad platform`);
    if (!Number.isSafeInteger(size) || (size as number) <= 0) fail(`${name}: bad size`);
    if (typeof sha256 !== "string" || !SHA256.test(sha256)) fail(`${name}: bad sha256`);
    return { platform, size: size as number, sha256, url: httpsUrl(url, name) };
  });
  // arm64 first: it is the qualified Apple silicon path.
  platforms.sort((a, b) => a.platform.localeCompare(b.platform)).reverse();
  return { version: record.version, platforms };
}

interface Provenance {
  runtimeImage: string;
  sourceCommit: string;
}

export function parseProvenance(version: string, value: unknown): Provenance {
  const record = value as Record<string, unknown> | undefined;
  if (record?.agentbox_version !== version) fail("provenance does not match the formula version");
  return {
    runtimeImage: matching(IMAGE, record.runtime_image, "runtime image"),
    sourceCommit: matching(COMMIT, record.source_commit, "source commit"),
  };
}

export function parseRelease(version: string, provenance: Provenance, inputs: unknown): Release {
  const tools = (inputs as { tools?: Record<string, unknown> } | undefined)?.tools;
  return {
    live: true,
    version,
    ...provenance,
    claude: tool(tools?.claude, "claude"),
    codex: tool(tools?.codex, "codex"),
  };
}

async function get(url: string): Promise<Response> {
  const response = await fetch(url, { signal: AbortSignal.timeout(TIMEOUT_MS) });
  if (!response.ok) fail(`${url}: HTTP ${response.status}`);
  return response;
}

export async function fetchRelease(): Promise<Release> {
  const formula = await (await get(FORMULA_URL)).text();
  const version = matching(VERSION, formula.match(/^\s*version\s+"([^"]+)"/m)?.[1], "formula version");
  const provenance = parseProvenance(
    version,
    await (await get(`${REPOSITORY_URL}/releases/download/v${version}/agentbox-${version}.provenance.json`)).json(),
  );
  const inputs = await (
    await get(`https://raw.githubusercontent.com/${REPOSITORY}/${provenance.sourceCommit}/release-inputs.json`)
  ).json();
  return parseRelease(version, provenance, inputs);
}

export const shortDigest = (digest: string, length = 16) => `${digest.replace(/^sha256:/, "").slice(0, length)}…`;

export const runtimeDigest = (image: string) => image.slice(image.indexOf("@") + 1);
