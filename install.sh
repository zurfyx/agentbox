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

echo "Installed. Run:  source \"$RC\"   then:  my-clauded"
echo "Build the image first if you haven't:  make build"
