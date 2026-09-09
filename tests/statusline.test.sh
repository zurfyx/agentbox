#!/usr/bin/env bash
# tests/statusline.test.sh — statusline.sh is a pure stdin-JSON -> stdout-string
# filter, so almost all of it is testable by feeding it a payload and reading
# the line back. The parts worth the most here are the ones that are silently
# wrong rather than loud: bar rounding, the falsy-vs-absent quota field, the
# TZ=UTC pin around jq, and the U+001F field join.
#
# Everything runs against $SCRATCH with TMPDIR overridden by lib.sh, so the
# script's ${TMPDIR}/claude-statusline.$(id -u) cache is per-case and cold.

. "$(dirname "$0")/lib.sh"

SL="$REPO_ROOT/statusline.sh"
ESC=$(printf '\033')

# ------------------------------------------------------------------ helpers --

# run_sl JSON [VAR=VAL ...] — feed JSON on stdin, capture stdout/stderr/status.
# Env is passed through `env` rather than as a bash prefix so nothing leaks into
# the rest of the case.
run_sl() {
  local json=$1
  shift
  capture_input "$json" env "$@" bash "$SL"
}

# Strip SGR escapes, so a substring assertion reads like the rendered line.
plain() {
  printf '%s' "$1" | sed "s/${ESC}\[[0-9;]*m//g"
}

# 1 if the string contains any byte outside printable ASCII, else 0. This is
# `grep -c`, which counts LINES, so on a one-line render it is a boolean and
# NOT a byte count — do not write `assert_eq 3 "$(has_nonascii ...)"`.
# (The C locale's [:print:] is 0x20-0x7e, so tabs count as non-printable too;
# no fixture here puts a tab in the rendered line.)
has_nonascii() {
  LC_ALL=C printf '%s' "$1" | LC_ALL=C grep -c '[^[:print:]]' | tr -d ' '
}

# ISO-8601 UTC for an epoch, on both GNU (-d @N) and BSD (-r N) date.
iso_at() {
  date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
    date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ
}

# The exact cache file statusline.sh would use for a directory + icon setting.
cf_path() { # dir icons
  local phys
  phys=$(cd "$1" 2>/dev/null && pwd -P) || phys=$1
  [ -n "$phys" ] || phys=$1
  printf '%s/claude-statusline.%s/vcs.%s' "$TMPDIR" "$(id -u)" \
    "$(printf '%s %s' "$phys" "$2" | cksum | cut -d' ' -f1)"
}

# A payload with no repository and no optional segments.
base_json() { # display_name dir pct cost duration_ms
  printf '{"model":{"display_name":"%s"},"workspace":{"current_dir":"%s"},' "$1" "$2"
  printf '"context_window":{"used_percentage":%s},' "$3"
  printf '"cost":{"total_cost_usd":%s,"total_duration_ms":%s}}' "$4" "$5"
}

# --------------------------------------------------------------- happy path --

case_happy_path() {
  skip_unless jq "statusline.sh parses its payload with jq"
  run_sl "$(base_json 'Opus 5' /nonexistent/myrepo 78 12.4 1083000)"
  assert_eq 0 "$STATUS" "exits 0"
  assert_empty "$STDERR" "writes nothing to stderr"
  # Cold cache => no repository segment, by design. Everything else is fixed.
  assert_eq '[Opus 5] myrepo | ████████░░ 78% | $12.40 18m3s' \
    "$(plain "$STDOUT")" "model, dir, bar, percentage, cost and elapsed"
}
test_case "happy path renders model / dir / bar / cost / elapsed" case_happy_path

case_cost_and_elapsed_formatting() {
  skip_unless jq "needs jq"
  # 0.006, not 0.005. An exact .005 is a representational tie, and printf
  # breaks it by architecture: x86_64 bash converts through 80-bit long double
  # and rounds it down to $0.00, while arm64 and macOS round up to $0.01. The
  # claim here is "cost is formatted to 2dp", not "halfway values round a
  # particular way", so do not sit the assertion on the tie.
  run_sl "$(base_json M /nonexistent/d 0 0.006 61000)"
  assert_contains "$(plain "$STDOUT")" '$0.01 1m1s' "cost rounds to 2dp, 61s is 1m1s"
  run_sl "$(base_json M /nonexistent/d 0 1234.5 59999)"
  assert_contains "$(plain "$STDOUT")" '$1234.50 0m59s' "no thousands separator; sub-minute is 0mNNs"
  run_sl '{"model":{"display_name":"M"},"workspace":{"current_dir":"/nonexistent/d"}}'
  assert_contains "$(plain "$STDOUT")" '$0.00 0m0s' "absent cost/duration default to zero"
}
test_case "cost is \$%.2f and elapsed is MmSs" case_cost_and_elapsed_formatting

# ---------------------------------------------------------------- the bar --

# The rounding is (PCT+5)/10, so 78% is eight blocks and not seven. In ascii
# mode the bar is bracketed, which makes the whole thing one exact substring.
bar_is() { # pct want_bar want_pct_text
  run_sl "$(base_json M /nonexistent/d "$1" 0 0)" STATUSLINE_ICONS=ascii
  assert_contains "$(plain "$STDOUT")" " $2 $3% " "${1}% renders $2"
}

