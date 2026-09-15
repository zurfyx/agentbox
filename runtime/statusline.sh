#!/bin/bash
#
# A status line for Claude Code: model, repository state, context usage, cost,
# and subscription quota, on one line.
#
#   [Opus 5] myrepo |  main +412/-88 | ████████░░ 78% 󰈸47m | $12.40 18m3s | 41% 2h 63% 4d
#
# The 󰈸 is the prompt cache: time left before the cached prefix goes cold. Once
# it has, the flame becomes a bare 󰜗.
#
# Install
#   1. Save as ~/.claude/statusline.sh, then `chmod +x ~/.claude/statusline.sh`
#   2. Add to ~/.claude/settings.json:
#        "statusLine": { "type": "command", "command": "~/.claude/statusline.sh"
#                      , "refreshInterval": 60 }
#
# refreshInterval is worth setting for this particular status line. Renders are
# otherwise event-driven — a new assistant message, a mode change, the end of a
# /compact — so nothing redraws while the session sits idle, and every countdown
# here (cache, quota windows, elapsed) freezes at whatever it last said. A
# 60-second timer thaws them without being wasteful: no field is finer-grained
# than a minute, so a faster tick would redraw an identical string. One render
# costs ~70ms with the repository cache warm, and the expensive part already
# runs detached behind that cache.
#
# Requires jq. Works in a git, Sapling (sl), or Mercurial (hg) checkout —
# whichever the directory turns out to be — and simply omits the repository
# segment anywhere else. Nothing else is assumed about the host.
#
# Configuration, all optional, all environment variables:
#
#   STATUSLINE_ICONS=ascii    Plain ASCII instead of Unicode and nerd-font
#                             glyphs. Use this if the bar renders as ??? or the
#                             icons render as boxes — it means the terminal font
#                             is not patched.
#   STATUSLINE_TTL=2          Seconds to cache repository state for.
#   STATUSLINE_VCS_REASON=1   Pass --reason to sl/hg. Some Sapling deployments
#                             ask for it for audit logging; upstream Sapling and
#                             Mercurial reject the flag, so this is off by
#                             default.
#   STATUSLINE_LABEL_TPL=...  Override the sl/hg template for the revision
#                             label. Default prefers an active bookmark, then a
#                             code-review id where the host provides one, then
#                             the short hash.
#
# Notes for anyone editing this:
#   - macOS /bin/bash is 3.2: no associative arrays, no ${x,,}, no mapfile.
#   - macOS has no timeout(1) and its stat wants -f, not -c. See TO and mtime.
#   - Do NOT build the bar with `tr`. GNU tr is byte-oriented and keeps only the
#     leading byte of each 3-byte block glyph, emitting invalid UTF-8 that shows
#     up as replacement characters. Concatenate instead.

: "${STATUSLINE_TTL:=2}"

input=$(cat)

