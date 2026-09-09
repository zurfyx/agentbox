#!/bin/bash
# Claude Code status line — one file, shared by every machine.
#
# To wire on a new machine:
#   1. Save this file as ~/.claude/statusline.sh
#   2. chmod +x ~/.claude/statusline.sh
#   3. Add to ~/.claude/settings.json:
#        "statusLine": { "type": "command", "command": "~/.claude/statusline.sh" }
#   Requires: jq
#
# Shows: [model] dir |  rev +added/-removed | context bar + % + cache TTL | cost + elapsed | quota
#
# Portability, the three things that actually bite:
#   - macOS /bin/bash is 3.2, so no associative arrays, no ${x,,}, no mapfile.
#   - macOS has no `timeout` (see TO below) and no `stat -c` (see mtime below).
#   - GNU `tr` is byte-oriented and shreds multibyte glyphs, so the bar is built
#     by concatenation (see BAR below).

input=$(cat)

# One jq pass for every scalar we need. Joined on U+001F rather than a tab
# because tab is IFS whitespace: bash collapses runs of it, so an empty field
# followed by a populated one would silently shift every later field left.
#
# TZ=UTC is load-bearing, not tidiness: jq 1.6 fromdateiso8601 leaks the local
# DST offset (it leaves tm_isdst set and glibc mktime then "corrects" it), so an
# already-UTC reset timestamp comes back an hour late while DST is in effect and
# exactly right in winter. Every other value here is TZ-agnostic, and date +%s
# is epoch, so pinning the whole call is safe.
FIELDS=$(echo "$input" | TZ=UTC jq -r '
  def e:  if . == null then "" else . end;
  def ep: if . == null then ""
          elif type == "string" then (sub("\\.[0-9]+"; "") | fromdateiso8601)
          else . end;
  [ (.model.display_name // "?")
  , (.workspace.current_dir // .cwd // "")
  # Report Claude own context_window.used_percentage verbatim: the raw fill of
  # the model window (total_input_tokens / context_window_size). We do not try
  # to model the footer undocumented auto-compact reserve, so the footer may
  # read a couple of points higher near the top. That divergence is expected.
  # Fall back to the direct ratio only if the field is absent entirely.
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
        then (.prompt_cache.expires_at // "") else "" end )
  ] | map(tostring) | join("")')

IFS=$'\037' read -r MODEL DIR_PATH PCT COST_RAW DURATION_MS \
  FIVE FIVE_AT WEEK WEEK_AT CACHE_EXP <<< "$FIELDS"

# Defaults for the malformed-payload case: every one of these feeds arithmetic
# or a numeric test below, where an empty string is a hard error, not a zero.
: "${PCT:=0}" "${DURATION_MS:=0}" "${COST_RAW:=0}"

DIR="${DIR_PATH##*/}"
# Resolve symlinks before looking for a repo. A working directory is often a
# link into a checkout, and walking its *logical* parents climbs out to the home
# directory and never sees the repo marker below the link target.
# `cd && pwd -P` rather than `readlink -f`, which older macOS does not have.
PHYS=$(cd "$DIR_PATH" 2>/dev/null && pwd -P) || PHYS=""
[ -z "$PHYS" ] && PHYS="$DIR_PATH"
COST=$(printf '$%.2f' "$COST_RAW")
MINS=$((DURATION_MS / 60000))
SECS=$(((DURATION_MS % 60000) / 1000))
NOW=$(date +%s)

# Palette. Defined up here because the VCS block below already needs it — a
# segment that emits a color without a reset bleeds into the next separator.
#
# Basic 16-color on purpose: the shade is whatever the terminal theme maps it
# to, so one shared script tracks each machine's scheme instead of imposing one.
# The fixed 256-color alternative sampled from Claude own TUI is
# 38;5;211 / 38;5;220 / 38;5;108 — swap the three below to use it.
DIM='\033[2m'; R='\033[0m'; YEL='\033[33m'
RED='\033[31m'; GOLD='\033[33m'; GRN='\033[32m'

# macOS ships no timeout(1) and no gtimeout unless coreutils is installed. That
# is survivable here only because every VCS call runs in the detached refresh
# below, which no render ever waits on — a hung repo costs a stale segment, not
# a stalled bar. Do not move a TO call onto the foreground path.
if command -v timeout >/dev/null 2>&1; then TO() { timeout "$@"; }
elif command -v gtimeout >/dev/null 2>&1; then TO() { gtimeout "$@"; }
else TO() { shift; "$@"; }; fi

mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }

# ---------------------------------------------------------------------------
# Work in flight
#
# The number next to the revision is the diff this work would land as: every
# change since it forked from upstream, working tree included. On an unmodified
# upstream commit the fork point *is* the current commit, so the same expression
# degrades to "just my uncommitted changes" with no special case. It measures
# the work, not the session — reopening a branch tomorrow still shows the whole
# thing, which is what you want when judging whether a change has grown too big.
# ---------------------------------------------------------------------------

# Count untracked lines: git and sl diffs both ignore untracked files, but a
# brand-new file is exactly the kind of work this number exists to measure.
# Capped at 200 files: reading an unbounded tree costs more than the accuracy is
# worth. Listing is cheap and stays exact, so only the reading is capped.
NEWLINES=0; TRUNC=""
count_new() {
  local new=$1
  [ -z "$new" ] && return
  NEWLINES=$(echo "$new" | head -200 | tr '\n' '\0' | xargs -0 cat 2>/dev/null | wc -l | tr -d ' ')
  # Past the cap the total is a floor, not a count. Say so, loudly — a number
  # that is silently 9x low is worse than no number.
  [ "$(echo "$new" | wc -l | tr -d ' ')" -gt 200 ] && TRUNC=" ${YEL}(!!)${R}"
}

# --no-optional-locks keeps a status line that renders on every keystroke from
# fighting a real git command for the index lock.
vcs_git() {
  local branch base from stat a d
  g() { git --no-optional-locks -C "$PHYS" "$@" 2>/dev/null; }
  branch=$(g branch --show-current)
  [ -z "$branch" ] && return
  base=$(g symbolic-ref --quiet --short refs/remotes/origin/HEAD)
  from=$(g merge-base HEAD "${base:-origin/main}")
  stat=$(g diff --shortstat "${from:-HEAD}")
  a=$(echo "$stat" | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+')
  d=$(echo "$stat" | grep -oE '[0-9]+ deletion'  | grep -oE '[0-9]+')
  count_new "$(g ls-files --others --exclude-standard)"
  a=$((${a:-0} + NEWLINES))
  emit_vcs "$branch" "$a" "${d:-0}"
}

# Some Sapling builds mandate --reason on every invocation; stock Sapling has no
# such flag and exits non-zero on it. Try the annotated form and fall back to the
# plain one. Unlike a cached capability probe, this re-decides every refresh, so
# it cannot get stuck on a wrong answer recorded during a transient failure.
#
# --cwd is not optional: without it sl resolves the repo from the *process* cwd,
# which is whatever the harness happened to launch us in, and aborts outright
# with "not inside a repository" whenever that differs from the reported dir.
s() {
  local why=$1; shift
  TO 6 sl --cwd "$PHYS" "$@" --reason "$why" 2>/dev/null \
    || TO 6 sl --cwd "$PHYS" "$@" 2>/dev/null
}

vcs_sl() {
  local label base stat a d
  # Label, in descending order of how much it tells you: an active bookmark,
  # else the review-diff id — but only on a draft commit, since a landed public
  # commit still carries one and showing it reads as if the work were still in
  # flight — else the short hash. Not every Sapling build knows the phabdiff
  # keyword, and those fail to parse the template, so fall back to a portable
  # one rather than losing the whole segment.
  label=$(s 'render statusline revision label - sl help log' log -r . \
    -T '{ifeq(bookmarks,"","{ifeq(phase,"public","{node|short}","{ifeq(phabdiff,"","{node|short}","{phabdiff}")}")}","{bookmarks}")}')
  [ -z "$label" ] && label=$(s 'render statusline revision label - sl help log' \
    log -r . -T '{ifeq(bookmarks,"","{node|short}","{bookmarks}")}')
  [ -z "$label" ] && return
  # The Sapling analog of git merge-base: the newest public ancestor is where
  # this draft stack forks from upstream, so diffing the working copy against it
  # covers the whole stack plus pending edits in one pass.
  base=$(s 'find stack base for statusline - sl help log' \
    log -r 'max(::. & public())' -T '{node|short}')
  stat=$(s 'measure work in flight for statusline - sl help diff' \
    diff --stat -r "${base:-.}" | tail -1)
  a=$(echo "$stat" | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+')
  d=$(echo "$stat" | grep -oE '[0-9]+ deletion'  | grep -oE '[0-9]+')
  count_new "$(s 'count untracked files for statusline - sl help status' status -u -n)"
  a=$((${a:-0} + NEWLINES))
  emit_vcs "$label" "$a" "${d:-0}"
}

# Nothing changed yet: show the revision alone rather than a hollow +0/-0.
emit_vcs() {
  local seg="$1"
  if [ "${2:-0}" -gt 0 ] || [ "${3:-0}" -gt 0 ]; then
    seg="${seg} ${DIM}+${2}/-${3}${R}${TRUNC}"
  fi
  printf ' |  %s' "$seg"
}

vcs_segment() {
  local d="$PHYS"
  while [ -n "$d" ] && [ "$d" != "/" ]; do
    # Sapling writes .sl in a fresh clone but keeps .hg in checkouts made before
    # the rename, so both mean the same thing and both have to be checked.
    [ -e "$d/.hg" ] || [ -e "$d/.sl" ] && { vcs_sl; return; }
    [ -e "$d/.git" ] && { vcs_git; return; }
    d="${d%/*}"
  done
}

# Serve the last known segment instantly and refresh behind it. A cold cache
# costs one render with no VCS segment, which then fills itself in — cheaper
# than making every keystroke wait on a slow or virtualised filesystem. The
# refresh must not inherit the captured stdout, or the harness blocks waiting
# for that pipe to close.
CACHE_DIR="${TMPDIR:-/tmp}/claude-statusline.$(id -u)"
mkdir -p "$CACHE_DIR" 2>/dev/null
# Key on the resolved path, so two routes to the same directory share one entry.
CF="$CACHE_DIR/vcs.$(printf '%s' "$PHYS" | cksum | cut -d' ' -f1)"
VCS=""
[ -f "$CF" ] && VCS=$(cat "$CF" 2>/dev/null)
if [ $((NOW - $(mtime "$CF"))) -ge 2 ]; then
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

# Build the bar by concatenating the multibyte glyphs directly. Do NOT use
# `tr ' ' '█'` — GNU tr is byte-oriented and keeps only the leading byte of each
# 3-byte block, producing invalid UTF-8 that renders as replacement diamonds.
# Round rather than floor, so a bar at 78% shows 8 blocks and not 7.
FILLED=$(((PCT + 5) / 10)); [ "$FILLED" -gt 10 ] && FILLED=10; EMPTY=$((10 - FILLED))
BAR=""
for ((i = 0; i < FILLED; i++)); do BAR="${BAR}█"; done
for ((i = 0; i < EMPTY; i++)); do BAR="${BAR}░"; done

fmt_left() { # seconds remaining -> single coarsest unit, e.g. 2d / 1h / 47m
  local s=$1
  [ "$s" -le 0 ] && { printf 'now'; return; }
  local m=$(((s + 59) / 60)) # round up, so we never show a misleading 0m
  if [ "$s" -ge 86400 ]; then printf '%dd' $((s / 86400))
  elif [ "$m" -ge 60 ]; then printf '%dh' $(((m + 30) / 60)) # 60m -> 1h
  else printf '%dm' "$m"; fi
}

# Subscription quota. Claude Code only sends .rate_limits on subscription auth
# (Max/Pro), so on an API key the whole segment self-hides. Shown as consumed,
# the way the API reports it: 0% on a fresh window, 100% when exhausted, so it
# counts up to match the context bar beside it. Time math stays in bash/jq on
# purpose — `date -d` (GNU) and `date -r` (BSD) are incompatible.
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
# separator between them. A cold cache has no countdown, so it disappears rather
# than reporting its own absence.
#
# 󰈸 is nf-md-fire (U+F0238), a nerd-font glyph rather than 🔥 or ⚡ on purpose:
# those are emoji presentation, so the terminal paints them its own color and
# ignores the dim. Private-use glyphs are plain outlines that take the color you
# give them, the same way the  branch icon does.
CACHE=""
[ -n "$CACHE_EXP" ] && CACHE=" 󰈸$(fmt_left $((CACHE_EXP - NOW)))"

# Groups run left to right by increasing time horizon: the working tree right
# now, then this conversation (how full, how long cached), then this session
# spend, then the quota windows measured in hours and days. Cost and elapsed
# share a group because both are session totals that only count up.
echo -e "[$MODEL] ${DIM}${DIR}${R}${VCS} | ${C}${BAR}${R} ${PCT}%${CACHE} | ${COST} ${MINS}m${SECS}s${QUOTA}"