case_bar_rounding() {
  skip_unless jq "needs jq"
  bar_is 0   '[----------]' 0
  bar_is 4   '[----------]' 4    # 4 rounds down to zero blocks
  bar_is 5   '[#---------]' 5    # 5 is the first block
  bar_is 78  '[########--]' 78   # the regression: 8 blocks, not 7
  bar_is 94  '[#########-]' 94
  bar_is 95  '[##########]' 95   # 95 rounds up to a full bar
  bar_is 100 '[##########]' 100  # and 100 does not overflow it
}
test_case "bar rounds (PCT+5)/10 — 78% is 8 blocks" case_bar_rounding

case_bar_clamped() {
  skip_unless jq "needs jq"
  bar_is 150 '[##########]' 100
  bar_is -10 '[----------]' 0
  # Fractional percentages are rounded, not truncated.
  bar_is 78.6 '[########--]' 79
}
test_case "out-of-range percentages clamp to 0..100" case_bar_clamped

# The bar's colour ladder uses the same three constants as the quota segment's,
# and the quota one is asserted on raw escape bytes. Assert this one the same
# way, or a colour regression on the PRIMARY segment is invisible. Both
# boundary values are included: -ge 90 and -ge 70, not 91 and 71.
bar_colour_is() { # pct sgr_number label
  run_sl "$(base_json M /nonexistent/d "$1" 0 0)" STATUSLINE_ICONS=ascii
  assert_contains "$STDOUT" "${ESC}[$2m[" "${1}% draws the bar in $3"
}

case_bar_colour_thresholds() {
  skip_unless jq "needs jq"
  bar_colour_is 0   32 green
  bar_colour_is 69  32 green
  bar_colour_is 70  33 gold    # the first gold value
  bar_colour_is 89  33 gold
  bar_colour_is 90  31 red     # the first red value
  bar_colour_is 100 31 red
}
test_case "the context bar is green / gold at 70 / red at 90" case_bar_colour_thresholds

case_context_fallback() {
  skip_unless jq "needs jq"
  run_sl '{"model":{"display_name":"M"},"workspace":{"current_dir":"/nonexistent/d"},
           "context_window":{"total_input_tokens":50000,"context_window_size":200000}}' \
    STATUSLINE_ICONS=ascii
  assert_contains "$(plain "$STDOUT")" ' [###-------] 25% ' \
    "used_percentage absent falls back to total_input_tokens/context_window_size"

  run_sl '{"model":{"display_name":"M"},"workspace":{"current_dir":"/nonexistent/d"},
           "context_window":{}}' STATUSLINE_ICONS=ascii
  assert_contains "$(plain "$STDOUT")" ' [----------] 0% ' "both absent is 0%"

  # used_percentage 0 is a *value*, not an absence: it must win over the ratio.
  run_sl '{"model":{"display_name":"M"},"workspace":{"current_dir":"/nonexistent/d"},
           "context_window":{"used_percentage":0,"total_input_tokens":190000,
                             "context_window_size":200000}}' STATUSLINE_ICONS=ascii
  assert_contains "$(plain "$STDOUT")" ' [----------] 0% ' \
    "used_percentage 0 is reported, not treated as missing"
}
test_case "context percentage falls back to the token ratio" case_context_fallback

# ---------------------------------------------------------------- glyphs --

# The documented escape hatch for an unpatched terminal font: every non-ASCII
# character in the output has to travel with the one switch, so this asserts on
# the bytes rather than on any particular glyph.
case_ascii_mode_is_pure_ascii() {
  skip_unless jq "needs jq"
  local now json
  now=$(date +%s)
  json=$(printf '{"model":{"display_name":"Opus 5"},"workspace":{"current_dir":"/nonexistent/d"},
    "context_window":{"used_percentage":78},"cost":{"total_cost_usd":1,"total_duration_ms":1000},
    "rate_limits":{"five_hour":{"used_percentage":41,"resets_at":%s},
                   "seven_day":{"used_percentage":63,"resets_at":%s}},
    "prompt_cache":{"caching_observed":true,"warm":true,"expires_at":%s}}' \
    "$((now + 7200))" "$((now + 388800))" "$((now + 600))")

  run_sl "$json" STATUSLINE_ICONS=ascii
  local a
  a=$(plain "$STDOUT")
  assert_eq 0 "$(has_nonascii "$a")" "STATUSLINE_ICONS=ascii emits no non-ASCII byte"
  assert_contains "$a" '[########--]' "the bar is still drawn, in ascii"
  assert_contains "$a" '~10m' "the prompt-cache flame becomes ~"

  run_sl "$json"
  local u
  u=$(plain "$STDOUT")
  assert_contains "$u" '█' "unicode mode does emit the filled block"
  assert_contains "$u" '░' "unicode mode does emit the empty block"
  assert_eq 1 "$(has_nonascii "$u")" "unicode mode is deliberately not ASCII-only"
}
test_case "STATUSLINE_ICONS=ascii swaps every non-ASCII glyph" case_ascii_mode_is_pure_ascii

# ---------------------------------------------------------------- quota --

