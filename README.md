# clauded

Run a second, fully isolated [Claude Code](https://github.com/anthropics/claude-code)
CLI on the same machine — inside Docker, with its own login and config.

Handy when your host enforces a corporate identity (e.g. `ANTHROPIC_API_KEY` is
set globally, or SSO auto-picks your work account) but you want a personal Claude
in the same terminal. The container gets its own home, auth, and environment;
your project directory is mounted in, so files, git, and your editor work as usual.

```
Host                          Docker container (runs as non-root "node")
  claude (work identity)  →     claude (personal login)
  ANTHROPIC_API_KEY             ~/.claude-personal → /home/node  (whole home)
                                /Users, /Volumes   → same paths (full FS access)
                                $PWD               → working dir
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
git clone https://github.com/zurfyx/clauded ~/Code/clauded
cd ~/Code/clauded
make build      # builds the "claude-personal" image
make install    # sources my-clauded.sh from your ~/.zshrc
source ~/.zshrc
```

## Usage

```sh
my-clauded                 # start Claude in the current directory
my-clauded resume
my-clauded "fix this bug"
```

First run prompts you to log in with your **personal** Claude.ai account. The
login persists in `~/.claude-personal` across runs (the container itself is
`--rm` and disposable).

## Customize

Override via env vars before sourcing, or in your shell:

| Var                 | Default              | Meaning                        |
| ------------------- | -------------------- | ------------------------------ |
| `MY_CLAUDED_IMAGE`  | `claude-personal`    | Docker image name              |
| `MY_CLAUDED_HOME`   | `~/.claude-personal` | Persistent config/login on host |

Pin a Claude Code version: `make build VERSION=1.2.3`.
Upgrade to latest: `make rebuild`.

## Git / GitHub inside the container

A Linux container can't run the macOS `gh` binary or read the keychain, so git
auth is handled at launch instead:

- `my-clauded` injects the host's live token (`gh auth token`) as `GH_TOKEN`,
  passed by name so it never lands in the `docker run` argv (`ps`-visible).
- The image ships a tiny credential helper (`git-credential-ghtoken`) that feeds
  that token to git over HTTPS **only for `github.com`** (it reads git's request
  on stdin and declines every other host, so the token can't leak to a rogue or
  non-GitHub remote), plus `safe.directory=*` so bind-mounted repos (owned by
  your macOS uid, not the container's) don't trip "dubious ownership".
- `install.sh` mirrors your host git `user.name` / `user.email` **if set** so
  commits are attributed correctly (merged into your personal `.gitconfig`, not
  clobbered).

Net result: `git pull` / `git push` / `gh`-authenticated fetches just work, with
no keychain, no 1Password prompt, and no token stored on disk — and it always
uses your current `gh` session, so it never goes stale.

Use a different credential (e.g. a scoped classic PAT) by exporting it first:

```sh
GH_TOKEN=ghp_yourclassicPAT my-clauded
```

Only HTTPS remotes work (`https://github.com/...`), not SSH — the container has
no access to your SSH agent. Convert a repo with:
`git remote set-url origin https://github.com/<owner>/<repo>.git`.

## Running macOS-host-only commands (`onhost`)

Some steps can't run in a Linux container at all — macOS-only binaries, or tests
that depend on Darwin kernel / pty behavior (e.g. a real-Claude smoke test).
Instead of switching terminals, the container hops to the Mac over SSH.

One-time setup (run on the Mac):

```sh
# Enable Remote Login: System Settings -> General -> Sharing -> Remote Login
#   (or: sudo systemsetup -setremotelogin on)
# "Allow full disk access for remote users" is NOT needed.
make host-bridge          # generates a dedicated key, authorizes it, verifies
```

`setup-host-bridge.sh` creates a dedicated ed25519 key in
`~/.claude-personal/.ssh/id_clauded_host`, adds it to your `~/.ssh/authorized_keys`,
and tests the round-trip from inside the container. `my-clauded` injects the host
address (`host.docker.internal`) and your Mac username at launch.

Then, from inside `my-clauded`:

```sh
onhost 'cd ~/Code/proj && ./run-macos-smoke.sh'   # run + capture output
onhost -t 'some-interactive-tool'                  # allocate a real Darwin pty
```

**Security:** this key grants a full shell as your Mac user (same reach as the
`/Users` mount). If a machine is lost, remove the key's line from
`~/.ssh/authorized_keys` and delete `~/.claude-personal/.ssh/id_clauded_host`.
Override the target with `CLAUDED_HOST` / `CLAUDED_HOST_USER`.

## Status line

`make install` also provisions `statusline.sh` (model · dir · git branch ·
context-usage bar · cost · lines changed · elapsed) into the personal config and
registers it in `settings.json`. The image ships `jq` + `git`, which it needs.
Edit `statusline.sh` and re-run `make install` to update it.

## Make targets

```
make build     Build the image (VERSION=x.y.z to pin)
make rebuild   Rebuild without cache
make install   Add the shell function to ~/.zshrc
make run       Build then run in the current directory
make shell     Bash shell inside the image (debug)
make host-bridge  Set up the container->macOS-host command bridge (onhost)
make clean     Remove the image (login/config kept)
```
