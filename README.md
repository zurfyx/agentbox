# clauded

Run a second, fully isolated [Claude Code](https://github.com/anthropics/claude-code)
CLI on the same machine — inside Docker, with its own login and config.

Handy when your host enforces a corporate identity (e.g. `ANTHROPIC_API_KEY` is
set globally, or SSO auto-picks your work account) but you want a personal Claude
in the same terminal. The container gets its own home, auth, and environment;
your project directory is mounted in, so files, git, and your editor work as usual.

```
Host                          Docker container
  claude (work identity)  →     claude (personal login)
  ANTHROPIC_API_KEY             ~/.claude-personal → /root/.claude
                                $PWD               → /workspace
```

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

## Make targets

```
make build     Build the image (VERSION=x.y.z to pin)
make rebuild   Rebuild without cache
make install   Add the shell function to ~/.zshrc
make run       Build then run in the current directory
make shell     Bash shell inside the image (debug)
make clean     Remove the image (login/config kept)
```
