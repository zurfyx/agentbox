# agentbox — run a personal AI coding agent (Claude Code or Codex) inside a
# Docker container, isolated from the work/corporate identity on the host.
# Source this from ~/.zshrc:  source ~/Code/agentbox/agentbox.sh
#
# Commands:
#   my-clauded [args...]     personal Claude Code   (also: agentbox claude ...)
#   my-codexd  [args...]     personal Codex         (also: agentbox codex ...)
#
# Isolation model:
#   * Personal config/login lives in $AGENTBOX_HOME (default ~/.agentbox),
#     mounted as the container HOME (/home/node). Claude uses ~/.claude(.json),
#     Codex uses ~/.codex — both persist side by side, separate from the work
#     CLIs on the host.
#   * /Users, /Volumes, /tmp are mounted PATH-TRANSPARENT for full filesystem
#     access; the working dir is $PWD. See README for the security model.

: "${AGENTBOX_IMAGE:=agentbox}"
: "${AGENTBOX_HOME:=$HOME/.agentbox}"

# Shared runner: _agentbox_run <agent> <in-container command + args...>
_agentbox_run() {
  local agent="$1"; shift
  mkdir -p "$AGENTBOX_HOME"

  # GitHub auth for git inside the container (Linux can't use the Mac gh/keychain).
  # Passed by NAME below so it never appears in the docker-run argv (ps-visible).
  local gh_token="${GH_TOKEN:-$(command -v gh >/dev/null 2>&1 && gh auth token 2>/dev/null)}"
  [ -z "$gh_token" ] && echo "agentbox: no GH_TOKEN (gh missing or logged out) — private-repo git will fail" >&2

  case "$PWD" in
    /Users|/Users/*|/Volumes|/Volumes/*|/tmp|/tmp/*) ;;
    *) echo "agentbox: warning: $PWD is not under /Users, /Volumes, or /tmp — it won't be visible in the container" >&2 ;;
  esac

  local -a extra
  extra=(-e GH_TOKEN)
  # Codex's ChatGPT login uses a localhost:1455 OAuth callback — publish it so
  # `codex login` works in the container. Pass OPENAI_API_KEY through if set.
  [ "$agent" = codex ] && extra+=(-p 127.0.0.1:1455:1455)
  [ -n "${OPENAI_API_KEY:-}" ] && extra+=(-e OPENAI_API_KEY)

  GH_TOKEN="$gh_token" docker run --rm -it \
    -v "$AGENTBOX_HOME:/home/node" \
    -v /Users:/Users \
    -v /Volumes:/Volumes \
    -v /tmp:/tmp \
    -w "$PWD" \
    -e AGENTBOX_HOST="${AGENTBOX_HOST:-host.docker.internal}" \
    -e AGENTBOX_HOST_USER="${AGENTBOX_HOST_USER:-$USER}" \
    "${extra[@]}" \
    "$AGENTBOX_IMAGE" "$@"
}

my-clauded() { _agentbox_run claude claude --dangerously-skip-permissions "$@"; }
my-codexd()  { _agentbox_run codex  codex  --dangerously-bypass-approvals-and-sandbox "$@"; }

# Dispatcher: agentbox {claude|codex} [args...]
agentbox() {
  local sub="${1:-}"; [ "$#" -gt 0 ] && shift
  case "$sub" in
    claude) my-clauded "$@" ;;
    codex)  my-codexd "$@" ;;
    *) echo "usage: agentbox {claude|codex} [args...]   (or: my-clauded / my-codexd)" >&2; return 2 ;;
  esac
}
