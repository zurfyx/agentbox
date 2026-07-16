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

# Status line — Claude: copy the script and register it in settings.json (merge,
# don't clobber). Claude renders its status line via an external command.
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

# Status line — Codex: enable the built-in TUI status line with the same quota
# indicators (model, dir, context, tokens, 5h + weekly limits). Codex has no
# external-command statusline like Claude's — it renders a fixed set of components
# you order in config.toml. Merge without clobbering existing keys; idempotent.
CODEX_HOME="$PERSONAL_HOME/.codex"
mkdir -p "$CODEX_HOME"
python3 - "$CODEX_HOME/config.toml" <<'PY'
import sys
path = sys.argv[1]
try:
    text = open(path).read()
except FileNotFoundError:
    text = ""
# Verified token names for the built-in TUI status line (context-used, not the
# often-cited context-usage, which this build rejects). Codex renders each item
# with a fixed label and no progress bar — there is no external-command hook.
keys = [
    'status_line = ["model-with-reasoning", "context-used", "five-hour-limit", "weekly-limit"]',
    "status_line_use_colors = true",
]
lines = text.splitlines()
if any(l.split("=", 1)[0].strip() == "status_line" for l in lines):
    pass  # already configured — leave the user's choice alone
else:
    # Insert under an existing bare [tui] header, else append a fresh [tui] table.
    out, inserted = [], False
    for l in lines:
        out.append(l)
        if not inserted and l.strip() == "[tui]":
            out.extend(keys)
            inserted = True
    if not inserted:
        if out and out[-1].strip() != "":
            out.append("")
        out += ["[tui]", *keys]
    open(path, "w").write("\n".join(out) + "\n")
PY

echo "Installed. Run:  source \"$RC\"   then:  agentbox claude   (or: agentbox codex)"
echo "Build the image first if you haven't:  make build"
