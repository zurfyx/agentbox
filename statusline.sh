#!/bin/bash
# Claude Code status line — custom status bar.
#
# To wire on a new machine:
#   1. Save this file as ~/.claude/statusline.sh
#   2. chmod +x ~/.claude/statusline.sh
#   3. Add to ~/.claude/settings.json:
#        "statusLine": { "type": "command", "command": "~/.claude/statusline.sh" }
#   Requires: jq
#
# Shows: [model] dir | branch | context-usage bar + % | cost | +added/-removed | elapsed
input=$(cat)
MODEL=$(echo "$input" | jq -r '.model.display_name')
DIR_PATH=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // ""')
DIR=$(basename "$DIR_PATH")
PCT=$(echo "$input" | jq -r '(.context_window.used_percentage // 0) | round')
COST=$(printf '$%.2f' "$(echo "$input" | jq -r '.cost.total_cost_usd // 0')")
ADDED=$(echo "$input" | jq -r '.cost.total_lines_added // 0')
REMOVED=$(echo "$input" | jq -r '.cost.total_lines_removed // 0')
DURATION_MS=$(echo "$input" | jq -r '.cost.total_duration_ms // 0')
MINS=$((DURATION_MS / 60000))
SECS=$(((DURATION_MS % 60000) / 1000))

# Git branch (if inside a repo)
BRANCH=$(git -C "$DIR_PATH" branch --show-current 2>/dev/null)
[ -n "$BRANCH" ] && BRANCH=" |  ${BRANCH}"

# Color by context usage
if [ "$PCT" -ge 90 ]; then C='\033[31m'
elif [ "$PCT" -ge 70 ]; then C='\033[33m'
else C='\033[32m'; fi
DIM='\033[2m'; R='\033[0m'

# Build the bar by concatenating the multibyte glyphs directly. Do NOT use
# `tr ' ' '█'` — GNU tr (Linux) is byte-oriented and mangles the 3-byte
# block characters into invalid UTF-8 (renders as ??? diamonds).
[ -z "$PCT" ] && PCT=0
FILLED=$((PCT / 10)); [ "$FILLED" -gt 10 ] && FILLED=10; EMPTY=$((10 - FILLED))
BAR=""
for ((i = 0; i < FILLED; i++)); do BAR="${BAR}█"; done
for ((i = 0; i < EMPTY; i++)); do BAR="${BAR}░"; done

echo -e "[$MODEL] ${DIM}${DIR}${R}${BRANCH} | ${C}${BAR}${R} ${PCT}% | ${COST} | ${DIM}+${ADDED}/-${REMOVED}${R} | ${MINS}m${SECS}s"
