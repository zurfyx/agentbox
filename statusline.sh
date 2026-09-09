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
# Shows: [model] dir | branch +added/-removed | context bar + % | quota | cost + elapsed | cache TTL
input=$(cat)
MODEL=$(echo "$input" | jq -r '.model.display_name')
DIR_PATH=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // ""')
DIR=$(basename "$DIR_PATH")
PCT=$(echo "$input" | jq -r '(.context_window.used_percentage // 0) | round')
COST=$(printf '$%.2f' "$(echo "$input" | jq -r '.cost.total_cost_usd // 0')")
DURATION_MS=$(echo "$input" | jq -r '.cost.total_duration_ms // 0')
MINS=$((DURATION_MS / 60000))
SECS=$(((DURATION_MS % 60000) / 1000))

# Palette. Defined up here because the git block below already needs it — a
# segment that emits a color without a reset bleeds into the next separator.
DIM='\033[2m'; R='\033[0m'; YEL='\033[33m'

# Git branch (if inside a repo), followed by the size of the work in flight.
#
# That size is the diff this branch would land as a PR: everything since it
# forked from the default branch, working tree included. On the default branch
# the merge base *is* HEAD, so the same expression degrades to "just my
# uncommitted changes" with no special case. It counts the work, not the
# session — reopening a branch tomorrow still shows the whole thing, which is
# what you want when judging whether a PR has grown too big.
#
# --no-optional-locks keeps a status line that renders on every keystroke from
# fighting a real git command for the index lock.
g() { git --no-optional-locks -C "$DIR_PATH" "$@" 2>/dev/null; }
BRANCH=$(g branch --show-current)
if [ -n "$BRANCH" ]; then
  BASE=$(g symbolic-ref --quiet --short refs/remotes/origin/HEAD)
  FROM=$(g merge-base HEAD "${BASE:-origin/main}")
  STAT=$(g diff --shortstat "${FROM:-HEAD}")
  A=$(echo "$STAT" | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+')
  D=$(echo "$STAT" | grep -oE '[0-9]+ deletion' | grep -oE '[0-9]+')
  # git diff can't see untracked files, but a brand-new file is exactly the
  # kind of work this number exists to measure — so count its lines too.
  # Capped at 200 files: reading an unbounded tree on every render costs more
  # than the accuracy is worth (measured 2x on a 2000-file tree). Listing the
  # files is cheap; only the reading is capped, so the count of how many there
  # are stays exact.
  TRUNC=""
  NEW=$(g ls-files --others --exclude-standard)
  if [ -n "$NEW" ]; then
    NEWLINES=$(echo "$NEW" | head -200 | tr '\n' '\0' | xargs -0 cat 2>/dev/null | wc -l | tr -d ' ')
    A=$((${A:-0} + NEWLINES))
    # Past the cap the total is a floor, not a count. Say so, loudly — a number
    # that is silently 9x low is worse than no number.
    [ "$(echo "$NEW" | wc -l | tr -d ' ')" -gt 200 ] && TRUNC=" ${YEL}(!!)${R}"
  fi
  # Nothing changed yet: show the branch alone rather than a hollow +0/-0.
  [ -n "$A$D" ] && BRANCH="${BRANCH} ${DIM}+${A:-0}/-${D:-0}${R}${TRUNC}"
  BRANCH=" |  ${BRANCH}"
fi

# Color by context usage
if [ "$PCT" -ge 90 ]; then C='\033[31m'
elif [ "$PCT" -ge 70 ]; then C='\033[33m'
else C='\033[32m'; fi

# Build the bar by concatenating the multibyte glyphs directly. Do NOT use
# `tr ' ' '█'` — GNU tr (Linux) is byte-oriented and mangles the 3-byte
# block characters into invalid UTF-8 (renders as ??? diamonds).
[ -z "$PCT" ] && PCT=0
FILLED=$((PCT / 10)); [ "$FILLED" -gt 10 ] && FILLED=10; EMPTY=$((10 - FILLED))
BAR=""
for ((i = 0; i < FILLED; i++)); do BAR="${BAR}█"; done
for ((i = 0; i < EMPTY; i++)); do BAR="${BAR}░"; done

# Subscription quota. Claude Code only sends .rate_limits on subscription auth
# (Max/Pro), so on an API key the whole segment self-hides. We display it as-is
# (consumed), so it counts UP toward 100% like the context bar does.
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
  local used=$1 reset=$2 label=$3 col tail
  [ -z "$used" ] && return
  # Show quota CONSUMED, as the API reports it: 0% on a fresh window, 100% when
  # exhausted — matching the context bar next to it, which also counts up.
  used=$(printf '%.0f' "$used")
  if [ "$used" -ge 90 ]; then col='\033[31m'
  elif [ "$used" -ge 70 ]; then col="$YEL"
  else col="$DIM"; fi
  # Prefer a live countdown; fall back to the static window label if the
  # server didn't send a reset time.
  if [ -n "$reset" ]; then tail=$(fmt_left $((reset - NOW))); else tail="$label"; fi
  printf "%b%s%%%b %b%s%b " "$col" "$used" "$R" "$DIM" "$tail" "$R"
}

rl() { echo "$input" | jq -r "(.rate_limits.$1.$2 // empty) | if type==\"string\" then (sub(\"\\\\.[0-9]+\";\"\") | fromdateiso8601) else . end"; }
FIVE=$(rl five_hour used_percentage);  FIVE_AT=$(rl five_hour resets_at)
WEEK=$(rl seven_day used_percentage);  WEEK_AT=$(rl seven_day resets_at)
QUOTA="$(quota_seg "$FIVE" "$FIVE_AT" 5h)$(quota_seg "$WEEK" "$WEEK_AT" 7d)"
[ -n "$QUOTA" ] && QUOTA=" | ${QUOTA% }"

# Prompt cache, trailing group: time left before the cached prefix goes cold.
# Warm only — a cold cache has no countdown to show, so the group disappears
# rather than reporting its own absence. Also absent before the first API
# response, and whenever the provider reports no cache tokens at all (gate on
# caching_observed, else a non-caching provider looks permanently cold). Read
# the booleans with `== true` — jq's `//` treats `false` as absent.
CACHE=""
if [ "$(echo "$input" | jq -r '.prompt_cache.caching_observed == true and .prompt_cache.warm == true')" = "true" ]; then
  EXP=$(echo "$input" | jq -r '.prompt_cache.expires_at // empty')
  # ⚡ = the fast path, held for another N. If your terminal gives the bolt
  # emoji presentation and the double width jitters the line, append U+FE0E
  # (⚡︎) to force the narrow text form.
  [ -n "$EXP" ] && CACHE=" | ${DIM}⚡$(fmt_left $((EXP - NOW)))${R}"
fi

# Cost and elapsed are one group: both are session totals that only count up.
# The cache countdown keeps the last slot to itself.
echo -e "[$MODEL] ${DIM}${DIR}${R}${BRANCH} | ${C}${BAR}${R} ${PCT}%${QUOTA} | ${COST} ${MINS}m${SECS}s${CACHE}"
