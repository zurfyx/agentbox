# agentbox

Run personal AI coding agents — **Claude Code** and **Codex** — inside one Docker
container on your Mac, each with its own login, isolated from the work/corporate
identity on the host.

Handy when your host enforces a corporate identity (e.g. `ANTHROPIC_API_KEY` set
globally, SSO auto-picks your work account, or the agent CLI is an internal fork)
but you want personal agents in the same terminal. The container gets its own
home, auth, and environment; your files are mounted in, so editing, git, and your
editor work as usual.

```
Host                          Docker container (runs as non-root "node")
  claude / codex (work)   →     claude + codex (personal logins)
  ANTHROPIC_API_KEY             ~/.agentbox → /home/node  (holds ~/.claude, ~/.codex)
                                /Users, /Volumes → same paths (full FS access)
                                $PWD → working dir
```

## Prerequisites

- **macOS** with **Docker Desktop** (the `/Users` mounts and `host.docker.internal`
  rely on it) and **zsh**.
- **GitHub CLI** for in-container git auth: `brew install gh && gh auth login`
  (or export your own `GH_TOKEN`). Without it, private-repo git won't work.
- Host git identity set (`git config --global user.name` / `user.email`) if you
  want commits made inside the container attributed to you.

## Setup

```sh
git clone https://github.com/zurfyx/agentbox ~/Code/agentbox
cd ~/Code/agentbox
make build      # builds the "agentbox" image (Claude Code + Codex)
make install    # sources agentbox.sh from your ~/.zshrc
source ~/.zshrc
```

## Usage

```sh
agentbox                     # personal Claude Code in the current directory
agentbox "fix bug"           # claude is the default mode — args pass straight through
agentbox --resume
agentbox claude --resume     # same thing, spelled out
agentbox clauded             # Claude Code with --dangerously-skip-permissions
agentbox clauded --resume    # extra args still work on top of the bundled flag
agentbox codex               # personal Codex in the current directory
```

`claude` is the default mode: any argument that isn't a known subcommand
(`claude`, `clauded`, `codex`) is handed to Claude Code as-is. `clauded` is the
same launch with `--dangerously-skip-permissions` bundled in, so you opt into
skipping permission prompts by name rather than by default. `agentbox help`
prints the summary.

First run of each prompts you to log in with your **personal** account:

- **Claude** — the usual browser/paste-a-code flow.
- **Codex** — run `codex login` (ChatGPT OAuth via the published `localhost:1455`
  callback), or export `OPENAI_API_KEY` before launching.

Both logins persist in `~/.agentbox` across runs (the container itself is `--rm`
and disposable).

## Customize

Override via env vars before sourcing, or in your shell:

| Var                            | Default       | Meaning                                   |
| ------------------------------ | ------------- | ----------------------------------------- |
| `AGENTBOX_IMAGE`               | `agentbox`    | Docker image name                         |
| `AGENTBOX_HOME`                | `~/.agentbox` | Persistent config/logins on host          |
| `AGENTBOX_AUTO_UPDATE`         | `1`           | Auto-update the image on launch (`0` off) |
| `AGENTBOX_UPDATE_INTERVAL_DAYS`| `1`           | How often the launch check may run        |

Pin versions: `make build VERSION=1.2.3 CODEX_VERSION=0.144.3`.

## Updating

The agents are **baked into the image** — the container is disposable (`--rm`)
and its global install dir isn't writable, so Claude Code's in-container
background auto-update can't work (the image sets `DISABLE_AUTOUPDATER=1` to
silence it). Updating means rebuilding the image, and the launcher does that for
you automatically.

**Auto-update on launch (default).** When you run `agentbox` / `codex`,
the launcher checks — at most once a day — whether a newer Claude or Codex has
been published, and if so rebuilds the image before starting (reusing cached
layers, so only the changed agent refetches). It's silent when you're current,
skips gracefully when offline, and never blocks the launch on failure. Tune or
turn it off:

```sh
AGENTBOX_AUTO_UPDATE=0 agentbox                 # skip the check this run
export AGENTBOX_UPDATE_INTERVAL_DAYS=7          # check weekly instead of daily
```

**Manual / forced.** Update right now, or pin exact versions:

```sh
cd ~/Code/agentbox && make update               # rebuild --no-cache, latest both
make build VERSION=1.2.3 CODEX_VERSION=0.144.3  # pin
```

If you ever see "Auto-update failed" *inside* a session, it's a stale image from
before this setting — the next launch's auto-update (or `make update`) clears it.

## Git / GitHub inside the container

A Linux container can't run the macOS `gh` binary or read the keychain, so git
auth is handled at launch instead:

- The launcher injects the host's live token (`gh auth token`) as `GH_TOKEN`,
  passed by name so it never lands in the `docker run` argv (`ps`-visible).
