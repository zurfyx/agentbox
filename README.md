# Agentbox

Agentbox runs personal Claude Code and Codex sessions in a version-pinned,
non-root Docker container on macOS. It keeps agent logins and configuration in
a dedicated home instead of mixing them with host installations, while making
your working files available at their normal absolute paths.

For example, open a project and start the agent you want:

```sh
cd ~/Code/my-project
agentbox claude
# or
agentbox codex
```

The first launch downloads, verifies, and prepares only the requested agent.
A later launch of the other agent prepares that agent without discarding the
first or your persistent agent state.

> [!IMPORTANT]
> Agentbox provides identity separation and pinned release management, not a
> sandbox for your files. Normal sessions can read and write broad host mounts.
> Read the [security model](docs/security.md), especially before using a mode
> that bypasses permission prompts or exposes host credentials.

## Requirements

- macOS with Docker Desktop running. Docker Desktop is the supported v1 engine;
  Colima and other Docker-compatible engines are not yet qualified.
- Homebrew. The formula supplies Python and jq; Docker Desktop is installed
  separately.

Agentbox publishes `linux/arm64` and `linux/amd64` runtime artifacts, but native
Intel Mac behavior is not yet qualified.

## Install and run

Trust the tap before installing from it:

```sh
brew trust zurfyx/tap
brew install zurfyx/tap/agentbox
```

Then, from any working directory, launch either agent directly:

```sh
agentbox claude
agentbox codex
```

Follow the agent's sign-in flow when prompted. Docker and network activity begin
only when you launch an agent or explicitly run a lifecycle operation; package
installation itself does not create `~/.agentbox`, run Docker, or download an
agent.

## Learn more

- [Usage and operations](docs/usage.md): arguments, authentication, lifecycle
  commands, state, the optional host bridge, and troubleshooting
- [Security](docs/security.md): host mounts, credentials, trust boundaries, and
  preparation isolation
- [Development](docs/development.md): source checkouts and repository checks
- [Release operations](docs/release.md): release invariants, automation,
  rollout, recovery, and verification

`agentbox setup` can eagerly prepare both agents, and `agentbox doctor` provides
read-only diagnostics, but neither is required before the first launch. Run
`agentbox --help` for the complete command summary.

Agentbox is available under the [MIT License](LICENSE). Claude Code, Codex,
Docker Desktop, the Debian base, and packaged dependencies retain their own
licenses and terms; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
