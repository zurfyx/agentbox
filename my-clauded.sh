# my-clauded — run Claude Code inside a Docker container with full access to
# your macOS files, but a separate personal login from the work CLI.
# Source this from ~/.zshrc:  source ~/Code/clauded/my-clauded.sh
#
# Isolation model:
#   * Personal login/config lives in $MY_CLAUDED_HOME (default ~/.claude-personal),
#     mounted as the container's HOME (/home/node) so it never touches the work
#     CLI's ~/.claude / ~/.claude.json.
#   * The rest of the Mac's user filesystem (/Users, /Volumes, /tmp) is mounted
#     PATH-TRANSPARENT so Claude can read/write anywhere your macOS user can,
#     just like the native `clauded`. Absolute paths resolve the same inside
#     and outside the container.
#
# macOS note: a Linux container cannot see the true macOS system dirs
# (/System, /usr, /etc, /Library) — those aren't shareable into Docker, and the
# native tool can't write them without sudo either. "Everything under /Users"
# is the practical equivalent of native reach.

: "${MY_CLAUDED_IMAGE:=claude-personal}"
: "${MY_CLAUDED_HOME:=$HOME/.claude-personal}"

my-clauded() {
  mkdir -p "$MY_CLAUDED_HOME"
  # GitHub auth for git inside the container: the Linux container can't run the
  # Mac `gh` binary or read the keychain, so hand it the live token at launch.
  # Override by exporting GH_TOKEN (e.g. a scoped classic PAT) before running.
  local gh_token="${GH_TOKEN:-$(command -v gh >/dev/null 2>&1 && gh auth token 2>/dev/null)}"
  [ -z "$gh_token" ] && echo "my-clauded: no GH_TOKEN (gh missing or logged out) — private-repo git will fail" >&2
  # Warn if launched from a dir that isn't mounted into the container (it would
  # appear as an empty, root-owned workdir).
  case "$PWD" in
    /Users|/Users/*|/Volumes|/Volumes/*|/tmp|/tmp/*) ;;
    *) echo "my-clauded: warning: $PWD is not under /Users, /Volumes, or /tmp — it won't be visible in the container" >&2 ;;
  esac
  # Pass the token by NAME (not -e KEY=value) so it's read from docker's
  # environment and never appears in the docker-run argv (visible via `ps`).
  GH_TOKEN="$gh_token" docker run --rm -it \
    -v "$MY_CLAUDED_HOME:/home/node" \
    -v /Users:/Users \
    -v /Volumes:/Volumes \
    -v /tmp:/tmp \
    -w "$PWD" \
    -e GH_TOKEN \
    -e CLAUDED_HOST="${CLAUDED_HOST:-host.docker.internal}" \
    -e CLAUDED_HOST_USER="${CLAUDED_HOST_USER:-$USER}" \
    "$MY_CLAUDED_IMAGE" \
    --dangerously-skip-permissions "$@"
}
