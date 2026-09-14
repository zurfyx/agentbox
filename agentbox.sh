# agentbox — run a personal AI coding agent (Claude Code or Codex) inside a
# Docker container, isolated from the work/corporate identity on the host.
# Source this from ~/.zshrc:  source ~/Code/agentbox/agentbox.sh
#
# Commands:
#   agentbox [args...]           personal Claude Code (claude is the default mode)
#   agentbox claude  [args...]   same, spelled out
#   agentbox clauded [args...]   Claude Code with --dangerously-skip-permissions
#   agentbox codex   [args...]   personal Codex
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
# Directory of this script (the repo) — used to rebuild the image on update.
: "${AGENTBOX_REPO:=${${(%):-%x}:A:h}}"

# Return the registry's concrete version, never the mutable "latest" tag. Docker
# cannot know that a registry tag changed, so using @latest in a RUN instruction
# can silently reuse an old installation layer.
_agentbox_latest_version() {
  local version
  version=$(npm view "$1" version 2>/dev/null) || return 1
  [ -n "$version" ] || return 1
  printf '%s\n' "$version"
}

_agentbox_build() {
  local claude_version="$1" codex_version="$2"
  docker build \
    --build-arg CLAUDE_VERSION="$claude_version" \
    --build-arg CODEX_VERSION="$codex_version" \
    -t "$AGENTBOX_IMAGE" "$AGENTBOX_REPO" \
    >"$AGENTBOX_HOME/.last-update.log" 2>&1
}

# Keep the image current on launch. Throttled: at most once every successful
# $AGENTBOX_UPDATE_INTERVAL_DAYS (default 1). Rebuilds only when a published
# version differs, reusing cached layers (only the changed agent refetches).
# Disable with AGENTBOX_AUTO_UPDATE=0. Never blocks an existing image on failure.
_agentbox_maybe_update() {
  case "${AGENTBOX_AUTO_UPDATE:-1}" in 0 | off | no) return 0 ;; esac
  mkdir -p "$AGENTBOX_HOME"
  local stamp="$AGENTBOX_HOME/.last-update-check" now last age
  now=$(date +%s); last=0; [ -f "$stamp" ] && last=$(cat "$stamp" 2>/dev/null || echo 0)

  local latest_claude latest_codex

  # First run / after `make clean`: resolve immutable versions before building.
  # BuildKit may retain layers after an image is deleted, so a build using the
  # literal @latest is not sufficient to guarantee a current installation.
  if ! docker image inspect "$AGENTBOX_IMAGE" >/dev/null 2>&1; then
    echo "agentbox: image '$AGENTBOX_IMAGE' not found — building…" >&2
    latest_claude=$(_agentbox_latest_version @anthropic-ai/claude-code) || latest_claude=""
    latest_codex=$(_agentbox_latest_version @openai/codex) || latest_codex=""
    if [ -z "$latest_claude" ] || [ -z "$latest_codex" ]; then
      echo "agentbox: cannot resolve current agent versions from npm — build deferred." >&2
      return 1
    fi
    if _agentbox_build "$latest_claude" "$latest_codex"; then
      echo "$now" > "$stamp"
    else
      echo "agentbox: build failed (see $AGENTBOX_HOME/.last-update.log)" >&2
      return 1
    fi
    return 0
  fi

  age=$(( (now - last) / 86400 ))
  [ "$age" -lt "${AGENTBOX_UPDATE_INTERVAL_DAYS:-1}" ] && return 0
  latest_claude=$(_agentbox_latest_version @anthropic-ai/claude-code) || latest_claude=""
  latest_codex=$(_agentbox_latest_version @openai/codex) || latest_codex=""
  [ -z "$latest_claude$latest_codex" ] && return 0   # offline / npm unavailable

  local vers cur_claude cur_codex
  vers=$(docker run --rm --entrypoint sh "$AGENTBOX_IMAGE" -c 'claude --version 2>/dev/null; codex --version 2>/dev/null')
  cur_claude=$(printf '%s\n' "$vers" | sed -n 's/^\([0-9][0-9.]*\).*/\1/p' | head -1)
  cur_codex=$(printf '%s\n' "$vers" | grep -i codex | sed -n 's/.*[[:space:]]\([0-9][0-9.]*\).*/\1/p' | head -1)

  if { [ -n "$latest_claude" ] && [ "$latest_claude" != "$cur_claude" ]; } ||
     { [ -n "$latest_codex" ] && [ "$latest_codex" != "$cur_codex" ]; }; then
    # If one registry lookup failed, keep that agent at the exact version already
    # installed. Never fall back to a cacheable @latest build argument.
    local build_claude="${latest_claude:-$cur_claude}"
    local build_codex="${latest_codex:-$cur_codex}"
    if [ -z "$build_claude" ] || [ -z "$build_codex" ]; then
      echo "agentbox: could not determine both installed versions — update deferred." >&2
      return 0
    fi
    echo "agentbox: updating (claude ${cur_claude:-?}→${latest_claude:-$cur_claude}, codex ${cur_codex:-?}→${latest_codex:-$cur_codex})…" >&2
    if _agentbox_build "$build_claude" "$build_codex"; then
      echo "agentbox: updated." >&2
    else
      echo "agentbox: update failed (see $AGENTBOX_HOME/.last-update.log) — continuing with current image." >&2
      return 0
    fi
  fi

  # A partial/offline check is deliberately not throttled for a day. Once both
  # registry queries succeed, record the check (and any required build) as done.
  if [ -n "$latest_claude" ] && [ -n "$latest_codex" ]; then
    echo "$now" > "$stamp"
  fi
}

# Shared runner: _agentbox_run <agent> <in-container command + args...>
_agentbox_run() {
  local agent="$1"; shift
  mkdir -p "$AGENTBOX_HOME"
  _agentbox_maybe_update || return 1

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

# Entry point: agentbox [claude|clauded|codex] [args...]
# `claude` is the default mode: anything that isn't a known subcommand is treated
# as arguments to Claude Code, so `agentbox --resume` / `agentbox "fix bug"` work.
# Extra args are always appended after the agent's own flags.
agentbox() {
  local sub=claude
  case "${1:-}" in
    claude | clauded | codex) sub="$1"; shift ;;
    help | -h | --help)
      cat >&2 <<'USAGE'
usage: agentbox [claude|clauded|codex] [args...]

  agentbox [args...]           Claude Code (default mode)
  agentbox claude  [args...]   same, spelled out
  agentbox clauded [args...]   Claude Code + --dangerously-skip-permissions
  agentbox codex   [args...]   Codex + --dangerously-bypass-approvals-and-sandbox
USAGE
      return 0
      ;;
  esac
  case "$sub" in
    claude)  _agentbox_run claude claude "$@" ;;
    clauded) _agentbox_run claude claude --dangerously-skip-permissions "$@" ;;
    codex)   _agentbox_run codex  codex  --dangerously-bypass-approvals-and-sandbox "$@" ;;
  esac
}
