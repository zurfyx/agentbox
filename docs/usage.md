# Usage and operations

The Homebrew formula installs the host launcher, documentation, and static Bash,
zsh, and fish completions. Homebrew's normal shell integration discovers the
completions; Agentbox does not edit shell startup files.

## Launching agents

Run Agentbox from the directory you want the agent to work in:

```sh
agentbox [--workspace-only] [--no-update] [claude|clauded|codex] [--] [ARG ...]

agentbox                         # Claude Code (default)
agentbox "fix the flaky test"    # arguments pass through unchanged
agentbox --resume               # unknown root flags belong to Claude
agentbox claude --resume        # explicit Claude selector
agentbox clauded --resume       # Claude with --dangerously-skip-permissions
agentbox codex                  # Codex with approvals and sandbox bypassed
agentbox -- setup               # pass reserved word "setup" to Claude
agentbox --no-update claude     # use an already selected compatible release
agentbox --workspace-only       # workspace-limited default Claude launch
agentbox --workspace-only codex # workspace-limited Codex launch
```

On first launch, Agentbox downloads, verifies, and validates only the requested
vendor. `clauded` prepares the Claude artifact but remains a distinct launch
mode. Launching the other vendor later adds it to a new immutable prepared
snapshot while retaining verified artifacts and user-owned state.

`--workspace-only` and `--no-update` are Agentbox options only in the leading
prefix. Each may appear at most once, and they may appear in either order.
Agentbox stops parsing that prefix at a selector, `--`, or the first unknown
argument (which starts the default Claude payload). Everything from that point
is forwarded unchanged, so `agentbox codex --workspace-only` passes the flag to
Codex instead of enabling the Agentbox mode. Global Agentbox flags do not apply
to lifecycle commands. `clauded` and `codex` are intentionally dangerous
shortcuts: Agentbox adds the vendor's permission or sandbox bypass flag before
the arguments you supply. Review the [security model](security.md) before using
them.

The harmless global meta-actions `help`, `-h`, `--help`, and `--version` are
early-exit exceptions: they are accepted after either or both global options,
ignore those options, print help or the version, and exit without preparing or
launching an agent. For example, `agentbox --workspace-only --help` describes
the mode without resolving a workspace or contacting Docker.

### Workspace-only access

Use the opt-in mode when the agent needs the current project but not Agentbox's
normal broad host mounts:

```sh
agentbox --workspace-only claude
agentbox --no-update --workspace-only codex
agentbox --workspace-only -- "review this project"
```

Inside a Git worktree, Agentbox mounts the canonical top-level worktree
read/write at the same absolute path and preserves the physical current
directory as the container working directory. Outside Git, it mounts exactly
the physical current directory. A standard linked worktree also requires its
common Git directory read/write at the same absolute path; that exposes shared
objects, refs, hooks, configuration, and metadata for sibling worktrees, but
not sibling working-tree files. Contained metadata mounts are deduplicated.

The policy is fixed: there are no custom mount, credential, profile, or network
parameters. Workspace-only omits broad `/Users`, `/Volumes`, host `/tmp`, and
host `/private/tmp` binds; `/tmp` is a bounded, container-local tmpfs. It keeps
the persistent Agentbox vendor home at `/home/node` read/write, while masking
its `.ssh` directory for the session, and keeps the selected vendor, managed
runtime, and manifest mounts read-only. It neither reads nor forwards a host
`GH_TOKEN` and does not provide the optional `onhost` bridge.

Network access remains enabled. Existing Claude/Codex login state in the
persistent vendor home remains available, and `OPENAI_API_KEY` remains
available to workspace-only Codex launches when set. The agent can therefore
modify or exfiltrate workspace and vendor-home data, use vendor credentials,
reach network services (including reachable host services), and leave
persistent state for later sessions. Workspace-only is a host-filesystem access
limitation and defense-in-depth measure, not a hostile-code sandbox.

Agentbox rejects unsafe or unresolvable workspace scopes instead of widening
access. Arbitrary separate Git directories, external object alternates, and a
submodule selected as the workspace root when its required metadata is outside
the allowed scope are not supported. Use normal mode only when its broader
authority is intended. Launches without `--workspace-only` retain the normal
mount, credential, bridge, working-directory, and argument behavior.

