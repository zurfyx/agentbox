#!/usr/bin/env bash
# Wire my-clauded into the shell by sourcing my-clauded.sh from ~/.zshrc.
# Idempotent: re-running just refreshes the managed block.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RC="${ZDOTDIR:-$HOME}/.zshrc"
MARKER="# >>> clauded (my-clauded) >>>"
END="# <<< clauded (my-clauded) <<<"

touch "$RC"

# Drop any previous managed block so the install is idempotent.
if grep -qF "$MARKER" "$RC"; then
  tmp="$(mktemp)"
  awk -v s="$MARKER" -v e="$END" '
    $0==s{skip=1} !skip{print} $0==e{skip=0}
  ' "$RC" > "$tmp"
  mv "$tmp" "$RC"
fi

{
  echo "$MARKER"
  echo "source \"$SCRIPT_DIR/my-clauded.sh\""
  echo "$END"
} >> "$RC"

# Provision the personal config dir (login lives here; survives image rebuilds).
CONFIG_HOME="${MY_CLAUDED_HOME:-$HOME/.claude-personal}/.claude"
mkdir -p "$CONFIG_HOME"

# Status line: copy the script and register it in settings.json (merge, don't clobber).
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

echo "Installed. Run:  source \"$RC\"   then:  my-clauded"
echo "Build the image first if you haven't:  make build"