case_quota_absent() {
  skip_unless jq "needs jq"
  run_sl "$(base_json M /nonexistent/d 10 0 0)" STATUSLINE_ICONS=ascii
  local a
  a=$(plain "$STDOUT")
  # On API-key auth the host sends no .rate_limits at all: the whole trailing
  # group, separator included, has to disappear.
  assert_eq '[M] d | [#---------] 10% | $0.00 0m0s' "$a" "no rate_limits, no quota segment"
}
test_case "absent .rate_limits hides the whole quota segment" case_quota_absent

case_quota_five_hour_only() {
  skip_unless jq "needs jq"
  local now
  now=$(date +%s)
  run_sl "$(printf '{"model":{"display_name":"M"},"workspace":{"current_dir":"/nonexistent/d"},
    "rate_limits":{"five_hour":{"used_percentage":41,"resets_at":%s}}}' "$((now + 7200))")" \
    STATUSLINE_ICONS=ascii
  local a
  a=$(plain "$STDOUT")
  assert_contains "$a" '| 41% 2h' "five_hour alone renders"
  assert_eq '41% 2h' "${a##*| }" "and nothing trails it (no empty seven_day slot)"
}
test_case "five_hour alone renders without a seven_day slot" case_quota_five_hour_only

case_quota_both_and_thresholds() {
  skip_unless jq "needs jq"
  local now
  now=$(date +%s)
  run_sl "$(printf '{"model":{"display_name":"M"},"workspace":{"current_dir":"/nonexistent/d"},
    "rate_limits":{"five_hour":{"used_percentage":63,"resets_at":%s},
                   "seven_day":{"used_percentage":91,"resets_at":%s}}}' \
    "$((now + 7200))" "$((now + 388800))")" STATUSLINE_ICONS=ascii
  assert_eq '63% 2h 91% 4d' "$(plain "$STDOUT" | sed 's/.*| //')" "both windows render, in order"
  # Colour thresholds live in the raw bytes: dim under 70, gold at 70, red at 90.
  assert_contains "$STDOUT" "${ESC}[2m63%" "63% is dim"
  assert_contains "$STDOUT" "${ESC}[31m91%" "91% is red"

  run_sl "$(printf '{"model":{"display_name":"M"},"workspace":{"current_dir":"/nonexistent/d"},
    "rate_limits":{"five_hour":{"used_percentage":70,"resets_at":%s},
                   "seven_day":{"used_percentage":89,"resets_at":%s}}}' \
    "$((now + 7200))" "$((now + 388800))")" STATUSLINE_ICONS=ascii
  assert_contains "$STDOUT" "${ESC}[33m70%" "70% is the first gold value"
  assert_contains "$STDOUT" "${ESC}[33m89%" "89% is still gold"
  assert_not_contains "$STDOUT" "${ESC}[31m" "and nothing is red below 90"

  # 90 itself: the one value the `-ge 90` comparison actually turns on, and the
  # one the table above steps around.
  run_sl "$(printf '{"model":{"display_name":"M"},"workspace":{"current_dir":"/nonexistent/d"},
    "rate_limits":{"five_hour":{"used_percentage":69,"resets_at":%s},
                   "seven_day":{"used_percentage":90,"resets_at":%s}}}' \
    "$((now + 7200))" "$((now + 388800))")" STATUSLINE_ICONS=ascii
  assert_contains "$STDOUT" "${ESC}[31m90%" "90% is the first red value"
  assert_contains "$STDOUT" "${ESC}[2m69%" "69% is the last dim one"
}
test_case "both quota windows render with 70/90 colour thresholds" case_quota_both_and_thresholds

case_quota_zero_and_label_fallback() {
  skip_unless jq "needs jq"
  # 0 is falsy in jq's // — the source uses an explicit null test, and a fresh
  # window at 0% must still be shown rather than vanishing.
  run_sl '{"model":{"display_name":"M"},"workspace":{"current_dir":"/nonexistent/d"},
          "rate_limits":{"five_hour":{"used_percentage":0},
                         "seven_day":{"used_percentage":0}}}' STATUSLINE_ICONS=ascii
  local a
  a=$(plain "$STDOUT")
  assert_contains "$a" '| 0% 5h 0% 7d' "0% renders, and falls back to the static window label"
}
test_case "quota used_percentage 0 still renders (falsy is not absent)" case_quota_zero_and_label_fallback

# ---------------------------------------------------------------- fmt_left --

# fmt_left is reachable through the quota countdown. resets_at goes in as a raw
# epoch here so the only thing under test is the seconds -> label arithmetic.
# The clock is frozen for these cases. statusline.sh reads its own `date +%s`,
# so stamping resets_at from the test's clock leaves a window in which the
# second ticks over between the two reads: +86400 arrives as 86399 and the
# `-ge 86400` day boundary quietly renders 24h instead of 1d. That is a real
# flake, caught once on macOS. Stubbing date is what lets these assert the exact
# boundary instead of retreating to a value safely inside the branch.
AB_FROZEN_NOW=1800000000