- The image ships a tiny credential helper (`git-credential-ghtoken`) that feeds
  that token to git over HTTPS **only for `github.com`** (it reads git's request
  on stdin and declines every other host, so the token can't leak to a rogue or
  non-GitHub remote), plus `safe.directory=*` so bind-mounted repos (owned by
  your macOS uid, not the container's) don't trip "dubious ownership".
- `install.sh` mirrors your host git `user.name` / `user.email` **if set** so
  commits are attributed correctly (merged into your personal `.gitconfig`).

Net result: `git pull` / `git push` just work — no keychain, no 1Password prompt,
no token stored on disk — always using your current `gh` session.

Only HTTPS remotes work (`https://github.com/...`), not SSH. Convert a repo with:
`git remote set-url origin https://github.com/<owner>/<repo>.git`.

## Running macOS-host-only commands (`onhost`)

Some steps can't run in a Linux container at all — macOS-only binaries, or tests
that depend on Darwin kernel / pty behavior. Instead of switching terminals, the
container hops to the Mac over SSH.

One-time setup (run on the Mac):

```sh
# Enable Remote Login: System Settings -> General -> Sharing -> Remote Login
#   (or: sudo systemsetup -setremotelogin on)
# "Allow full disk access for remote users" is not needed for running commands,
# but WITHOUT it, listing TCC-protected dirs (~/Desktop, ~/Documents,
# ~/Downloads) over ssh hangs forever with no error -- macOS blocks the
# enumeration on a consent dialog that can never be shown to an ssh session.
# Exact-path file reads/writes/scp still work. Enable it if the agent will
# browse those dirs remotely.
make host-bridge          # generates a dedicated key, authorizes it, verifies
```

**Caveats for any Mac reached over ssh** (this host or another machine):
listing TCC-protected dirs hangs without full disk access (above), and macOS
ships no GNU `timeout` — so always bound remote calls from the *client* side
(`timeout 30 ssh …`); a blocked remote call otherwise hangs the session
indefinitely.

Then, from inside an agentbox session:

```sh
onhost 'cd ~/Code/proj && ./run-macos-smoke.sh'   # run + capture output
onhost -t 'some-interactive-tool'                  # allocate a real Darwin pty
```

`setup-host-bridge.sh` creates a dedicated ed25519 key in
`~/.agentbox/.ssh/id_agentbox_host`, authorizes it, and tests the round-trip. The
launcher injects the host address (`host.docker.internal`) and your Mac username.

**Security:** this key grants a full shell as your Mac user (same reach as the
`/Users` mount). If a machine is lost, remove the key's line from
`~/.ssh/authorized_keys` and delete `~/.agentbox/.ssh/id_agentbox_host`. Override
the target with `AGENTBOX_HOST` / `AGENTBOX_HOST_USER`.

## Status line (Claude)

`make install` provisions `statusline.sh` (model · dir · git branch · context bar ·
**quota** · cost · lines changed · elapsed) into Claude's config and registers it in
`settings.json`. The image ships `jq` + `git`, which it needs. Codex has its own
TUI and ignores this.

```
[Opus 4.8] agentbox |  main | █░░░░░░░░░ 11% | 29% 3h  15% 3d | $1.81 | +0/-0 | 13m35s
                              └ context used   └ quota used, and when it resets:
                                                 29% of the 5h session (resets in 3h)
                                                 15% of the 7d week    (resets in 3d)
```

Both percentages count **up**: 0% on a fresh window, 100% when exhausted — same
direction as the context bar beside them. Dim below 70%, yellow at 70%, red at 90%.

The quota figures come from `.rate_limits` on the JSON that Claude Code pipes to
the script on stdin — the same numbers `/usage` reports, not an estimate. One
thing about that payload is easy to get wrong: `resets_at` is a **unix epoch in
seconds**, not an ISO string (Claude Code has a separate code path that emits ISO
— don't copy that one). The script handles both shapes anyway.

Claude Code only sends `.rate_limits` on subscription auth (Max/Pro). On an API
key the whole segment self-hides, so the script is safe to use either way.

**Editing it:** `install.sh` copies this repo's `statusline.sh` over
`~/.claude/statusline.sh` **unconditionally** on every install, so edits made
directly to `~/.claude/statusline.sh` are silently reverted on the next `make
install` / rebuild. Edit `statusline.sh` *here*, then re-run `make install`.

## Make targets

```
make build      Build the image (VERSION=x.y.z CODEX_VERSION=a.b.c to pin)
make rebuild    Rebuild without cache
make update     Update agents to latest (rebuild; the only update path)
make install    Add the shell functions to ~/.zshrc
make run        Build + run Claude in the current directory
make run-dangerous  Build + run Claude with --dangerously-skip-permissions
make run-codex  Build + run Codex in the current directory
make shell      Bash shell inside the image (debug)
make host-bridge  Set up the container->macOS-host command bridge (onhost)
make clean      Remove the image (login/config kept)
```
