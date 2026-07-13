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
# Shows: [model] dir | branch | context-usage bar + % | quota | cost | +added/-removed | elapsed
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

# Subscription quota. Claude Code only sends .rate_limits on subscription auth
# (Max/Pro), so on an API key the whole segment self-hides.
# used_percentage is 0-100; resets_at is a unix epoch in SECONDS.
# Time math stays in bash/jq on purpose: `date -d` (GNU) and `date -r` (BSD)
# are incompatible, and this script runs on both macOS and Linux.
NOW=$(date +%s)

fmt_left() { # seconds remaining -> single coarsest unit, e.g. 2d / 1h / 47m
  local s=$1
  [ "$s" -le 0 ] && { printf 'now'; return; }
  local m=$(((s + 59) / 60)) # round up, so we never show a misleading 0m
  if [ "$s" -ge 86400 ]; then printf '%dd' $((s / 86400))
  elif [ "$m" -ge 60 ]; then printf '%dh' $(((m + 30) / 60)) # 60m -> 1h
  else printf '%dm' "$m"; fi
}

quota_seg() { # used_pct, resets_at(epoch), fallback_label
  local used=$1 reset=$2 label=$3 left col tail
  [ -z "$used" ] && return
  # The API reports quota CONSUMED; we display quota LEFT, to read naturally
  # alongside the time left. Colors invert accordingly: red when running out.
  left=$(printf '%.0f' "$(echo "$used" | awk '{print 100 - $1}')")
  if [ "$left" -le 10 ]; then col='\033[31m'
  elif [ "$left" -le 30 ]; then col='\033[33m'
  else col="$DIM"; fi
  # Prefer a live countdown; fall back to the static window label if the
  # server didn't send a reset time.
  if [ -n "$reset" ]; then tail=$(fmt_left $((reset - NOW))); else tail="$label"; fi
  printf "%b%s%%%b %b%s%b " "$col" "$left" "$R" "$DIM" "$tail" "$R"
}

rl() { echo "$input" | jq -r "(.rate_limits.$1.$2 // empty) | if type==\"string\" then (sub(\"\\\\.[0-9]+\";\"\") | fromdateiso8601) else . end"; }
FIVE=$(rl five_hour used_percentage);  FIVE_AT=$(rl five_hour resets_at)
WEEK=$(rl seven_day used_percentage);  WEEK_AT=$(rl seven_day resets_at)
QUOTA="$(quota_seg "$FIVE" "$FIVE_AT" 5h)$(quota_seg "$WEEK" "$WEEK_AT" 7d)"
[ -n "$QUOTA" ] && QUOTA=" | ${QUOTA% }"

echo -e "[$MODEL] ${DIM}${DIR}${R}${BRANCH} | ${C}${BAR}${R} ${PCT}%${QUOTA} | ${COST} | ${DIM}+${ADDED}/-${REMOVED}${R} | ${MINS}m${SECS}s"