left_is() { # seconds_from_now want
  run_sl "$(printf '{"model":{"display_name":"M"},"workspace":{"current_dir":"/nonexistent/d"},
    "rate_limits":{"five_hour":{"used_percentage":10,"resets_at":%s}}}' "$((AB_FROZEN_NOW + $1))")" \
    STATUSLINE_ICONS=ascii
  local a
  a=$(plain "$STDOUT")
  assert_eq "10% $2" "${a##*| }" "+${1}s reads as $2"
}

case_fmt_left() {
  skip_unless jq "needs jq"
  stub_bin date 'case "$1" in +%s) printf "%s\n" 1800000000 ;; *) command -p date "$@" ;; esac'
  left_is -10 now      # already past
  left_is 0 now        # exactly due
  left_is 5 1m         # rounds up: never a misleading 0m
  left_is 90 2m
  left_is 3600 1h      # m == 60 exactly, the value `-ge 60` turns on
  left_is 3620 1h      # once minutes reach 60 the unit collapses to hours
  left_is 3000 50m     # but 50m stays in minutes
  left_is 2000 34m     # 33.3m rounds up to 34m, still minutes
  left_is 86000 24h    # just under a day is still hours
  left_is 86400 1d     # exactly one day, the value `-ge 86400` turns on
  left_is 90000 1d     # and a day-plus is days
  left_is 388800 4d
}
test_case "fmt_left picks one coarsest unit and never shows 0m" case_fmt_left

case_resets_at_iso_string() {
  skip_unless jq "needs jq"
  local now
  now=$(date +%s)
  # An ISO string, the way the host actually sends it.
  run_sl "$(printf '{"model":{"display_name":"M"},"workspace":{"current_dir":"/nonexistent/d"},
    "rate_limits":{"five_hour":{"used_percentage":10,"resets_at":"%s"}}}' \
    "$(iso_at $((now + 7200)))")" STATUSLINE_ICONS=ascii
  assert_empty "$STDERR" "an ISO reset time is parsed without complaint"
  assert_eq '10% 2h' "$(plain "$STDOUT" | sed 's/.*| //')" "ISO string resets_at counts down"

  # Fractional seconds: jq's fromdateiso8601 rejects them, hence the sub().
  local frac
  frac=$(iso_at $((now + 7200)))
  frac="${frac%Z}.123456Z"
  run_sl "$(printf '{"model":{"display_name":"M"},"workspace":{"current_dir":"/nonexistent/d"},
    "rate_limits":{"five_hour":{"used_percentage":10,"resets_at":"%s"}}}' "$frac")" \
    STATUSLINE_ICONS=ascii
  assert_empty "$STDERR" "fractional seconds are stripped, not fatal"
  assert_eq '10% 2h' "$(plain "$STDOUT" | sed 's/.*| //')" "fractional-second resets_at still counts down"
}
test_case "resets_at accepts an epoch number and an ISO string" case_resets_at_iso_string

# THE REGRESSION. jq 1.6's fromdateiso8601 leaves tm_isdst set and glibc's
# mktime then "corrects" an already-UTC timestamp, so an ISO reset time comes
# back an hour off while DST is in effect — right in winter, wrong in summer.
# statusline.sh pins TZ=UTC around the jq call; this fails by exactly 60 minutes
# if that pin is ever removed.
dst_offset_is_ignored() { # tz
  local now iso a
  now=$(date +%s)
  # +2h05m: a one-hour shift in either direction lands on 1h or 3h, never 2h.
  iso=$(iso_at $((now + 7500)))
  run_sl "$(printf '{"model":{"display_name":"M"},"workspace":{"current_dir":"/nonexistent/d"},
    "rate_limits":{"five_hour":{"used_percentage":10,"resets_at":"%s"}}}' "$iso")" \
    STATUSLINE_ICONS=ascii "TZ=$1"
  a=$(plain "$STDOUT" | sed 's/.*| //')
  assert_eq '10% 2h' "$a" "TZ=$1 does not shift the countdown"
}

case_tz_dst_regression() {
  skip_unless jq "needs jq"
  skip_unless_file /usr/share/zoneinfo/Europe/Madrid "a tz database to set a DST-active zone"
  # September: DST is active in both of these, so an unpinned jq is off by 3600s.
  dst_offset_is_ignored Europe/Madrid
  dst_offset_is_ignored America/New_York
  # A summer reset time read from a winter clock, and the reverse, are the same
  # bug seen from the other side; UTC must give the identical answer.
  dst_offset_is_ignored UTC
}
test_case "TZ=UTC pin: a DST-active zone does not shift the reset by an hour" case_tz_dst_regression

# ---------------------------------------------------------- prompt cache --

flame_case() { # caching_observed warm expires_json want_flame(1|0)
  local now
  now=$(date +%s)
  run_sl "$(printf '{"model":{"display_name":"M"},"workspace":{"current_dir":"/nonexistent/d"},
    "prompt_cache":{"caching_observed":%s,"warm":%s%s}}' "$1" "$2" "$3")" \
    STATUSLINE_ICONS=ascii
  local a
  a=$(plain "$STDOUT")
  if [ "$4" = 1 ]; then
    assert_contains "$a" '0% ~10m' "caching_observed=$1 warm=$2 shows the flame"
  else
    assert_not_contains "$a" '~' "caching_observed=$1 warm=$2$3 hides the flame"
  fi
}

