#!/usr/bin/env bash
# tests/run.sh — the entrypoint for the agentbox test suite.
#
#   ./tests/run.sh                          run every tests/*.test.sh
#   ./tests/run.sh statusline               run tests/statusline.test.sh
#   ./tests/run.sh tests/onhost.test.sh …   run the named files (any path)
#   ./tests/run.sh -k 'github|token'        run only cases whose name matches
#   ./tests/run.sh -q                       print failures and skips only
#   ./tests/run.sh -l                       list the test files and exit
#
# Each file runs in its own process, so a file that crashes cannot take the run
# with it. Exit status is 0 only when nothing failed, nothing crashed, and at
# least one assertion actually ran.
#
# bash 3.2 compatible on purpose (macOS /bin/bash). No bats, no shellcheck,
# no docker, no jq.

AB_TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$AB_TESTS_DIR/.." && pwd)
export AB_TESTS_DIR REPO_ROOT

AB_FILTER=${AB_FILTER:-}
AB_QUIET=${AB_QUIET:-0}
AB_KEEP_SCRATCH=${AB_KEEP_SCRATCH:-0}
list_only=0
targets=""

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case $1 in
    -k | --filter)
      AB_FILTER=$2; shift 2 || exit 2 ;;
    -k=* | --filter=*)
      AB_FILTER=${1#*=}; shift ;;
    -q | --quiet)   AB_QUIET=1; shift ;;
    -l | --list)    list_only=1; shift ;;
    --keep)         AB_KEEP_SCRATCH=1; shift ;;
    --no-color)     AB_COLOR=0; shift ;;
    -h | --help)    usage; exit 0 ;;
    --)             shift; while [ $# -gt 0 ]; do targets="$targets$1
"; shift; done ;;
    -*)
      printf 'run.sh: unknown option %s (try --help)\n' "$1" >&2; exit 2 ;;
    *)
      targets="$targets$1
"; shift ;;
  esac
done

if [ -z "${AB_COLOR:-}" ]; then
  if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then AB_COLOR=1; else AB_COLOR=0; fi
fi
if [ "$AB_COLOR" = 1 ]; then
  ESC=$(printf '\033')
  C_RED=$ESC'[31m'; C_GREEN=$ESC'[32m'; C_YELLOW=$ESC'[33m'
  C_BOLD=$ESC'[1m'; C_DIM=$ESC'[2m'; C_OFF=$ESC'[0m'
else
  C_RED=''; C_GREEN=''; C_YELLOW=''; C_BOLD=''; C_DIM=''; C_OFF=''
fi