Lifecycle words are reserved. `agentbox -- setup`, for example, sends `setup`
to Claude instead of invoking the lifecycle command. Leading Claude `install`,
`update`, and `upgrade` arguments remain blocked even after a separator because
vendor self-update is forbidden; put those words inside a larger prompt
instead. Lifecycle usage errors exit 64, operational failures are nonzero, and
successful checks exit 0. Agent invocations preserve the vendor/container exit
status and signals.

## Authentication

### Claude

Launch `agentbox claude` and follow Claude Code's interactive sign-in flow.
Claude state persists in the Agentbox home. Agentbox invokes the
release-selected binary by absolute path and disables its independent updater.

### Codex

Browser callback login is not supported in v1 and Agentbox publishes no OAuth
callback port. Use device-code login:

```sh
agentbox codex login --device-auth
```

Alternatively, export `OPENAI_API_KEY` before a Codex launch. It is forwarded
by environment name only to Codex sessions, not to Claude, setup, validation,
`doctor`, or `info`. Supported login/logout transitions are serialized so
concurrent authentication changes fail safely.

### GitHub

The optional GitHub CLI can provide HTTPS Git access to private GitHub
repositories. Run `gh auth login` on the Mac before launching Agentbox. This
passes the live token into the agent session, with the implications described
in [Security](security.md#credentials).

SSH remotes need separate user configuration; HTTPS is the supported default.

## Lifecycle commands

| Command | Behavior |
| --- | --- |
| `agentbox setup` | Eagerly prepare, verify, isolated-smoke-test, and select both agents for the exact installed release unless a manual rollback hold is active. |
| `agentbox setup --reset-selector` | After full validation, replace an invalid or held selector with the installed release and discard its previous-selection history. |
| `agentbox update` | Upgrade the parent Homebrew package, then prepare its pinned release. A checkout prints source-update guidance instead. |
| `agentbox rollback --accept-vendor-state-risk` | Locally verify and select the immediately previous managed release, acknowledging that vendor-owned state is not reverted. |
| `agentbox info [--json]` | Show the installed target and active/previous selection without creating state or contacting Docker or network services; an unrendered checkout reports `uninstalled`. |
| `agentbox doctor [--json]` | Perform read-only integrity and engine diagnosis. It never runs vendor code, pulls, repairs, or creates a container. |
| `agentbox --help`, `agentbox --version` | Show daemon-independent help and the Agentbox version. |

### Updates, rollback, and failures

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

## Persistent state

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

Agentbox supplies release-owned instructions to each invocation without adding
instruction files to the repository being edited. Claude's status line is also
runtime-owned and supplied through session settings rather than by rewriting
the persistent vendor configuration. Codex retains its own TUI.

## Optional macOS host bridge

Linux containers cannot execute macOS-only binaries. The optional bridge uses
a dedicated SSH key to run a command on the Mac. Enable Remote Login first in
**System Settings → General → Sharing**, then run:

```sh
agentbox-host-bridge
```

From inside Agentbox:

```sh
onhost 'cd ~/Code/project && ./run-macos-smoke.sh'
onhost -t 'interactive-command'
```

The installed command reads the active digest from `agentbox info --json`; run
`agentbox setup` first if you want to configure the bridge before launching an
agent. The key at `~/.agentbox/.ssh/id_agentbox_host` grants a full shell as
your Mac user. See [Security](security.md#optional-host-bridge) for its authority,
revocation, and macOS privacy implications.

## Troubleshooting

- If a launch says Docker is unavailable, start Docker Desktop and retry the
  same `agentbox claude` or `agentbox codex` command. Setup is not a prerequisite.
- If an upgraded shell reports `invalid choice: 'claude' (choose from
  'prepare', 'validate', 'run')`, the current shell is still resolving the old
  sourced `agentbox` function. Remove its previous `source` line from the shell
  startup file, start a new shell (or unset the function), and retry the
  installed executable. Agentbox no longer has a manual shell installer and
  does not modify `.zshrc`.
- Use `agentbox doctor` for read-only integrity and Docker engine diagnostics.
  Use `agentbox info --json` to inspect the installed and selected release.
