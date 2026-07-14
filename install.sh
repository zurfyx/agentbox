#!/usr/bin/env bash
# Wire the agentbox launcher into the shell by sourcing agentbox.sh from ~/.zshrc.
# Idempotent: re-running just refreshes the block.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RC="${ZDOTDIR:-$HOME}/.zshrc"
MARKER="# >>> agentbox >>>"
END="# <<< agentbox <<<"

touch "$RC"

# Drop any previous managed block (current + the legacy "clauded" name) so the
# install is idempotent and migrates cleanly.
strip_block() {
  local s="$1" e="$2" tmp
  if grep -qF "$s" "$RC"; then
    tmp="$(mktemp)"
    awk -v s="$s" -v e="$e" '$0==s{skip=1} !skip{print} $0==e{skip=0}' "$RC" > "$tmp"
    mv "$tmp" "$RC"
  fi
}
strip_block "$MARKER" "$END"
strip_block "# >>> clauded (my-clauded) >>>" "# <<< clauded (my-clauded) <<<"

# Ensure the rc ends in a newline so the marker doesn't glue onto the last line
# (a hand-edited ~/.zshrc without a trailing newline would otherwise corrupt).
if [ -s "$RC" ] && [ "$(tail -c1 "$RC")" != "" ]; then
  printf '\n' >> "$RC"
fi

{
  echo "$MARKER"
  echo "source \"$SCRIPT_DIR/agentbox.sh\""
  echo "$END"
} >> "$RC"

# Provision the personal config dir (login lives here; survives image rebuilds).
PERSONAL_HOME="${AGENTBOX_HOME:-$HOME/.agentbox}"
CONFIG_HOME="$PERSONAL_HOME/.claude"
mkdir -p "$CONFIG_HOME"

# Mirror the host git identity so commits made inside the container are attributed
# correctly. (Credential auth + safe.directory are baked into the image; the token
# itself is injected at launch by the agentbox launcher.)
GIT_NAME="$(git config --global user.name 2>/dev/null || true)"
GIT_EMAIL="$(git config --global user.email 2>/dev/null || true)"
if [ -n "$GIT_EMAIL" ]; then
  # `git config --file` MERGES (never clobbers a customized personal .gitconfig).
  [ -n "$GIT_NAME" ] && git config --file "$PERSONAL_HOME/.gitconfig" user.name "$GIT_NAME"
  git config --file "$PERSONAL_HOME/.gitconfig" user.email "$GIT_EMAIL"
else
  echo "Note: host git identity not set — container commits will need an identity." >&2
  echo "  Set it on the host: git config --global user.name '...'; git config --global user.email '...'" >&2
fi

# Status line (Claude only — Codex has its own TUI): copy the script and register
# it in Claude's settings.json (merge, don't clobber).
install -m 0755 "$SCRIPT_DIR/statusline.sh" "$CONFIG_HOME/statusline.sh"
python3 - "$CONFIG_HOME/settings.json" <<'PY'
import json, os, sys
path = sys.argv[1]
data = {}
if os.path.exists(path):
    try: data = json.load(open(path))
    except Exception: data = {}
data.setdefault("theme", "auto")
data["statusLine"] = {"type": "command", "command": "~/.claude/statusline.sh"}
json.dump(data, open(path, "w"), indent=2)
PY

echo "Installed. Run:  source \"$RC\"   then:  agentbox claude   (or: agentbox codex)"
echo "Build the image first if you haven't:  make build"