case_prompt_cache_flame() {
  skip_unless jq "needs jq"
  local exp
  # +600s, not +300s: fmt_left rounds minutes UP, so a +300s fixture has only
  # 59 seconds of slack between the test's clock read and the script's. +600s
  # buys ten times that for nothing.
  exp=$(printf ',"expires_at":%s' "$(( $(date +%s) + 600 ))")
  flame_case true  true  "$exp" 1
  flame_case false true  "$exp" 0   # a provider that never caches is not "cold"
  flame_case true  false "$exp" 0
  flame_case false false "$exp" 0
  flame_case true  true  ""     0   # warm, but no expiry to count down
}
test_case "prompt-cache flame needs caching_observed AND warm AND expires_at" case_prompt_cache_flame

# KNOWN SOURCE BUG. Every other timestamp in the payload goes through the jq
# `ep` helper, which accepts an epoch number *or* an ISO string; field 10,
# .prompt_cache.expires_at, is the one that does not. An ISO expires_at
# therefore reaches `$((CACHE_EXP - NOW))` as a date string and bash reports an
# arithmetic error, leaving a flame with no countdown beside it. One `| ep` on
# that field in the jq program fixes it. Marked xfail: the run stays green, the
# bug stays listed in the summary, and deleting the marker is the test that the
# one-token fix worked.
case_prompt_cache_iso_expiry() {
  skip_unless jq "needs jq"
  run_sl "$(printf '{"model":{"display_name":"M"},"workspace":{"current_dir":"/nonexistent/d"},
    "prompt_cache":{"caching_observed":true,"warm":true,"expires_at":"%s"}}' \
    "$(iso_at $(( $(date +%s) + 600 )))")" STATUSLINE_ICONS=ascii
  xfail "statusline.sh:80 does not pipe .prompt_cache.expires_at through the jq \`ep\` helper"
  assert_not_contains "$STDERR" "statusline.sh:" \
    "an ISO expires_at must not reach bash arithmetic"
  assert_contains "$(plain "$STDOUT")" '0% ~10m' \
    "an ISO expires_at counts down like resets_at does"
  xfail_off
}
test_case "ISO prompt_cache.expires_at (KNOWN SOURCE BUG)" case_prompt_cache_iso_expiry

# ------------------------------------------------------------- robustness --

# bad_input_is_survivable PAYLOAD LABEL [WHOLE_LINE] — exit 0, no bash-level
# error, and a complete render. Pass WHOLE_LINE to pin the line exactly, which
# is also what pins the jq `// "?"` model default: without it an absent
# display_name renders the literal `[null]` and a substring assertion on the
# tail would not notice.
bad_input_is_survivable() {
  run_sl "$1" STATUSLINE_ICONS=ascii
  assert_eq 0 "$STATUS" "[$2] exits 0"
  # Any bash-level error (arithmetic, unbound, syntax) is prefixed with the
  # script path — this is the assertion that catches an empty field reaching
  # $(( )).
  assert_not_contains "$STDERR" "statusline.sh:" "[$2] no bash error on stderr"
  if [ -n "${3:-}" ]; then
    assert_eq "$3" "$(plain "$STDOUT")" "[$2] renders exactly the degraded line"
  else
    assert_contains "$(plain "$STDOUT")" '0% | $0.00 0m0s' "[$2] still renders a whole line"
  fi
}

case_malformed_input() {
  skip_unless jq "needs jq"
  # jq emits nothing at all for empty stdin, so every field including the model
  # is empty — that is a different degraded line from `{}`, where jq runs and
  # the defaults inside the program apply.
  bad_input_is_survivable '' 'empty stdin' \
    '[]  | [----------] 0% | $0.00 0m0s'
  assert_empty "$STDERR" "empty stdin leaves stderr clean"
  bad_input_is_survivable '{}' 'empty object' \
    '[?]  | [----------] 0% | $0.00 0m0s'
  assert_empty "$STDERR" "{} leaves stderr clean"
  bad_input_is_survivable 'null' 'JSON null' \
    '[?]  | [----------] 0% | $0.00 0m0s'
  assert_empty "$STDERR" "null leaves stderr clean"
  bad_input_is_survivable '{"model":{"display_name":null},"cost":{"total_cost_usd":null}}' \
    'explicit nulls' '[?]  | [----------] 0% | $0.00 0m0s'
  # jq's own parse diagnostic reaches stderr here; that is jq telling the truth
  # about the payload, not a bash error, so only the render is pinned.
  bad_input_is_survivable 'garbage {' 'non-JSON garbage'
}
test_case "empty / {} / null / garbage stdin never breaks the render" case_malformed_input

