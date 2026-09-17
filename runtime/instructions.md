# Agentbox runtime

You are running inside an Agentbox container. In a normal launch, the working
repository and broad host paths `/Users`, `/Volumes`, and host temporary
directories may be mounted from the Mac. In an opt-in `--workspace-only`
launch, host filesystem access is reduced to the canonical Git worktree (or
physical current directory outside Git), plus shared Git metadata required by
a standard linked worktree. The physical working directory is preserved and
the allowed workspace and Git metadata are writable. Treat them as real host
data. Neither launch mode is a hostile-code sandbox.

Workspace-only sessions omit the broad host mounts, use container-local `/tmp`,
hide persisted SSH files, do not receive `GH_TOKEN`, and cannot use Agentbox's
optional `onhost` bridge. They still have network access, may reach accessible
host services, and retain read/write access to the persistent vendor home.
That home contains authentication, configuration, and session state that can
be read, changed, or carried into later launches. A linked worktree's mounted
common Git directory exposes shared objects, refs, hooks, configuration, and
sibling-worktree metadata, though not sibling working-tree files. External Git
directories, object alternates, and submodule roots that require metadata
outside the allowed scope are unsupported in workspace-only mode.

Claude and Codex are pinned by the active Agentbox release and run from
read-only paths below `/opt/agentbox/vendor`. Their own update and install
commands are unsupported. Exit the container and run `agentbox update` on the
host to update the complete managed release. Side-installed vendor binaries in
the shared home are never selected by Agentbox.

The persistent home is `/home/node`; authentication and user configuration live
under it. In normal mode, when supplied, the raw `GH_TOKEN` environment variable
is readable and reusable by every process in the session. The Git credential
helper returns that token only for HTTPS requests to the exact `github.com`
host; this helper restriction does not constrain direct use of the environment
variable. Workspace-only omits that token. Codex still receives
`OPENAI_API_KEY` when the host supplied it, including in workspace-only mode,
and supports explicit device-code login
(`agentbox codex login --device-auth`); browser callback login is not available
and no callback port is published.

In normal mode, use `onhost <command> [args...]` only when a task genuinely
requires a macOS binary or Darwin behavior. It executes with the host user's
authority and is therefore outside Agentbox's container boundary. The bridge
must first be enabled on the Mac with `agentbox-host-bridge` (or
`./setup-host-bridge.sh` from a source checkout). It is unavailable in
workspace-only mode.

For selected versions and paths use `agentbox info` on the host. For read-only
integrity and engine diagnostics use `agentbox doctor`.
