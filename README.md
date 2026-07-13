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
my-clauded                 # personal Claude Code in the current directory
my-codexd                  # personal Codex in the current directory
agentbox claude "fix bug"  # dispatcher form (== my-clauded)
agentbox codex             # (== my-codexd)
```

First run of each prompts you to log in with your **personal** account:

- **Claude** — the usual browser/paste-a-code flow.
- **Codex** — run `codex login` (ChatGPT OAuth via the published `localhost:1455`
  callback), or export `OPENAI_API_KEY` before launching.

Both logins persist in `~/.agentbox` across runs (the container itself is `--rm`
and disposable).

## Customize

Override via env vars before sourcing, or in your shell:

| Var               | Default        | Meaning                          |
| ----------------- | -------------- | -------------------------------- |
| `AGENTBOX_IMAGE`  | `agentbox`     | Docker image name                |
| `AGENTBOX_HOME`   | `~/.agentbox`  | Persistent config/logins on host |

Pin versions: `make build VERSION=1.2.3 CODEX_VERSION=0.144.3`.
Upgrade to latest: `make rebuild`.

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
# "Allow full disk access for remote users" is NOT needed.
make host-bridge          # generates a dedicated key, authorizes it, verifies
```

Then, from inside `my-clauded` / `my-codexd`:

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
cost · lines changed · elapsed) into Claude's config and registers it in
`settings.json`. The image ships `jq` + `git`, which it needs. Codex has its own
TUI and ignores this. Edit `statusline.sh` and re-run `make install` to update it.

## Make targets

```
make build      Build the image (VERSION=x.y.z CODEX_VERSION=a.b.c to pin)
make rebuild    Rebuild without cache
make install    Add the shell functions to ~/.zshrc
make run        Build + run Claude in the current directory
make run-codex  Build + run Codex in the current directory
make shell      Bash shell inside the image (debug)
make host-bridge  Set up the container->macOS-host command bridge (onhost)
make clean      Remove the image (login/config kept)
```
