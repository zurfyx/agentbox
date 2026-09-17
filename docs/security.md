# Security model

Agentbox separates personal agent identity and pins executable bytes. It does
not confine an agent from your Mac's mounted files. In a normal session the
agent can modify files under `/Users`, `/Volumes`, and `/tmp`, access its
persistent vendor home, use network access, and, if configured, run commands as
your Mac user through `onhost`.

The opt-in `--workspace-only` mode reduces host-filesystem reach, but it is not
a hostile-code sandbox or a secret-isolation boundary. It retains write access
to the selected workspace and persistent vendor home, vendor credentials, and
network access. It does not protect against network exfiltration, reachable
host services, Docker Desktop or daemon compromise, destructive workspace
changes, persistent vendor-state compromise, or races with the same host user.

`clauded` skips Claude permission prompts. Codex runs with approvals and its
sandbox bypassed. Treat prompts, repositories, hooks, MCP servers, and tool
output as potentially host-affecting. Keep secrets out of repositories, review
destructive commands, and do not present Agentbox as a boundary against
malicious agent code or the same host account.

Digest verification and read-only managed mounts protect release selection
from accidents; they do not reduce the deliberate authority granted to a normal
session.

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

## Workspace-only access

`agentbox --workspace-only ...` replaces the normal broad host binds with this
fixed launch policy:

| Host or storage | Container | Access |
| --- | --- | --- |
| canonical Git worktree, or physical current directory outside Git | same absolute path | read/write |
| standard linked-worktree common Git directory, when outside the worktree | same absolute path | read/write |
| `~/.agentbox` | `/home/node` | read/write vendor home |
| session-local tmpfs | `/home/node/.ssh` | read/write mask; persisted SSH files hidden |
| `~/.agentbox/runtime` | `/home/node/runtime` and its host-absolute alias | read-only managed overlays |
| selected vendor release | `/opt/agentbox/vendor` | read-only |
| selected manifest | `/opt/agentbox/release/manifest.json` | read-only |
| bounded session-local tmpfs | `/tmp` | read/write temporary storage |

The physical current directory is preserved as the container working
directory. `/Users`, `/Volumes`, host `/tmp`, and host `/private/tmp` are not
broadly mounted. Agentbox does not read or forward a host `GH_TOKEN`, and it
omits the host-bridge variables; masking `/home/node/.ssh` also prevents the
persisted `onhost` key from being used in that session. Launches without the
flag retain the normal behavior described above.

The workspace remains writable and may contain secrets. The persistent vendor
home also remains writable and can carry Claude/Codex authentication,
configuration, session data, and changes into future launches. For Codex,
`OPENAI_API_KEY` is still forwarded when set. Network remains enabled, so an
agent can send accessible data elsewhere or connect to reachable host and
remote services.

For a normal repository, Git metadata contained in the worktree needs no extra
mount. A standard linked worktree is an exception: Git requires the shared
common directory, so Agentbox mounts it read/write. This exposes shared
objects, refs, hooks, configuration, and sibling-worktree metadata, though not
the sibling working trees themselves. Repository hooks and shared Git metadata
are executable or mutable authority, not passive bookkeeping.

Agentbox rejects a scope that is unsafe, cannot be resolved canonically, or
would require unsupported external metadata rather than silently granting a
wider mount. Arbitrary separate Git directories, external object alternates,
and a submodule selected as the workspace root when its required metadata lies
outside the allowed scope are not supported in this mode.

## Preparation isolation and release integrity

One Agentbox release manifest pins the payload-free runtime image by OCI digest,
the Claude Code executable by exact version, byte length, and SHA-256, and the
complete Codex package by exact version, byte length, SHA-256, and layout. The
vendor programs are not included in the runtime image or Agentbox archive.

Preparation downloads pinned vendor artifacts directly from Anthropic and
OpenAI, verifies them, and validates them in an isolated candidate container.
Candidate execution has no network, credentials, repository, broad host mounts,
host bridge, ports, or live home; it uses a read-only root and disposable state.
Those restrictions apply to validation, not to normal agent sessions.

Normal launches use the selected local release without querying Homebrew,
GitHub, GHCR, npm, or a vendor version channel. Prepared release snapshots are
immutable and the active selector is checksummed and changed atomically.

## Credentials

`OPENAI_API_KEY` is forwarded by environment name only to Codex sessions. It is
not forwarded to Claude, setup, validation, `doctor`, or `info`.

When `gh` is available and authenticated on the Mac, the launcher passes its
live token into the session as the raw `GH_TOKEN` environment variable. The
agent process and every child process can read and use that token directly. The
in-container credential helper limits only Git's automatic HTTPS credential
response to the exact `github.com` host; it is not a security boundary around
the ambient token. The token is not written into managed release state. Do not
use an authenticated host `gh` session when that authority should not be given
to the agent. Workspace-only sessions neither obtain nor receive this token;
this does not remove their vendor credentials or network access.

## Optional host bridge

The `onhost` bridge's dedicated key grants a full shell as your Mac user—the
same broad authority as the host mounts. To revoke it, remove its marked line
from `~/.ssh/authorized_keys` and delete
`~/.agentbox/.ssh/id_agentbox_host`. macOS privacy controls can block SSH
enumeration of Desktop, Documents, and Downloads; grant remote users Full Disk
Access only if that behavior is wanted. Workspace-only sessions hide the
persistent SSH directory and do not configure this bridge.