# ---------------------------------------------------------------- discovery --
# A target may be a path, a file name, or a bare fragment ("statusline").
#
# tests/ is searched BEFORE the working directory. `./tests/run.sh onhost` from
# the repo root would otherwise resolve to the repo's own `onhost` script — a
# real file, cwd-relative — and report it as a crashing test file. A path that
# is genuinely meant to be relative (harness.test.sh writes throwaway files into
# $SCRATCH and runs them by name) still works: it just loses a tie it should
# never have been winning.
resolve_target() {
  local t
  t=$1
  if [ -f "$AB_TESTS_DIR/$t.test.sh" ]; then printf '%s\n' "$AB_TESTS_DIR/$t.test.sh"; return 0; fi
  if [ -f "$AB_TESTS_DIR/$t" ]; then printf '%s\n' "$AB_TESTS_DIR/$t"; return 0; fi
  if [ -f "$t" ]; then printf '%s\n' "$t"; return 0; fi
  local hit found
  found=0
  for hit in "$AB_TESTS_DIR"/*"$t"*.test.sh; do
    [ -f "$hit" ] || continue
    printf '%s\n' "$hit"
    found=1
  done
  [ "$found" = 1 ]
}

files=""
if [ -n "$targets" ]; then
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    hits=$(resolve_target "$t")
    if [ -z "$hits" ]; then
      printf '%srun.sh: no test file matches %s%s\n' "$C_RED" "$t" "$C_OFF" >&2
      exit 2
    fi
    files="$files$hits
"
  done <<TARGETS
$targets
TARGETS
else
  for f in "$AB_TESTS_DIR"/*.test.sh; do
    [ -f "$f" ] || continue
    files="$files$f
"
  done
fi

if [ "$list_only" = 1 ]; then
  printf '%s' "$files"
  exit 0
fi

if [ -z "$files" ]; then
  printf '%srun.sh: no test files found in %s%s\n' "$C_RED" "$AB_TESTS_DIR" "$C_OFF" >&2
  exit 1
fi

# ------------------------------------------------------------------- run it --
# macOS sets TMPDIR with a trailing slash (/var/folders/.../T/), which would put
# a // inside every scratch path. The paths under test come back normalized (make
# reports $(PWD), pwd -P collapses it), so an un-normalized base makes a handful
# of exact-match assertions fail on macOS and only on macOS. Strip it here, once.
AB_TMP_BASE=${TMPDIR:-/tmp}
while [ "$AB_TMP_BASE" != "/" ] && [ "${AB_TMP_BASE%/}" != "$AB_TMP_BASE" ]; do
  AB_TMP_BASE=${AB_TMP_BASE%/}
done
[ -n "$AB_TMP_BASE" ] || AB_TMP_BASE=/tmp
AB_RUN_DIR=$(mktemp -d "$AB_TMP_BASE/agentbox-tests.XXXXXX") || exit 1
cleanup() {
  if [ "$AB_KEEP_SCRATCH" = 1 ]; then
    printf 'run.sh: kept %s\n' "$AB_RUN_DIR"
  else
    rm -rf "$AB_RUN_DIR"
  fi
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

export AB_RUN_DIR AB_FILTER AB_QUIET AB_COLOR AB_KEEP_SCRATCH

# Count events of one kind in one tally file (count_of) or across the whole
# run (count_all). Globs stay quoted at the prefix so a $TMPDIR with a space
# in it cannot split them.
count_of() { # kind tallyfile
  awk -F'\t' -v k="$1" '$1 == k { n++ } END { printf "%d", n+0 }' "$2" 2>/dev/null
}
count_all() { # kind
  cat "$AB_RUN_DIR"/tally.* 2>/dev/null |
    awk -F'\t' -v k="$1" '$1 == k { n++ } END { printf "%d", n+0 }'
}

crashed=0
crashed_files=""
n=0
while IFS= read -r file; do
  [ -n "$file" ] || continue
  n=$((n + 1))
  AB_TALLY=$AB_RUN_DIR/tally.$n
  : > "$AB_TALLY"
  export AB_TALLY

  printf '%s==%s %s\n' "$C_BOLD" "$C_OFF" "$file"
  bash "$file"
  status=$?

  # 96 / 97 are lib.sh's AB_EXIT_SKIP / AB_EXIT_FAIL: a file that ended in a
  # top-level skip or fail already recorded it. Anything else non-zero is a
  # genuine crash (syntax error, set -e, a signal) and is reported as one.
  case $status in
    0 | 96 | 97) ;;
    *)
      crashed=$((crashed + 1))
      crashed_files="$crashed_files  $file (exit $status)
"
      printf '%s!!%s %s crashed (exit status %s)\n' "$C_RED" "$C_OFF" "$file" "$status"
      ;;
  esac

  fp=$(count_of pass "$AB_TALLY")
  ff=$(count_of fail "$AB_TALLY")
  fs=$(count_of skip "$AB_TALLY")
  printf '%s--%s %s passed, %s failed, %s skipped\n\n' "$C_DIM" "$C_OFF" "$fp" "$ff" "$fs"
done <<FILES
$files
FILES

# ------------------------------------------------------------------ summary --
pass=$(count_all pass)
fail=$(count_all fail)
skip=$(count_all skip)
filtered=$(count_all filter)
total=$((pass + fail + skip))

if [ "$skip" != 0 ]; then
  printf '%sskipped:%s\n' "$C_YELLOW" "$C_OFF"
  cat "$AB_RUN_DIR"/tally.* 2>/dev/null | awk -F'\t' '$1 == "skip" { printf "  %s / %s: %s\n", $2, $3, $4 }'
fi
if [ "$fail" != 0 ]; then
  printf '%sfailed:%s\n' "$C_RED" "$C_OFF"
  cat "$AB_RUN_DIR"/tally.* 2>/dev/null | awk -F'\t' '$1 == "fail" { printf "  %s / %s: %s\n", $2, $3, $4 }'
fi
if [ -n "$crashed_files" ]; then
  printf '%scrashed:%s\n%s' "$C_RED" "$C_OFF" "$crashed_files"
fi

printf '%s%s files, %s passed, %s failed, %s skipped' \
  "$C_BOLD" "$n" "$pass" "$fail" "$skip"
[ "$crashed" != 0 ] && printf ', %s crashed' "$crashed"
[ "$filtered" != 0 ] && printf ' (%s filtered out)' "$filtered"
printf '%s\n' "$C_OFF"

if [ "$total" = 0 ]; then
  printf '%sFAIL%s no assertions ran\n' "$C_RED" "$C_OFF"
  exit 1
fi
if [ "$fail" != 0 ] || [ "$crashed" != 0 ]; then
  printf '%sFAIL%s\n' "$C_RED" "$C_OFF"
  exit 1
fi
printf '%sPASS%s\n' "$C_GREEN" "$C_OFF"
exit 0