case_fields_do_not_shift() {
  skip_unless jq "needs jq"
  local now
  now=$(date +%s)
  # five_hour.used_percentage is absent while everything after it is present.
  # The jq join uses U+001F precisely so this empty field keeps its slot; with a
  # tab (IFS whitespace) bash would collapse it and seven_day's 88% would be
  # read as five_hour's, silently reporting the wrong window.
  run_sl "$(printf '{"model":{"display_name":"M"},"workspace":{"current_dir":"/nonexistent/d"},
    "rate_limits":{"five_hour":{"resets_at":%s},
                   "seven_day":{"used_percentage":88,"resets_at":%s}},
    "prompt_cache":{"caching_observed":true,"warm":true,"expires_at":%s}}' \
    "$((now + 7200))" "$((now + 388800))" "$((now + 600))")" STATUSLINE_ICONS=ascii
  local a
  a=$(plain "$STDOUT")
  assert_eq '88% 4d' "${a##*| }" "the empty middle field does not shift 88%/4d left"
  assert_not_contains "$a" '2h' "five_hour's reset is not adopted by seven_day"
  assert_contains "$a" '~10m' "and the field after the quota pair is still in place"
}
test_case "an empty middle field does not shift later fields (U+001F join)" case_fields_do_not_shift

case_whitespace_in_fields() {
  skip_unless jq "needs jq"
  # IFS is *replaced* with U+001F, so spaces and tabs inside a field survive
  # intact instead of splitting it.
  run_sl '{"model":{"display_name":"Opus 5  (1M)"},
           "workspace":{"current_dir":"/nonexistent/my repo"},
           "context_window":{"used_percentage":50}}' STATUSLINE_ICONS=ascii
  local a
  a=$(plain "$STDOUT")
  assert_contains "$a" '[Opus 5  (1M)] my repo ' "spaces inside model name and dir are preserved"

  run_sl '{"model":{"display_name":"A\tB"},"workspace":{"current_dir":"/nonexistent/d"}}' \
    STATUSLINE_ICONS=ascii
  assert_contains "$(plain "$STDOUT")" "$(printf '[A\tB]')" "a tab inside a field does not split it"
}
test_case "spaces and tabs inside a field are preserved" case_whitespace_in_fields

case_backslashes_in_fields() {
  skip_unless jq "needs jq"
  # `read -r` is load-bearing and no payload in this file used to contain a
  # backslash. Without -r, read eats them: a model name and a directory both
  # come out short, and a value ENDING in one escapes the U+001F delimiter and
  # shifts every later field.
  run_sl '{"model":{"display_name":"A\\B"},
           "workspace":{"current_dir":"/nonexistent/my\\dir"}}' STATUSLINE_ICONS=ascii
  local a
  a=$(plain "$STDOUT")
  assert_contains "$a" '[A\B]' "a backslash inside the model name survives"
  assert_contains "$a" 'my\dir' "and one inside the directory name survives"

  # A field whose value ENDS in a backslash. Without -r this splices the next
  # field onto it and the percentage is read from the wrong slot.
  run_sl '{"model":{"display_name":"M"},"workspace":{"current_dir":"/nonexistent/dir\\"},
           "context_window":{"used_percentage":50}}' STATUSLINE_ICONS=ascii
  assert_empty "$STDERR" "a trailing backslash is not an error"
  assert_contains "$(plain "$STDOUT")" '[#####-----] 50%' \
    "and does not splice the following field onto it"
}
test_case "backslashes inside fields are literal (read -r)" case_backslashes_in_fields

case_cwd_fallback() {
  skip_unless jq "needs jq"
  # Some hosts send only .cwd, with no .workspace object at all. Dropping that
  # fallback blanks DIR *and* PHYS, which silently kills the whole repository
  # segment as well — a total feature loss with no error anywhere.
  run_sl '{"model":{"display_name":"M"},"cwd":"/nonexistent/myrepo"}' STATUSLINE_ICONS=ascii
  assert_eq '[M] myrepo | [----------] 0% | $0.00 0m0s' "$(plain "$STDOUT")" \
    ".cwd is used when .workspace.current_dir is absent"

  # workspace.current_dir wins when both are present.
  run_sl '{"model":{"display_name":"M"},"cwd":"/nonexistent/wrong",
           "workspace":{"current_dir":"/nonexistent/right"}}' STATUSLINE_ICONS=ascii
  assert_contains "$(plain "$STDOUT")" '[M] right ' \
    "workspace.current_dir takes precedence over .cwd"
}
test_case "current_dir falls back to .cwd" case_cwd_fallback

# ------------------------------------------------------------------- vcs --

# Deterministic by construction: the first render against a cold cache is
# *expected* to show no repository segment, so this waits for the detached
# refresh to publish the cache file before rendering again. The wait is bounded
# and its failure is explicit rather than a silent missing assertion.
#
# wait_for_cache wants a NON-EMPTY entry; wait_for_cache_file only wants the
# entry to exist, which is what a repository that renders no segment (detached
# HEAD, no checkout) publishes.
__wait_for() { # nonempty|exists  file
  local i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 \
           21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40; do
    case $1 in
      nonempty) [ -s "$2" ] && return 0 ;;
      *)        [ -f "$2" ] && return 0 ;;
    esac
    sleep 0.25
  done
  return 1
}
wait_for_cache()      { __wait_for nonempty "$1"; }
wait_for_cache_file() { __wait_for exists   "$1"; }

