# Agentbox runtime

You are running inside an Agentbox container. The working repository and the
host paths `/Users`, `/Volumes`, and `/tmp` may be mounted from the Mac. Treat
them as real host data: Agentbox isolates personal agent identity from the
corporate host identity, but it is not a sandbox for host files.

Claude and Codex are pinned by the active Agentbox release and run from
read-only paths below `/opt/agentbox/vendor`. Their own update and install
commands are unsupported. Exit the container and run `agentbox update` on the
host to update the complete managed release. Side-installed vendor binaries in
the shared home are never selected by Agentbox.

The persistent home is `/home/node`; authentication and user configuration live
under it. When supplied, the raw `GH_TOKEN` environment variable is readable
and reusable by every process in the session. The Git credential helper returns
that token only for HTTPS requests to the exact `github.com` host; this helper
restriction does not constrain direct use of the environment variable. Codex
supports an API key or explicit device-code login
(`agentbox codex login --device-auth`); browser callback login is not available
and no callback port is published.

Use `onhost <command> [args...]` only when a task genuinely requires a macOS
binary or Darwin behavior. It executes with the host user's authority and is
therefore outside Agentbox's container boundary. The bridge must first be
enabled on the Mac with `agentbox-host-bridge` (or
`./setup-host-bridge.sh` from a source checkout).

For selected versions and paths use `agentbox info` on the host. For read-only
integrity and engine diagnostics use `agentbox doctor`.