# One jq pass for every scalar we need. Joined on U+001F rather than a tab
# because tab is IFS whitespace: bash collapses runs of it, so an empty field
# followed by a populated one would silently shift every later field left.
#
# TZ=UTC is load-bearing, not tidiness. jq 1.6's fromdateiso8601 leaves tm_isdst
# set and glibc's mktime then "corrects" an already-UTC timestamp, so a reset
# time comes back an hour late while DST is in effect and exactly right in
# winter — which is precisely how it escapes notice. jq 1.7 is unaffected, but
# pinning costs nothing: every value here is TZ-agnostic and date +%s is epoch.
FIELDS=$(echo "$input" | TZ=UTC jq -r '
  def e:  if . == null then "" else . end;
  def ep: if . == null then ""
          elif type == "string" then (sub("\\.[0-9]+"; "") | fromdateiso8601)
          else . end;
  [ (.model.display_name // "?")
  , (.workspace.current_dir // .cwd // "")
  # Report the host own context_window.used_percentage verbatim: the raw fill of
  # the model window (total_input_tokens / context_window_size). We do not model
  # the footer undocumented auto-compact reserve, so the footer may read a
  # couple of points higher near the top; that divergence is expected. Fall back
  # to the direct ratio only if the field is absent entirely.
  , ( if (.context_window.used_percentage // null) != null
        then .context_window.used_percentage
      elif (.context_window.context_window_size // 0) > 0
        then (.context_window.total_input_tokens // 0) * 100 / .context_window.context_window_size
      else 0 end
      | round | if . > 100 then 100 elif . < 0 then 0 else . end )
  , (.cost.total_cost_usd // 0)
  , (.cost.total_duration_ms // 0)
  , (.rate_limits.five_hour.used_percentage | e)
  , (.rate_limits.five_hour.resets_at       | ep)
  , (.rate_limits.seven_day.used_percentage | e)
  , (.rate_limits.seven_day.resets_at       | ep)
  # Warm only. Gate on caching_observed too, else a provider that never caches
  # looks permanently cold. Compare with == true: jq // treats false as absent.
  , ( if (.prompt_cache.caching_observed == true and .prompt_cache.warm == true)
        then (.prompt_cache.expires_at | ep) else "" end )
  # Has this session ever cached? Distinguishes "cooled down" — which earns the
  # cold glyph — from "provider never caches", where the segment stays absent.
  , (if (.prompt_cache.caching_observed == true) then 1 else "" end)
  ] | map(tostring) | join("\u001f")')

IFS=$'\037' read -r MODEL DIR_PATH PCT COST_RAW DURATION_MS \
  FIVE FIVE_AT WEEK WEEK_AT CACHE_EXP CACHE_SEEN <<< "$FIELDS"

# Defaults for the malformed-payload case: each of these feeds arithmetic or a
# numeric test below, where an empty string is a hard error rather than a zero.
: "${PCT:=0}" "${DURATION_MS:=0}" "${COST_RAW:=0}"

DIR="${DIR_PATH##*/}"
# Resolve symlinks before looking for a repository. A working directory is often
# a link into a checkout, and walking its *logical* parents climbs out to the
# home directory and never sees the marker below the link target. `cd && pwd -P`
# rather than `readlink -f`, which older macOS does not have.
PHYS=$(cd "$DIR_PATH" 2>/dev/null && pwd -P) || PHYS=""
[ -z "$PHYS" ] && PHYS="$DIR_PATH"
COST=$(printf '$%.2f' "$COST_RAW")
MINS=$((DURATION_MS / 60000))
SECS=$(((DURATION_MS % 60000) / 1000))
NOW=$(date +%s)

# Palette, defined up here because the VCS block already needs it — a segment
# that emits a color without a reset bleeds into the next separator. Basic
# 16-color on purpose: the shade is whatever the terminal theme maps it to, so
# one file follows each machine's scheme instead of imposing one. For fixed
# colors independent of the theme, use 38;5;211 / 38;5;220 / 38;5;108.
DIM='\033[2m'; R='\033[0m'; YEL='\033[33m'
RED='\033[31m'; GOLD='\033[33m'; GRN='\033[32m'

# Glyphs.  is nf-dev-git-branch, 󰈸 is nf-md-fire and 󰜗 is nf-md-snowflake, all
# nerd-font private-use codepoints. They are deliberately not 🔥/❄️ or similar:
# emoji are painted in the terminal's own color and ignore the dim attribute,
# whereas private-use glyphs are plain outlines that take the color they are
# given. The bar blocks are ordinary Unicode and widely available, but they
# travel with the same switch so one setting covers every non-ASCII character
# in the output.
if [ "$STATUSLINE_ICONS" = ascii ]; then
  I_VCS="@"; I_FIRE="~"; I_COLD="*"; B_FULL="#"; B_EMPTY="-"; B_OPEN="["; B_CLOSE="]"
else
  I_VCS=""; I_FIRE="󰈸"; I_COLD="󰜗"; B_FULL="█"; B_EMPTY="░"; B_OPEN=""; B_CLOSE=""
fi

# macOS ships no timeout(1), and no gtimeout unless coreutils is installed. That
# is survivable only because every VCS call runs in the detached refresh below,
# which no render ever waits on: a hung repository costs a stale segment, not a
# stalled status line. Do not move a TO call onto the foreground path.
if command -v timeout >/dev/null 2>&1; then TO() { timeout "$@"; }
elif command -v gtimeout >/dev/null 2>&1; then TO() { gtimeout "$@"; }
else TO() { shift; "$@"; }; fi

mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }

# ---------------------------------------------------------------------------
# Work in flight
#
# The number beside the revision is the diff this work would land as: every
# change since it forked from upstream, working tree included. With no upstream
# to compare against, the fork point collapses to the current commit and the
# same expression degrades to "just my uncommitted changes", identically for
# git, Sapling and Mercurial. It measures the work, not the session — reopening
# a branch tomorrow still shows the whole thing, which is what you want when
# judging whether a change has grown too big to review.
# ---------------------------------------------------------------------------

# Count untracked lines. Neither git nor hg reports untracked files in a diff,
# but a brand-new file is exactly the kind of work this number exists to
# measure. Capped at 200 files: reading an unbounded tree costs more than the
# accuracy is worth. Listing stays exact, so only the reading is capped.
NEWLINES=0; TRUNC=""
count_new() { # repository root, then newline-separated paths
  local root=$1 new=$2
  [ -z "$new" ] && return
  # Both tools report paths relative to the repository *root*, while this
  # process's working directory is wherever the harness launched it. Read them
  # from the root or every file silently misses and the count comes out zero.
  NEWLINES=$(echo "$new" | head -200 | tr '\n' '\0' \
    | (cd "$root" 2>/dev/null && xargs -0 cat 2>/dev/null) | wc -l | tr -d ' ')
  # Past the cap the total is a floor, not a count. Say so, loudly: a number
  # that is silently 9x low is worse than no number at all.
  [ "$(echo "$new" | wc -l | tr -d ' ')" -gt 200 ] && TRUNC=" ${YEL}(!!)${R}"
}

# Nothing changed yet: show the revision alone rather than a hollow +0/-0.
emit_vcs() {
  local seg="$1"
  if [ "${2:-0}" -gt 0 ] || [ "${3:-0}" -gt 0 ]; then
    seg="${seg} ${DIM}+${2}/-${3}${R}${TRUNC}"
  fi
  printf ' | %s %s' "$I_VCS" "$seg"
}

shortstat() { # "N files changed, A insertions(+), D deletions(-)" -> A and D
  A=$(echo "$1" | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+')
  D=$(echo "$1" | grep -oE '[0-9]+ deletion'  | grep -oE '[0-9]+')
}

# --no-optional-locks keeps a status line that renders on every keystroke from
# fighting a real git command for the index lock.
vcs_git() {
  local branch base from
  g() { git --no-optional-locks -C "$PHYS" "$@" 2>/dev/null; }
  branch=$(g branch --show-current)
  [ -z "$branch" ] && return
  base=$(g symbolic-ref --quiet --short refs/remotes/origin/HEAD)
  from=$(g merge-base HEAD "${base:-origin/main}")
  shortstat "$(g diff --shortstat "${from:-HEAD}")"
  count_new "$(g rev-parse --show-toplevel)" "$(g ls-files --others --exclude-standard)"
  emit_vcs "$branch" "$((${A:-0} + NEWLINES))" "${D:-0}"
}

# Sapling and Mercurial share this command surface: --cwd, `log -r REV -T TPL`,
# `diff --stat -r REV`, `status -u -n`, and the revsets below are all standard
# in both. --cwd is not optional: without it the tool resolves the repository
# from the *process* working directory, which is whatever the harness happened
# to launch us in, and aborts outright when that differs from the reported one.
v() {
  if [ -n "$STATUSLINE_VCS_REASON" ]; then
    TO 6 "$VCS_BIN" --cwd "$PHYS" "$@" --reason 'claude-code status line' 2>/dev/null
  else
    TO 6 "$VCS_BIN" --cwd "$PHYS" "$@" 2>/dev/null
  fi
}

TPL_PLAIN='{ifeq(bookmarks,"","{node|short}","{bookmarks}")}'
# Prefers an active bookmark; else the code-review id, but only on a draft
# commit, since a landed commit still carries one and showing it would read as
# if the work were still in flight; else the short hash.
TPL_RICH='{ifeq(bookmarks,"","{ifeq(phase,"public","{node|short}","{ifeq(phabdiff,"","{node|short}","{phabdiff}")}")}","{bookmarks}")}'

# {phabdiff} is an extension keyword that some Sapling deployments add and that
# upstream Sapling and Mercurial fail to parse. Probe once and remember, so the
# common path stays at one process per query instead of a failed call plus a
# retry on every refresh. Keyed on the binary and its mtime, so an upgrade or a
# move to a different host re-probes rather than trusting a stale answer.
label_tpl() {
  local f
  [ -n "$STATUSLINE_LABEL_TPL" ] && { printf '%s' "$STATUSLINE_LABEL_TPL"; return; }
  f="$CACHE_DIR/tpl.$(printf '%s %s' "$VCS_BIN" "$(mtime "$VCS_BIN")" | cksum | cut -d' ' -f1)"
  if [ ! -f "$f" ]; then
    if v log -r . -T '{phabdiff}' >/dev/null 2>&1
      then printf '%s' "$TPL_RICH"  > "$f"
      else printf '%s' "$TPL_PLAIN" > "$f"
    fi
  fi
  cat "$f"
}

vcs_hg() {
  local label base
  label=$(v log -r . -T "$(label_tpl)")
  [ -z "$label" ] && return
  # The analog of git's merge-base: the newest public ancestor is where this
  # stack of drafts forks from upstream, so diffing the working copy against it
  # covers the whole stack plus pending edits in one pass. A repository with no
  # public commits at all yields nothing, and the base collapses to the current
  # commit — the same degradation as git's merge-base fallback.
  base=$(v log -r 'max(::. & public())' -T '{node|short}')
  shortstat "$(v diff --stat -r "${base:-.}" | tail -1)"
  count_new "$(v root)" "$(v status -u -n)"
  emit_vcs "$label" "$((${A:-0} + NEWLINES))" "${D:-0}"
}

vcs_segment() {
  local d="$PHYS"
  while [ -n "$d" ] && [ "$d" != "/" ]; do
    # Sapling writes .sl in a fresh clone but keeps .hg in checkouts made before
    # the rename, and Mercurial always uses .hg, so all three mean "not git".
    if [ -e "$d/.hg" ] || [ -e "$d/.sl" ]; then
      VCS_BIN=$(command -v sl || command -v hg) || return
      vcs_hg; return
    fi
    [ -e "$d/.git" ] && { vcs_git; return; }
    d="${d%/*}"
  done
}

# Serve the last known segment instantly and refresh behind it. A cold cache
# costs one render with no repository segment, which then fills itself in —
# cheaper than making every keystroke wait on a network-backed filesystem. The
# refresh must not inherit the captured stdout, or the harness blocks waiting
# for that pipe to close.
CACHE_DIR="${TMPDIR:-/tmp}/claude-statusline.$(id -u)"
mkdir -p "$CACHE_DIR" 2>/dev/null
# Key on the resolved path, so two routes to one directory share an entry. The
# icon setting is part of the key because what gets cached is the *rendered*
# segment, glyphs included, so flipping the setting must not serve back a
# segment drawn in the other alphabet.
CF="$CACHE_DIR/vcs.$(printf '%s %s' "$PHYS" "$STATUSLINE_ICONS" | cksum | cut -d' ' -f1)"
VCS=""
[ -f "$CF" ] && VCS=$(cat "$CF" 2>/dev/null)
if [ $((NOW - $(mtime "$CF"))) -ge "$STATUSLINE_TTL" ]; then
  LOCK="$CF.lock"
  # Reap a lock orphaned by a refresh that died, or this wedges permanently.
  [ -d "$LOCK" ] && [ $((NOW - $(mtime "$LOCK"))) -ge 60 ] && rmdir "$LOCK" 2>/dev/null
  if mkdir "$LOCK" 2>/dev/null; then
    ( vcs_segment > "$CF.new" 2>/dev/null && mv -f "$CF.new" "$CF"
      rmdir "$LOCK" 2>/dev/null ) </dev/null >/dev/null 2>&1 &
  fi
fi

# Color by context usage.
if [ "$PCT" -ge 90 ]; then C="$RED"
elif [ "$PCT" -ge 70 ]; then C="$GOLD"
else C="$GRN"; fi

# Round rather than floor, so a bar at 78% shows 8 blocks and not 7.
FILLED=$(((PCT + 5) / 10)); [ "$FILLED" -gt 10 ] && FILLED=10; EMPTY=$((10 - FILLED))
BAR="$B_OPEN"
for ((i = 0; i < FILLED; i++)); do BAR="${BAR}${B_FULL}"; done
for ((i = 0; i < EMPTY;  i++)); do BAR="${BAR}${B_EMPTY}"; done
BAR="${BAR}${B_CLOSE}"

fmt_left() { # seconds remaining -> single coarsest unit, e.g. 2d / 1h / 47m
  local s=$1
  [ "$s" -le 0 ] && { printf 'now'; return; }
  local m=$(((s + 59) / 60)) # round up, so we never show a misleading 0m
  if [ "$s" -ge 86400 ]; then printf '%dd' $((s / 86400))
  elif [ "$m" -ge 60 ]; then printf '%dh' $(((m + 30) / 60)) # 60m -> 1h
  else printf '%dm' "$m"; fi
}

# Subscription quota. The host only sends .rate_limits on subscription auth, so
# on an API key the whole segment self-hides. Shown as consumed, the way the API
# reports it: 0% on a fresh window, 100% when exhausted, so it counts up to
# match the context bar beside it. Time math stays in bash and jq on purpose —
# `date -d` (GNU) and `date -r` (BSD) are mutually incompatible.
quota_seg() { # used_pct, resets_at(epoch), fallback_label
  local used=$1 reset=$2 label=$3 col tail
  [ -z "$used" ] && return
  used=$(printf '%.0f' "$used")
  if [ "$used" -ge 90 ]; then col="$RED"
  elif [ "$used" -ge 70 ]; then col="$GOLD"
  else col="$DIM"; fi
  # Prefer a live countdown; fall back to the static window label if the server
  # did not send a reset time.
  if [ -n "$reset" ]; then tail=$(fmt_left $((reset - NOW))); else tail="$label"; fi
  printf "%b%s%%%b %b%s%b " "$col" "$used" "$R" "$DIM" "$tail" "$R"
}
QUOTA="$(quota_seg "$FIVE" "$FIVE_AT" 5h)$(quota_seg "$WEEK" "$WEEK_AT" 7d)"
[ -n "$QUOTA" ] && QUOTA=" | ${QUOTA% }"

# Prompt cache: time left before the cached prefix goes cold. Rides in the
# context group — how full this conversation is, and how long it stays cached,
# are the same subject, and the flame keeps the two numbers apart without a
# separator between them. Once the window has lapsed there is no countdown left
# to show, so the flame gives way to a bare snowflake: the next turn will pay
# full price for the prefix, which is worth seeing at a glance. A provider that
# never caches at all shows neither glyph rather than a permanent snowflake.
#
# Both states render at the same weight, uncolored. One segment changing state
# should not also change how loud it is: the glyph already says which state it
# is in, and dimming the cold one would make the swap read as two changes
# instead of one. A dim outline glyph is also the first thing to disappear on a
# low-contrast theme, which is the wrong thing to hide.
CACHE=""
if [ -n "$CACHE_EXP" ]; then
  CACHE=" ${I_FIRE}$(fmt_left $((CACHE_EXP - NOW)))"
elif [ -n "$CACHE_SEEN" ]; then
  CACHE=" ${I_COLD}"
fi

# Groups run left to right by increasing time horizon: the working tree right
# now, then this conversation (how full, how long cached), then this session's
# spend, then the quota windows measured in hours and days. Cost and elapsed
# share a group because both are session totals that only count up.
echo -e "[$MODEL] ${DIM}${DIR}${R}${VCS} | ${C}${BAR}${R} ${PCT}%${CACHE} | ${COST} ${MINS}m${SECS}s${QUOTA}"