# git_fixture DIR CMD... — run a git setup script inside DIR, and if it fails,
# say WHY. Swallowing the output here once cost an afternoon: the real message
# was "detected dubious ownership", which lib.sh now prevents outright.
git_fixture() { # dir  (setup commands are read from stdin)
  local dir log
  dir=$1
  mkdir -p "$dir" || fail "cannot create the fixture dir $dir"
  log=$SCRATCH/git-fixture.log
  if ! ( cd "$dir" && sh -e ) > "$log" 2>&1; then
    fail "could not build the throwaway git repo: $(tr '\n' ' ' < "$log")"
  fi
}

case_git_segment() {
  skip_unless jq "needs jq"
  skip_unless git "a git checkout to describe"
  local repo cf a
  repo=$SCRATCH/work
  # `two words.txt` is deliberate: count_new pipes the untracked list through
  # `tr '\n' '\0' | xargs -0`, and without the -0 a path with a space is split
  # into two words that cat then misses — a silent UNDERCOUNT, which is exactly
  # what the loud truncation marker exists to avoid elsewhere.
  git_fixture "$repo" <<'SETUP'
git init -q .
printf 'one\ntwo\nthree\n' > a.txt
git add a.txt
git commit -q -m init
git branch -m testbranch
printf 'one\nthree\nfour\n' > a.txt
printf 'n1\nn2\n' > new.txt
printf 'w1\nw2\n' > 'two words.txt'
SETUP

  cf=$(cf_path "$repo" ascii)
  run_sl "$(base_json M "$repo" 0 0 0)" STATUSLINE_ICONS=ascii
  assert_not_contains "$(plain "$STDOUT")" 'testbranch' \
    "a cold cache renders without the repo segment, by design"

  wait_for_cache "$cf" || fail "background vcs refresh did not publish $cf"
  run_sl "$(base_json M "$repo" 0 0 0)" STATUSLINE_ICONS=ascii
  a=$(plain "$STDOUT")
  # 1 insertion in the tracked file + 2 + 2 lines of untracked file = +5; 1 deletion.
  assert_contains "$a" '| @ testbranch +5/-1 |' "branch plus the whole diff in flight"
  assert_eq 0 "$(has_nonascii "$a")" "the repo segment is ASCII too under STATUSLINE_ICONS=ascii"
}
test_case "git segment shows the branch and +N/-N including untracked lines" case_git_segment

# `.git` is a DIRECTORY only in a plain clone. In a worktree or a submodule it
# is a FILE, so `[ -e ]` rather than `[ -d ]` is load-bearing — and worktrees
# are normal usage for anyone running several agents against one checkout.
# Detached HEAD is the other degraded shape: `branch --show-current` is empty,
# and without the guard the segment renders as a bare `@` with no label.
case_git_worktree_and_detached_head() {
  skip_unless jq "needs jq"
  skip_unless git "a git checkout to describe"
  local repo wt cf a
  repo=$SCRATCH/main
  wt=$SCRATCH/wt
  git_fixture "$repo" <<SETUP
git init -q .
echo seed > seed.txt
git add seed.txt
git commit -q -m init
git branch -m trunk
git worktree add -b side "$wt"
SETUP
  assert_status -m "the worktree's .git is a file, not a directory" 1 test -d "$wt/.git"
  assert_file_exists "$wt/.git" "but it does exist"

  cf=$(cf_path "$wt" ascii)
  run_sl "$(base_json M "$wt" 0 0 0)" STATUSLINE_ICONS=ascii
  wait_for_cache "$cf" || fail "background vcs refresh did not publish $cf"
  run_sl "$(base_json M "$wt" 0 0 0)" STATUSLINE_ICONS=ascii
  assert_contains "$(plain "$STDOUT")" '| @ side |' \
    "a worktree, where .git is a file, still gets a repository segment"

  # Now detach HEAD in the main checkout: no branch name, so no segment at all.
  git_fixture "$repo" <<'SETUP'
git checkout -q --detach
SETUP
  cf=$(cf_path "$repo" ascii)
  run_sl "$(base_json M "$repo" 0 0 0)" STATUSLINE_ICONS=ascii
  wait_for_cache_file "$cf" || fail "background vcs refresh did not publish $cf"
  run_sl "$(base_json M "$repo" 0 0 0)" STATUSLINE_ICONS=ascii
  a=$(plain "$STDOUT")
  assert_not_contains "$a" '@' "a detached HEAD emits no segment rather than an empty label"
  assert_eq '[M] main | [----------] 0% | $0.00 0m0s' "$a" "and the rest of the line is intact"
}
test_case "worktrees (.git is a file) render; a detached HEAD stays silent" case_git_worktree_and_detached_head

# make_untracked REPO N — a repo with exactly N untracked one-line files.
make_untracked() {
  local repo n i
  repo=$1; n=$2
  git_fixture "$repo" <<'SETUP'
git init -q .
echo seed > seed.txt
git add seed.txt
git commit -q -m init
SETUP
  i=1
  while [ "$i" -le "$n" ]; do
    echo x > "$repo/f$i.txt"
    i=$((i + 1))
  done
}

