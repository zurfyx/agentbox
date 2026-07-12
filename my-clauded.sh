# my-clauded — run Claude Code inside an isolated Docker container.
# Source this from ~/.zshrc:  source ~/Code/clauded/my-clauded.sh
#
# Config/login persist in $MY_CLAUDED_HOME (default ~/.claude-personal),
# completely separate from the host's work Claude CLI.

: "${MY_CLAUDED_IMAGE:=claude-personal}"
: "${MY_CLAUDED_HOME:=$HOME/.claude-personal}"

my-clauded() {
  mkdir -p "$MY_CLAUDED_HOME"
  docker run --rm -it \
    -v "$MY_CLAUDED_HOME:/root/.claude" \
    -v "$PWD:/workspace" \
    -w /workspace \
    "$MY_CLAUDED_IMAGE" \
    --dangerously-skip-permissions "$@"
}
