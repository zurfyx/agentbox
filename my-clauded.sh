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
  docker run --rm -it \
    -v "$MY_CLAUDED_HOME:/home/node" \
    -v /Users:/Users \
    -v /Volumes:/Volumes \
    -v /tmp:/tmp \
    -w "$PWD" \
    "$MY_CLAUDED_IMAGE" \
    --dangerously-skip-permissions "$@"
}