# The cap is `> 200`, and the marker's whole point is to distinguish a floor
# from an exact count — so the interesting value is 200 itself, where the count
# is complete and the marker must NOT appear.
case_untracked_truncation() {
  skip_unless jq "needs jq"
  skip_unless git "a git checkout to describe"
  local repo cf a
  repo=$SCRATCH/exactly200
  make_untracked "$repo" 200
  cf=$(cf_path "$repo" ascii)
  run_sl "$(base_json M "$repo" 0 0 0)" STATUSLINE_ICONS=ascii
  wait_for_cache "$cf" || fail "background vcs refresh did not publish $cf"
  run_sl "$(base_json M "$repo" 0 0 0)" STATUSLINE_ICONS=ascii
  a=$(plain "$STDOUT")
  assert_contains "$a" '+200/-0' "exactly 200 untracked files are all counted"
  assert_not_contains "$a" '(!!)' "and 200 is an exact count, so it carries no marker"

  repo=$SCRATCH/over200
  make_untracked "$repo" 201
  cf=$(cf_path "$repo" ascii)
  run_sl "$(base_json M "$repo" 0 0 0)" STATUSLINE_ICONS=ascii
  wait_for_cache "$cf" || fail "background vcs refresh did not publish $cf"
  run_sl "$(base_json M "$repo" 0 0 0)" STATUSLINE_ICONS=ascii
  a=$(plain "$STDOUT")
  assert_contains "$a" '+200/-0' "201 untracked files stop at the 200-file cap"
  assert_contains "$a" '(!!)' "and 201 is a floor, so it says so loudly"
}
test_case "untracked counting caps at 200 files and marks only a floor" case_untracked_truncation

case_cache_is_served_and_keyed_by_icons() {
  skip_unless jq "needs jq"
  local dir cf other a
  dir=$SCRATCH/cached
  mkdir -p "$dir"
  cf=$(cf_path "$dir" ascii)
  mkdir -p "$(dirname "$cf")"
  printf ' | @ seeded +7/-8' > "$cf"

  # A long TTL keeps the refresh from firing, so what comes back is the cache.
  run_sl "$(base_json M "$dir" 0 0 0)" STATUSLINE_ICONS=ascii STATUSLINE_TTL=99999
  a=$(plain "$STDOUT")
  assert_contains "$a" '| @ seeded +7/-8 |' "a warm cache entry is served verbatim"

  # The cached value is the *rendered* segment, glyphs included, so the icon
  # setting is part of the key: unicode mode must not be handed the ascii draw.
  # Asserted positively — the old `assert_ne "$cf" "$other"` compared two
  # outputs of this file's OWN cf_path helper and never ran statusline.sh at
  # all, and its `assert_not_contains ... seeded` neighbour was satisfied by any
  # output including none.
  other=$(cf_path "$dir" "")
  run_sl "$(base_json M "$dir" 0 0 0)" STATUSLINE_TTL=99999
  assert_eq '[M] cached | ░░░░░░░░░░ 0% | $0.00 0m0s' "$(plain "$STDOUT")" \
    "unicode mode renders the complete line MINUS the ascii cache entry"
  assert_ne "$(cat "$cf")" "$(cat "$other" 2>/dev/null)" \
    "the two icon settings really are two different cache entries"
}
test_case "the vcs cache is served and is keyed by STATUSLINE_ICONS" case_cache_is_served_and_keyed_by_icons

# The refresh fires when `age -ge $STATUSLINE_TTL`. Age is 0 immediately after
# the entry is written, so TTL=0 is the boundary itself — no clock fixture, no
# `touch -d` (GNU-only), and `-gt` instead of `-ge` leaves the stale entry in
# place forever at that setting.
case_cache_ttl_boundary() {
  skip_unless jq "needs jq"
  local dir cf i
  dir=$SCRATCH/ttl
  mkdir -p "$dir"
  cf=$(cf_path "$dir" ascii)
  mkdir -p "$(dirname "$cf")"
  printf ' | @ stale +1/-1' > "$cf"

  run_sl "$(base_json M "$dir" 0 0 0)" STATUSLINE_ICONS=ascii STATUSLINE_TTL=0
  assert_contains "$(plain "$STDOUT")" '@ stale' "the stale entry is still served this render"
  # $dir is not a checkout, so a refresh that fires replaces it with nothing.
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [ -s "$cf" ] || break
    sleep 0.25
  done
  assert_eq "" "$(cat "$cf")" "age == TTL is stale enough to trigger a refresh"
}
test_case "the cache refreshes when age reaches the TTL exactly" case_cache_ttl_boundary

case_no_repo_no_segment() {
  skip_unless jq "needs jq"
  local dir
  dir=$SCRATCH/plain
  mkdir -p "$dir"
  run_sl "$(base_json M "$dir" 0 0 0)" STATUSLINE_ICONS=ascii
  # Two separators only: dir|bar and bar|cost. A repo segment would add a third.
  assert_eq '[M] plain | [----------] 0% | $0.00 0m0s' "$(plain "$STDOUT")" \
    "a directory outside any checkout renders no repository segment"
  run_sl "$(base_json M "$dir" 0 0 0)" STATUSLINE_ICONS=ascii
  assert_not_contains "$(plain "$STDOUT")" '@' \
    "and the refreshed cache stays empty rather than inventing one"
}
test_case "no checkout means no repository segment, warm or cold" case_no_repo_no_segment
