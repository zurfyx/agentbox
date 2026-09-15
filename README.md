# Agentbox

Agentbox runs personal Claude Code and Codex sessions in a version-pinned,
non-root Docker container on macOS. The agents get a persistent home separate
from your host tools, while your working files remain available at their normal
absolute paths.

Agentbox is identity separation and release management, not a sandbox for your
files. Normal sessions can read and write broad host mounts. See
[Security boundary](#security-boundary) before using a dangerous mode.

## How it works

One Agentbox release manifest pins all three parts of a session:

- the payload-free Agentbox runtime image by OCI digest;
- the Claude Code executable by exact version, byte length, and SHA-256; and
- the complete Codex package by exact version, byte length, SHA-256, and layout.

Homebrew installs only host-side files, documentation, and static shell
completions. It does not run Docker, download an agent, or create
`~/.agentbox`. `agentbox setup` downloads the pinned vendor artifacts directly
from Anthropic and OpenAI, verifies them, validates them in an isolated
candidate container, and atomically selects the complete release. The release
design keeps both vendor programs out of the runtime image and Agentbox archive.

Normal launches use the selected local release without querying Homebrew,
GitHub, GHCR, npm, or a vendor version channel. If a newly installed Agentbox
release has not been prepared, launch may lazily perform the same exact-target
setup; `--no-update` suppresses that reconciliation when a usable release is
already active.

## Requirements

- macOS with Docker Desktop. Docker Desktop is the supported v1 engine;
  Colima and other Docker-compatible engines are not yet qualified.
- Homebrew for the packaged installation. The formula supplies Python and jq;
  the launcher targets macOS's `/bin/bash` 3.2. Docker Desktop is installed
  separately.
- Optional: GitHub CLI (`gh auth login`) for HTTPS Git operations against
  private GitHub repositories from a session. Its raw token becomes available
  to the agent process and its children; see [GitHub](#github).
- Optional: macOS Remote Login for the `onhost` bridge.

The release targets both `linux/arm64` and `linux/amd64` runtime artifacts, but
native Intel Mac behavior is not yet qualified. Docker must be running for
`setup`, launches, and engine checks in `doctor`; it is not needed for
installation, `--help`, `--version`, or `info`.

## Install

The intended packaged installation is:

```sh
brew install zurfyx/tap/agentbox
agentbox setup
```

The formula installs Bash, zsh, and fish completions without editing shell
startup files. Homebrew's normal shell integration discovers them.

For a source checkout:

```sh
git clone https://github.com/zurfyx/agentbox.git
cd agentbox
./bin/agentbox --help
./scripts/dev.sh setup
```

A checkout has reviewed release inputs, not the final digest-bound manifest
shipped in a release archive. Use `scripts/dev.sh` for setup and agent launches:
it builds the payload-free image, inspects its immutable local image ID, renders
a temporary development manifest, and opts the launcher into explicit
development mode. Plain `./bin/agentbox setup` intentionally refuses an
unrendered checkout.

Agentbox no longer has a manual shell installer and does not modify `.zshrc`.
If upgrading from the old shell-function version, remove its previous `source`
line if your shell resolves that legacy function before the new executable.

## Run agents

```sh
agentbox                         # Claude Code (default)
agentbox "fix the flaky test"    # arguments pass through unchanged
agentbox --resume               # unknown root flags belong to Claude
agentbox claude --resume        # explicit Claude selector
agentbox clauded --resume       # Claude with --dangerously-skip-permissions
agentbox codex                  # Codex with approvals and sandbox bypassed
agentbox -- setup               # pass reserved word "setup" to Claude
agentbox --no-update claude     # use the selected release without reconciliation
```

After an agent selector, arguments are opaque vendor arguments. `--no-update`
is an Agentbox option only before the selector. `clauded` and `codex` are
intentionally dangerous shortcuts: Agentbox adds the vendor's permission or
sandbox bypass flag before the arguments you supply.

## Lifecycle commands

| Command | Behavior |
| --- | --- |
| `agentbox setup` | Prepare, verify, isolated-smoke-test, and select the exact installed release unless a manual rollback hold is active. |
| `agentbox setup --reset-selector` | After full validation, replace an invalid or held selector with the installed release and discard its previous-selection history. |
| `agentbox update` | Upgrade the parent Homebrew package, then prepare its pinned release. A checkout prints source-update guidance instead. |
| `agentbox rollback --accept-vendor-state-risk` | Locally verify and select the immediately previous managed release, acknowledging that vendor-owned state is not reverted. |
| `agentbox info [--json]` | Show the installed target and active/previous selection without creating state or contacting Docker/network services; an unrendered checkout reports `uninstalled`. |
| `agentbox doctor [--json]` | Read-only integrity and engine diagnosis. It never runs vendor code, pulls, repairs, or creates a container. |
| `agentbox --help`, `agentbox --version` | Daemon-independent help and Agentbox version. |

Lifecycle words are reserved. `agentbox -- setup`, for example, sends `setup`
to Claude instead of invoking the lifecycle command. Leading Claude
`install`, `update`, and `upgrade` arguments remain blocked even after a
separator because vendor self-update is forbidden; put those words inside a
larger prompt instead. Lifecycle usage errors exit 64, operational failures are
nonzero, and successful checks exit 0. Agent invocations preserve the
vendor/container exit status and signals.

### Update policy and failure behavior

Only a new Agentbox release changes the runtime or agent versions. Clients do
not resolve subordinate `latest` channels, and vendor self-update commands are
blocked with guidance to use `agentbox update`.

A failure before activation keeps the previous selection. Agentbox does not
automatically roll back after a release has been activated: Claude and Codex
may already have changed their own configuration, sessions, or databases.
Explicit rollback changes only the Agentbox-managed selection, only to its
immediate previous release, and requires `--accept-vendor-state-risk`. It sets
a manual hold so setup and ordinary launches cannot silently reactivate the
installed release. After addressing the reason for rollback, use
`agentbox setup --reset-selector` to validate and select the installed release;
this deliberately resets the selector and its previous-release history.

## Authentication and persistent state

The container home is persisted at `~/.agentbox` on the host and mounted at
`/home/node`. Claude and Codex own their normal configuration and authentication
there, including `.claude`, `.claude.json`, and `.codex`. Agentbox does not
rewrite, migrate, snapshot, or roll those paths back.

Agentbox owns only `~/.agentbox/runtime`, which contains immutable prepared
releases, staging data, locks, and one checksummed `activation.json` selector.
The managed root must be a plain, user-owned directory on local APFS; symlinked
or group/world-writable roots are rejected. The selected managed directory is
mounted read-only into normal sessions. Do not edit managed files by hand; use
`setup` or `doctor`.

### Claude

Launch `agentbox` and follow Claude Code's interactive sign-in flow. Claude
state persists in the Agentbox home. Agentbox invokes the release-selected
binary by absolute path and disables its independent updater.

### Codex

Browser callback login is not supported in v1 and Agentbox publishes no OAuth
callback port. Use device-code login:

```sh
agentbox codex login --device-auth
```

Alternatively, export `OPENAI_API_KEY` before a Codex launch; it is forwarded
by environment name only to Codex sessions. It is not forwarded to Claude,
setup, validation, `doctor`, or `info`. Supported login/logout transitions are
serialized so concurrent auth changes fail safely.

### GitHub

When `gh` is available and authenticated on the Mac, the launcher passes its
live token into the session as the raw `GH_TOKEN` environment variable. The
agent process and every child process can read and use that token directly.
The in-container credential helper limits only Git's automatic HTTPS credential
response to the exact `github.com` host; it is not a security boundary around
the ambient token. The token is not written into managed release state. Do not
use an authenticated host `gh` session when that authority should not be given
to the agent. SSH remotes need separate user configuration; HTTPS is the
supported default.

## Mounts and working directory

Normal sessions preserve macOS paths so tools and diagnostics agree about file
locations:

| Host | Container | Access |
| --- | --- | --- |
| `~/.agentbox` | `/home/node` | read/write vendor home |
| `~/.agentbox/runtime` | `/home/node/runtime` | read-only managed overlay |
| selected vendor release | `/opt/agentbox/vendor` | read-only |
| `/Users` | `/Users` | read/write |
| `/Volumes` | `/Volumes` | read/write |
| `/tmp` | `/tmp` | read/write |
| current directory | same absolute path | working directory through the broad mounts |

When `/Users` exposes the Agentbox home through a second path, the launcher adds
a second read-only overlay for the managed runtime alias. Authentication and
other vendor-owned state remain writable.

Preparation uses a different container plan: no network during candidate
execution, no credentials, repository, broad host mounts, host bridge, ports,
or live home; a read-only root; and disposable state. Those restrictions apply
to validation, not to normal agent sessions.

## Security boundary

Agentbox separates personal agent identity and pins executable bytes. It does
not confine an agent from your Mac's mounted files. In a normal session the
agent can modify files under `/Users`, `/Volumes`, and `/tmp`, access its
persistent vendor home, use network access, and—if configured—run commands as
your Mac user through `onhost`. `clauded` skips Claude permission prompts;
Codex runs with approvals and its sandbox bypassed.

Treat prompts, repositories, hooks, MCP servers, and tool output as potentially
host-affecting. Keep secrets out of repositories, review destructive commands,
and do not present Agentbox as a boundary against malicious agent code or the
same host account. Digest verification and read-only managed mounts protect
release selection from accidents; they do not reduce the deliberate authority
granted to a normal session.

## macOS host bridge

Linux containers cannot execute macOS-only binaries. The optional bridge uses
a dedicated SSH key to run a command on the Mac:

```sh
# Homebrew installation:
agentbox-host-bridge

# Source checkout:
make docker-build
./setup-host-bridge.sh --dev-image agentbox-runtime:dev

# From inside Agentbox:
onhost 'cd ~/Code/project && ./run-macos-smoke.sh'
onhost -t 'interactive-command'
```

The source-only `--dev-image` path resolves that mutable tag to its immutable
local image ID before changing SSH files. The installed command instead reads
the active digest from `agentbox info --json`; run `agentbox setup` first.

Enable Remote Login first in **System Settings → General → Sharing**. The key
at `~/.agentbox/.ssh/id_agentbox_host` grants a full shell as your Mac user—the
same broad authority as the host mounts. To revoke it, remove its marked line
from `~/.ssh/authorized_keys` and delete the private key. macOS privacy controls
can block SSH enumeration of Desktop, Documents, and Downloads; grant remote
users Full Disk Access only if that behavior is wanted.

## Runtime instructions and status line

Agentbox supplies release-owned instructions to each invocation without adding
instruction files to the repository being edited. Claude's status line is also
runtime-owned and supplied through session settings rather than by rewriting
the persistent vendor configuration. Codex retains its own TUI.

## Development

Node.js 22 or newer is used only for repository checks and Husky; it is not an
end-user runtime dependency.

```sh
npm ci
npm run check

# Individual lanes
npm run test:unit
npm run test:static
npm run lint
npm run format:check
```

Use the development wrapper for commands that need a manifest:

```sh
./scripts/dev.sh setup
./scripts/dev.sh -- claude --resume
./scripts/dev.sh --no-build -- codex  # reuse this commit's existing local image
```

`--no-build` still inspects and records the image's immutable local ID; it does
not make a mutable tag authoritative. `./bin/agentbox --help`, `--version`, and
`info` remain useful directly from a checkout because they do not prepare or
launch a release.

The root `VERSION` file is the Agentbox version authority. Development metadata
and reviewed release inputs must match it. The release process renders the
final manifest only after it has the multi-platform OCI digest, copies the
version into `share/agentbox/VERSION`, and then packages
`agentbox-VERSION.tar.gz`. The Homebrew formula's version, URL, and SHA-256 are
release outputs. Do not hand-edit a vendor binary into the image or archive.

Docker Desktop integration and real vendor authentication are separate manual
release checks. CI uses fixtures and must not consume personal credentials.

## License

Agentbox is available under the [MIT License](LICENSE). Claude Code, Codex,
Docker Desktop, the Debian base, and packaged dependencies retain their own
licenses and terms; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
