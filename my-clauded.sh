# my-clauded — run Claude Code inside an isolated Docker container.
# Source this from ~/.zshrc:  source ~/Code/clauded/my-clauded.sh
#
# Config/login persist in $MY_CLAUDED_HOME (default ~/.claude-personal),
# completely separate from the host's work Claude CLI. This is mounted as the
# container user's whole home so BOTH ~/.claude/ and ~/.claude.json (which holds
# the login) survive across the disposable --rm containers.

: "${MY_CLAUDED_IMAGE:=claude-personal}"
: "${MY_CLAUDED_HOME:=$HOME/.claude-personal}"

my-clauded() {
  mkdir -p "$MY_CLAUDED_HOME"
  docker run --rm -it \
    -v "$MY_CLAUDED_HOME:/home/node" \
    -v "$PWD:/workspace" \
    -w /workspace \
    "$MY_CLAUDED_IMAGE" \
    --dangerously-skip-permissions "$@"
}
