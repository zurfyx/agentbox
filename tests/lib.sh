# tests/lib.sh — assertions, test declaration and stubbing for the agentbox
# test suite. Source it at the top of every tests/*.test.sh file:
#
#     . "$(dirname "$0")/lib.sh"
#
# Design constraints (do not break these):
#   * bash 3.2 (macOS /bin/bash) AND bash 5.x must both run this verbatim:
#     no associative arrays, no mapfile, no ${x,,}, no local -n, no declare -A.
#   * Zero dependencies beyond bash + coreutils. jq may be used *inside* a test
#     that exercises statusline.sh (the script already requires it) — never here.
#
# House rules for a new test file (the mechanics are in the API CONTRACT at
# the bottom of this file; these are the conventions it does not encode):
#   * Assert on BEHAVIOUR, not on implementation. Prefer one exact-equality
#     assertion on a whole rendered line or a whole argv over a pile of
#     substring checks — it is the shape that catches a field shifting left.
#   * Every case is hermetic. Never read or write outside $SCRATCH, never
#     reach the network, a docker daemon, a real ssh host, or real auth. Stub
#     the boundary with stub_bin and assert on the argv the script produced.
#   * An optional tool is a skip_unless, never an `if command -v ... ; then`.
#     A skip is counted and listed; a silent branch is a test that quietly
#     stopped testing. CI additionally fails the build if a case skips for a
#     tool that demonstrably exists on that runner.
#   * A real defect in a repo script gets an xfail with the file:line and the
#     fix in the reason, not a weakened assertion. Fixing the source is a
#     separate change from the test that pins it.
#   * Name the case for the behaviour it proves ("a trailing newline survives
#     re-quoting"), not for the function it calls. The name is what a failure
#     prints, so it should read as the broken promise.
#
# See run.sh --help and the API contract at the bottom of this file.

# Idempotent load.
if [ -n "${AB_LIB_LOADED:-}" ]; then
  return 0 2>/dev/null || exit 0
fi
AB_LIB_LOADED=1

# ---------------------------------------------------------------- locations --
AB_LIB_FILE=${BASH_SOURCE[0]}
AB_TESTS_DIR=$(cd "$(dirname "$AB_LIB_FILE")" && pwd)
REPO_ROOT=$(cd "$AB_TESTS_DIR/.." && pwd)
export AB_TESTS_DIR REPO_ROOT

AB_FILE_PATH=$0
AB_FILE_LABEL=$(basename "$0")
AB_FILE_LABEL=${AB_FILE_LABEL%.test.sh}
AB_FILE_LABEL=${AB_FILE_LABEL%.sh}
AB_CASE_NAME=""

# A literal newline, without $'...'.
AB_NL='
'

# Magic exit codes used to talk to run.sh / test_case. A test case (or a whole
# file) that ends with one of these did so deliberately; anything else nonzero
# is a crash.
AB_EXIT_SKIP=96
AB_EXIT_FAIL=97

# ------------------------------------------------------------- run bootstrap --
# Normally run.sh exports AB_RUN_DIR/AB_TALLY. When a file is executed directly
# (bash tests/foo.test.sh) we bootstrap a one-file run and print our own summary.
AB_STANDALONE=0
if [ -z "${AB_TALLY:-}" ]; then
  AB_STANDALONE=1
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
  AB_TALLY=$AB_RUN_DIR/tally.1
  : > "$AB_TALLY"
  export AB_RUN_DIR AB_TALLY
fi

if [ -z "${AB_COLOR:-}" ]; then
  if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then AB_COLOR=1; else AB_COLOR=0; fi
fi
if [ "$AB_COLOR" = 1 ]; then
  AB_ESC=$(printf '\033')
  AB_C_RED=$AB_ESC'[31m'; AB_C_GREEN=$AB_ESC'[32m'; AB_C_YELLOW=$AB_ESC'[33m'
  AB_C_DIM=$AB_ESC'[2m'; AB_C_OFF=$AB_ESC'[0m'
else
  AB_C_RED=''; AB_C_GREEN=''; AB_C_YELLOW=''; AB_C_DIM=''; AB_C_OFF=''
fi

# --------------------------------------------------------------- bookkeeping --
# Every event is one tab-separated line in $AB_TALLY:
#     <pass|fail|skip|filter>\t<file label>\t<case name>\t<message>
# run.sh aggregates those with awk; nothing here needs jq or bash 4.
__ab_event() {
  local kind msg where
  kind=$1
  msg=${2:-}
  msg=${msg//$AB_NL/ }
  where=$AB_CASE_NAME
  [ -n "$where" ] || where='<file>'
  printf '%s\t%s\t%s\t%s\n' "$kind" "$AB_FILE_LABEL" "$where" "$msg" >> "$AB_TALLY"
}

__ab_tally_lines() {
  wc -l < "$AB_TALLY" 2>/dev/null | tr -d ' '
}

__ab_where() {
  if [ -n "$AB_CASE_NAME" ]; then
    printf '%s / %s' "$AB_FILE_LABEL" "$AB_CASE_NAME"
  else
    printf '%s / <file>' "$AB_FILE_LABEL"
  fi
}

# Collapse to one line and clip, for default assertion messages.
__ab_brief() {
  local v
  v=${1//$AB_NL/ }
  if [ ${#v} -gt 60 ]; then v=${v:0:57}...; fi
  printf '%s' "$v"
}

__ab_print() {
  local kind tag col
  kind=$1
  case $kind in
    pass) tag='ok  '; col=$AB_C_GREEN ;;
    fail) tag='FAIL'; col=$AB_C_RED ;;
    skip) tag='skip'; col=$AB_C_YELLOW ;;
    *)    tag='????'; col='' ;;
  esac
  printf '%s%s%s %s%s%s: %s\n' \
    "$col" "$tag" "$AB_C_OFF" "$AB_C_DIM" "$(__ab_where)" "$AB_C_OFF" "$2"
}

# Show a value under a failure, quoted on one line or as an indented block.
__ab_dump() {
  case "$2" in
    *"$AB_NL"*)
      printf '        %8s:\n' "$1"
      printf '%s\n' "$2" | sed 's/^/          | /'
      ;;
    *)
      printf "        %8s: '%s'\n" "$1" "$2"
      ;;
  esac
}

__ab_ok() {
  if [ -n "${AB_XFAIL:-}" ]; then
    # The known bug is gone: that is good news, and it must not be silent.
    __ab_event fail "XPASS: '$1' now holds — delete the xfail ($AB_XFAIL)"
    __ab_print fail "XPASS: '$1' now holds — delete the xfail ($AB_XFAIL)"
    return 0
  fi
  __ab_event pass "$1"
  [ "${AB_QUIET:-0}" = 1 ] || __ab_print pass "$1"
  return 0
}

__ab_bad() {
  if [ -n "${AB_XFAIL:-}" ]; then
    __ab_event skip "KNOWN BUG: $AB_XFAIL — $1"
    __ab_print skip "KNOWN BUG: $AB_XFAIL — $1"
    return 0
  fi
  __ab_event fail "$1"
  __ab_print fail "$1"
  return 0
}

# ------------------------------------------------------------------ asserts --
# Every assertion RETURNS 0, always — a failure is recorded, never propagated.
# That keeps `set -e` in a test file from turning one failed assertion into a
# whole-file crash, and keeps a file's exit status clean.

assert_eq() {
  local msg
  msg=${3:-"== '$(__ab_brief "$1")'"}
  if [ "x$1" = "x$2" ]; then
    __ab_ok "$msg"
  else
    __ab_bad "$msg"
    __ab_dump expected "$1"
    __ab_dump actual "$2"
  fi
  return 0
}

assert_ne() {
  local msg
  msg=${3:-"!= '$(__ab_brief "$1")'"}
  if [ "x$1" != "x$2" ]; then
    __ab_ok "$msg"
  else
    __ab_bad "$msg"
    __ab_dump "not wanted" "$1"
    __ab_dump actual "$2"
  fi
  return 0
}

assert_contains() {
  local msg
  msg=${3:-"contains '$(__ab_brief "$2")'"}
  case "$1" in
    *"$2"*) __ab_ok "$msg" ;;
    *)
      __ab_bad "$msg"
      __ab_dump needle "$2"
      __ab_dump haystack "$1"
      ;;
  esac
  return 0
}

assert_not_contains() {
  local msg
  msg=${3:-"does not contain '$(__ab_brief "$2")'"}
  case "$1" in
    *"$2"*)
      __ab_bad "$msg"
      __ab_dump needle "$2"
      __ab_dump haystack "$1"
      ;;
    *) __ab_ok "$msg" ;;
  esac
  return 0
}

# assert_matches STRING ERE [MSG] — POSIX ERE via bash [[ =~ ]]. The pattern is
# used unquoted on purpose: bash 3.2 treats a *quoted* right-hand side as a
# literal string, so quoting it here would silently change the semantics.
assert_matches() {
  local msg ok
  msg=${3:-"matches /$(__ab_brief "$2")/"}
  ok=0
  if [[ $1 =~ $2 ]] 2>/dev/null; then ok=1; fi
  if [ "$ok" = 1 ]; then
    __ab_ok "$msg"
  else
    __ab_bad "$msg"
    __ab_dump regex "$2"
    __ab_dump actual "$1"
  fi
  return 0
}

# assert_status [-m MSG] EXPECTED_CODE CMD [ARGS...] — runs CMD and compares
# its exit status. stdout/stderr are captured, not printed, and are afterwards
# readable as $STDOUT / $STDERR (same as capture).
#
# NOTE: everything after EXPECTED_CODE is the command, so there is NO trailing
# message argument here — a trailing string would be passed to the command.
# Use the leading -m flag when the auto-generated message is not clear enough.
assert_status() {
  local want msg
  msg=""
  if [ "$1" = "-m" ]; then msg=$2; shift 2; fi
  want=$1; shift
  [ -n "$msg" ] || msg="\`$(__ab_brief "$*")\` exits $want"
  capture "$@"
  if [ "$STATUS" = "$want" ]; then
    __ab_ok "$msg"
  else
    __ab_bad "$msg"
    __ab_dump expected "$want"
    __ab_dump actual "$STATUS"
    [ -n "$STDERR" ] && __ab_dump stderr "$STDERR"
    [ -n "$STDOUT" ] && __ab_dump stdout "$STDOUT"
  fi
  return 0
}

assert_empty() {
  local msg
  msg=${2:-"is empty"}
  if [ -z "$1" ]; then
    __ab_ok "$msg"
  else
    __ab_bad "$msg"
    __ab_dump actual "$1"
  fi
  return 0
}

assert_not_empty() {
  local msg
  msg=${2:-"is not empty"}
  if [ -n "$1" ]; then
    __ab_ok "$msg"
  else
    __ab_bad "$msg"
    __ab_dump actual "$1"
  fi
  return 0
}

assert_file_contains() {
  local msg body
  msg=${3:-"$(basename "$1") contains '$(__ab_brief "$2")'"}
  if [ ! -f "$1" ]; then
    __ab_bad "$msg"
    __ab_dump missing "$1"
    return 0
  fi
  body=$(cat "$1")
  case "$body" in
    *"$2"*) __ab_ok "$msg" ;;
    *)
      __ab_bad "$msg"
      __ab_dump needle "$2"
      __ab_dump "file" "$1"
      __ab_dump contents "$body"
      ;;
  esac
  return 0
}

assert_file_exists() {
  local msg
  msg=${2:-"$(basename "$1") exists"}
  if [ -e "$1" ]; then
    __ab_ok "$msg"
  else
    __ab_bad "$msg"
    __ab_dump missing "$1"
  fi
  return 0
}

# fail MSG — record a failure and ABORT the current test case (or, at file
# top level, the file). Assertions never abort; only fail does.
fail() {
  __ab_event fail "${1:-explicit fail}"
  __ab_print fail "${1:-explicit fail}"
  exit $AB_EXIT_FAIL
}

# ------------------------------------------------------------------- skipping --
# skip_unless CMD REASON — if CMD is not on PATH, record a skip and abort the
# current test case (at file top level: skip the whole file). Never a failure.
skip_unless() {
  local cmd reason
  cmd=$1
  reason=${2:-}
  if command -v "$cmd" >/dev/null 2>&1; then
    return 0
  fi
  if [ -n "$reason" ]; then
    skip "needs $cmd — $reason"
  else
    skip "needs $cmd (not installed)"
  fi
}

# skip_unless_file PATH REASON — same, for a required fixture/file.
skip_unless_file() {
  if [ -e "$1" ]; then
    return 0
  fi
  skip "needs $1${2:+ — $2}"
}

# skip REASON — unconditional skip; aborts the current case (or file).
skip() {
  __ab_event skip "${1:-skipped}"
  __ab_print skip "${1:-skipped}"
  exit $AB_EXIT_SKIP
}

# --------------------------------------------------------------------- xfail --
# xfail REASON — from here to the end of the current case, the code under test
# is KNOWN BROKEN. While it is in force:
#   * a FAILING assertion is recorded as a skip carrying REASON, so the run
#     stays green and run.sh still lists the bug in its `skipped:` section;
#   * a PASSING assertion is recorded as a FAILURE, telling you the bug is
#     fixed and the marker has to go.
# Unlike skip/fail it does NOT abort: the assertions still run, which is the
# whole point — the case keeps documenting the exact broken behaviour.
#
# Scope the region TIGHTLY, with xfail_off, around the assertions that the bug
# actually breaks. Every assertion inside it must be one that fails today; a
# passing one is reported as an XPASS failure, which is exactly what you want
# when the bug is fixed and exactly what you do not want around unrelated
# scaffolding. That also handles a defect that only bites on one platform or
# one shell: wrap the arm that is broken, and leave the other arm ordinary.
#
# Use it ONLY for a defect in a repo script that this suite has deliberately
# chosen not to fix. Never to mute a flaky or wrong test: fix or delete those.
xfail() {
  AB_XFAIL=${1:-known bug}
}

# xfail_off — end an xfail region early (rarely needed; a case ends one too).
xfail_off() {
  AB_XFAIL=""
}

# --------------------------------------------------------------- capturing --
# capture CMD [ARGS...]           run CMD, set $STDOUT $STDERR $STATUS
# capture_input STR CMD [ARGS...] same, feeding STR (plus a newline) on stdin
#
# Use these instead of `out=$(cmd)` when you need the exit status and stderr,
# and NEVER pipe into them: `foo | capture bar` runs capture in a subshell and
# the variables it sets are lost.
#
# $STDOUT/$STDERR have trailing newlines stripped (command substitution rules).
# The raw bytes stay in the files named by $CAPTURE_OUT and $CAPTURE_ERR.
capture() {
  local dir
  dir=${SCRATCH:-$AB_RUN_DIR}
  CAPTURE_OUT=$dir/.capture.out
  CAPTURE_ERR=$dir/.capture.err
  "$@" > "$CAPTURE_OUT" 2> "$CAPTURE_ERR"
  STATUS=$?
  STDOUT=$(cat "$CAPTURE_OUT")
  STDERR=$(cat "$CAPTURE_ERR")
  return 0
}

# capture_bounded SECS CMD [ARGS...] — capture with a deadline. macOS ships no
# timeout(1), so a watchdog subshell kills the command if it outlives SECS. On
# expiry $STATUS is 124 and $CAPTURE_TIMEDOUT is 1; otherwise it behaves exactly
# like capture. Use it for anything that reads stdin or could loop forever — a
# hung helper must fail the case, not wedge the run.
capture_bounded() {
  local secs dir pid watcher flag
  secs=$1; shift
  dir=${SCRATCH:-$AB_RUN_DIR}
  CAPTURE_OUT=$dir/.capture.out
  CAPTURE_ERR=$dir/.capture.err
  flag=$dir/.capture.timedout
  rm -f "$flag"
  CAPTURE_TIMEDOUT=0
  "$@" > "$CAPTURE_OUT" 2> "$CAPTURE_ERR" &
  pid=$!
  # The watchdog's stdio is detached: a leftover `sleep` that still held the
  # captured stdout would keep a `tee` in CI waiting for a pipe that never
  # closes.
  ( sleep "$secs"
    if kill -0 "$pid" 2>/dev/null; then : > "$flag"; kill -9 "$pid" 2>/dev/null; fi
  ) </dev/null >/dev/null 2>&1 &
  watcher=$!
  wait "$pid"
  STATUS=$?
  kill "$watcher" 2>/dev/null
  wait "$watcher" 2>/dev/null
  if [ -f "$flag" ]; then CAPTURE_TIMEDOUT=1; STATUS=124; fi
  STDOUT=$(cat "$CAPTURE_OUT")
  STDERR=$(cat "$CAPTURE_ERR")
  return 0
}

capture_input() {
  local dir input
  input=$1; shift
  dir=${SCRATCH:-$AB_RUN_DIR}
  CAPTURE_IN=$dir/.capture.in
  printf '%s\n' "$input" > "$CAPTURE_IN"
  CAPTURE_OUT=$dir/.capture.out
  CAPTURE_ERR=$dir/.capture.err
  "$@" < "$CAPTURE_IN" > "$CAPTURE_OUT" 2> "$CAPTURE_ERR"
  STATUS=$?
  STDOUT=$(cat "$CAPTURE_OUT")
  STDERR=$(cat "$CAPTURE_ERR")
  return 0
}

# ------------------------------------------------------------------- stubs --
# stub_bin NAME [BODY] — put an executable NAME at the front of $PATH. Every
# call is recorded first (argv + cwd), then BODY runs with the original "$@"
# intact, so `stub_bin docker 'echo hi; exit 3'` both records and behaves.
# BODY is bash; omit it for a silent recorder that exits 0.
#
# Inside BODY these are set: $STUB_DIR, $STUB_NAME, $STUB_CALL (1-based call
# number). Write anything else you want to inspect into $STUB_DIR yourself,
# e.g. `stub_bin ssh 'cat > "$STUB_DIR/ssh.stdin"'`.
__ab_ensure_stub_dir() {
  if [ -z "${STUB_DIR:-}" ]; then
    STUB_DIR=${SCRATCH:-$AB_RUN_DIR}/.stubs
    export STUB_DIR
  fi
  mkdir -p "$STUB_DIR" || return 1
  case ":$PATH:" in
    *":$STUB_DIR:"*) ;;
    *) PATH=$STUB_DIR:$PATH; export PATH ;;
  esac
  return 0
}

stub_bin() {
  local name body path
  name=$1
  body=${2:-}
  __ab_ensure_stub_dir || return 1
  path=$STUB_DIR/$name
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' "# agentbox test stub for '$name'"
    printf 'STUB_DIR=%s\n' "'$STUB_DIR'"
    printf 'STUB_NAME=%s\n' "'$name'"
    printf '%s\n' 'STUB_CALL=0'
    printf '%s\n' '[ -f "$STUB_DIR/$STUB_NAME.calls" ] && STUB_CALL=$(cat "$STUB_DIR/$STUB_NAME.calls")'
    printf '%s\n' 'STUB_CALL=$(( STUB_CALL + 1 ))'
    printf '%s\n' 'printf "%s\n" "$STUB_CALL" > "$STUB_DIR/$STUB_NAME.calls"'
    printf '%s\n' ': > "$STUB_DIR/$STUB_NAME.$STUB_CALL.argv"'
    printf '%s\n' '[ "$#" -gt 0 ] && printf "%s\n" "$@" > "$STUB_DIR/$STUB_NAME.$STUB_CALL.argv"'
    printf '%s\n' 'pwd > "$STUB_DIR/$STUB_NAME.$STUB_CALL.pwd"'
    printf '%s\n' 'export STUB_DIR STUB_NAME STUB_CALL'
    printf '%s\n' '# ---- user body ----'
    if [ -n "$body" ]; then
      printf '%s\n' "$body"
    else
      printf '%s\n' 'exit 0'
    fi
  } > "$path" || return 1
  chmod +x "$path" || return 1
  return 0
}

# stub_calls NAME — how many times the stub ran (0 if never).
stub_calls() {
  local f
  f=${STUB_DIR:-/nonexistent}/$1.calls
  if [ -f "$f" ]; then cat "$f"; else printf '0\n'; fi
}

# stub_argv NAME [N] — argv of call N (default: the last call), one arg per
# line. Prints nothing and returns 1 if the stub was never called.
stub_argv() {
  local n f
  n=${2:-}
  if [ -z "$n" ]; then n=$(stub_calls "$1"); fi
  [ "$n" -ge 1 ] 2>/dev/null || return 1
  f=${STUB_DIR:-/nonexistent}/$1.$n.argv
  [ -f "$f" ] || return 1
  cat "$f"
}

# stub_argv_line NAME [N] — the same argv joined with single spaces, for a
# quick assert_contains. Ambiguous if an argument itself contains a space —
# use stub_argv when the exact split matters.
stub_argv_line() {
  stub_argv "$@" | awk '{ if (NR > 1) printf " "; printf "%s", $0 } END { if (NR > 0) printf "\n" }'
}

# stub_pwd NAME [N] — the working directory the stub was called from.
stub_pwd() {
  local n f
  n=${2:-}
  if [ -z "$n" ]; then n=$(stub_calls "$1"); fi
  [ "$n" -ge 1 ] 2>/dev/null || return 1
  f=${STUB_DIR:-/nonexistent}/$1.$n.pwd
  [ -f "$f" ] || return 1
  cat "$f"
}

# stub_reset NAME — forget recorded calls (the stub itself stays on PATH).
stub_reset() {
  rm -f "${STUB_DIR:-/nonexistent}/$1.calls" "${STUB_DIR:-/nonexistent}/$1".*.argv \
        "${STUB_DIR:-/nonexistent}/$1".*.pwd
  return 0
}

# ---------------------------------------------------------- test declaration --
# test_case NAME FUNC [ARGS...] — run FUNC (a shell function defined ABOVE this
# call) as one test case, in its own subshell, with:
#   $SCRATCH    a fresh mktemp -d, also the cwd, removed afterwards
#   $HOME       $SCRATCH/home        (the real one is $AB_REAL_HOME)
#   $TMPDIR     $SCRATCH/tmp
#   $STUB_DIR   $SCRATCH/.stubs, already at the front of $PATH
# Nothing the case does to cwd, env or PATH can leak into the next case.
__ab_case_env() {
  HOME=$SCRATCH/home
  TMPDIR=$SCRATCH/tmp
  STUB_DIR=$SCRATCH/.stubs
  mkdir -p "$HOME" "$TMPDIR" "$STUB_DIR" || exit 1
  PATH=$STUB_DIR:$PATH
  # Make git usable inside $SCRATCH without touching the real user config.
  # GIT_CONFIG_GLOBAL points at a scratch file rather than being unset, so that
  # (a) no real ~/.gitconfig is ever read and (b) `safe.directory = *` is in
  # force: on an overlay/container filesystem the scratch dir can report an
  # owner that is not the caller, and git then refuses the repo outright with
  # "detected dubious ownership". safe.directory is honoured from system and
  # global config only, so a per-repo setting cannot replace this.
  GIT_CONFIG_NOSYSTEM=1
  GIT_CONFIG_GLOBAL=$SCRATCH/.gitconfig-harness
  printf '[safe]\n\tdirectory = *\n' > "$GIT_CONFIG_GLOBAL" 2>/dev/null || exit 1
  GIT_AUTHOR_NAME=${GIT_AUTHOR_NAME:-agentbox tests}
  GIT_AUTHOR_EMAIL=${GIT_AUTHOR_EMAIL:-tests@agentbox.invalid}
  GIT_COMMITTER_NAME=$GIT_AUTHOR_NAME
  GIT_COMMITTER_EMAIL=$GIT_AUTHOR_EMAIL
  export HOME TMPDIR STUB_DIR PATH SCRATCH GIT_CONFIG_NOSYSTEM GIT_CONFIG_GLOBAL \
         GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
  cd "$SCRATCH" || exit 1
}

test_case() {
  local name before after status
  name=$1
  shift

  if [ -n "${AB_FILTER:-}" ]; then
    if ! printf '%s %s' "$AB_FILE_LABEL" "$name" | grep -qiE -- "$AB_FILTER"; then
      AB_CASE_NAME=$name
      __ab_event filter ""
      AB_CASE_NAME=""
      return 0
    fi
  fi

  AB_CASE_NAME=$name

  if [ $# -eq 0 ]; then
    __ab_bad "test_case '$name' was given no function to run"
    AB_CASE_NAME=""
    return 0
  fi
  if ! command -v "$1" >/dev/null 2>&1; then
    __ab_bad "no such function '$1' — define it ABOVE the test_case call"
    AB_CASE_NAME=""
    return 0
  fi

  SCRATCH=$(mktemp -d "$AB_RUN_DIR/case.XXXXXX")
  if [ -z "$SCRATCH" ] || [ ! -d "$SCRATCH" ]; then
    __ab_bad "could not create a scratch dir for '$name'"
    AB_CASE_NAME=""
    return 0
  fi
  export SCRATCH

  before=$(__ab_tally_lines)
  # `|| status=$?` — not a bare call. A case that ends in fail/skip exits
  # non-zero, and in a file that set -e that would otherwise abort the file
  # and silently drop every later case.
  status=0
  ( __ab_case_env; "$@" ) || status=$?
  after=$(__ab_tally_lines)

  case $status in
    0 | $AB_EXIT_SKIP | $AB_EXIT_FAIL) ;;
    *)
      __ab_bad "test case aborted with exit status $status"
      ;;
  esac
  if [ "$status" = 0 ] && [ "$before" = "$after" ]; then
    __ab_bad "test case ran but made no assertions"
  fi

  if [ "${AB_KEEP_SCRATCH:-0}" = 1 ]; then
    printf '     %skept scratch: %s%s\n' "$AB_C_DIM" "$SCRATCH" "$AB_C_OFF"
  else
    rm -rf "$SCRATCH"
  fi
  SCRATCH=""
  AB_CASE_NAME=""
  return 0
}

# --------------------------------------------------------- standalone runner --
AB_REAL_HOME=$HOME
export AB_REAL_HOME

__ab_standalone_exit() {
  local code counts p f s
  code=$?
  counts=$(awk -F'\t' '{ c[$1]++ } END { printf "%d %d %d", c["pass"], c["fail"], c["skip"] }' "$AB_TALLY")
  set -- $counts
  p=$1; f=$2; s=$3
  printf -- '---- %s: %s passed, %s failed, %s skipped\n' "$AB_FILE_LABEL" "$p" "$f" "$s"
  [ "${AB_KEEP_SCRATCH:-0}" = 1 ] || rm -rf "$AB_RUN_DIR"
  if [ "$f" != 0 ]; then exit 1; fi
  case $code in
    0 | $AB_EXIT_SKIP | $AB_EXIT_FAIL) exit 0 ;;
  esac
  exit "$code"
}

if [ "$AB_STANDALONE" = 1 ]; then
  trap __ab_standalone_exit EXIT
fi

# =============================================================================
# API CONTRACT — everything a tests/*.test.sh file may rely on.
# =============================================================================
#
# FILE SHAPE
#   #!/usr/bin/env bash
#   . "$(dirname "$0")/lib.sh"
#   my_case() { assert_eq "want" "$(thing)" "what this proves"; }
#   test_case "human readable name" my_case      # function defined ABOVE
#
#   Files need not be executable; run.sh invokes them as `bash <file>`.
#   Define every helper function before the test_case that names it.
#   Do not redefine any name documented here — the file is sourced into
#   your shell, so `capture`, `fail`, `skip` etc. are yours to call, not
#   to shadow.
#
# DECLARATION
#   test_case NAME FUNC [ARGS...]
#       Runs FUNC "$ARGS" in its own subshell. Nothing it does to cwd, env,
#       PATH or the filesystem reaches the next case. A case that makes no
#       assertion is reported as a failure; a case that dies on an unexpected
#       status is reported as an aborted failure, and the file keeps going.
#
# PER-CASE ENVIRONMENT (all exported, all thrown away afterwards)
#   $SCRATCH    fresh mktemp -d; it is also the cwd when the case starts
#   $HOME       $SCRATCH/home   (the real one stays in $AB_REAL_HOME)
#   $TMPDIR     $SCRATCH/tmp    (isolates statusline.sh's cache, among others)
#   $STUB_DIR   $SCRATCH/.stubs, already first on $PATH
#   $REPO_ROOT  the agentbox checkout;  $AB_TESTS_DIR  this directory
#   GIT_* author/committer identity and GIT_CONFIG_NOSYSTEM, so `git init`
#   and `git commit` work inside $SCRATCH without touching the real config.
#
# ASSERTIONS — record and CONTINUE; each returns 0, so `set -e` is safe.
#   assert_eq            EXPECTED ACTUAL [MSG]
#   assert_ne            NOT_WANTED ACTUAL [MSG]
#   assert_contains      HAYSTACK NEEDLE [MSG]       (literal substring)
#   assert_not_contains  HAYSTACK NEEDLE [MSG]
#   assert_matches       STRING ERE [MSG]            (bash [[ =~ ]])
#   assert_empty         VALUE [MSG]
#   assert_not_empty     VALUE [MSG]
#   assert_file_exists   PATH [MSG]
#   assert_file_contains PATH NEEDLE [MSG]
#   assert_status        [-m MSG] EXPECTED_CODE CMD [ARGS...]
#       Everything after EXPECTED_CODE is the command: there is NO trailing
#       message here. Use -m. Afterwards $STDOUT/$STDERR/$STATUS are set.
#
# CONTROL — these ABORT the current case (or, at file top level, the file).
#   fail MSG                    record a failure and stop the case
#   skip REASON                 record a skip and stop the case
#   skip_unless CMD REASON      skip unless CMD is on $PATH (zsh, docker, jq…)
#   skip_unless_file PATH [REASON]
#       Skips are counted and listed in the run summary, never silent.
#       Call these from the case body, not inside $(command substitution).
#
# EXPECTED FAILURE — does NOT abort; the assertions still run.
#   xfail REASON     for the rest of the case, a failing assertion is recorded
#                    as a skip carrying REASON and a PASSING one is recorded as
#                    a failure ("the known bug is fixed, delete the marker").
#                    Only for a real defect in a repo script that this suite has
#                    chosen not to fix. Never for a flaky or wrong test. Keep
#                    the region tight — everything in it must fail today.
#   xfail_off        end the region early.
#
# RUNNING THINGS
#   capture CMD [ARGS...]              -> $STDOUT $STDERR $STATUS
#   capture_input STDIN CMD [ARGS...]  -> same, with STDIN (plus \n) on stdin
#   capture_bounded SECS CMD [ARGS...] -> same, but killed after SECS; then
#                    $STATUS is 124 and $CAPTURE_TIMEDOUT is 1. There is no
#                    timeout(1) on macOS, so use this for anything that reads
#                    stdin or could loop forever.
#       Never pipe into them (`x | capture y` loses the variables). Raw output
#       stays in the files $CAPTURE_OUT / $CAPTURE_ERR; $STDOUT and $STDERR
#       have trailing newlines stripped, as command substitution would.
#       Note: git-credential-ghtoken and agentbox.sh are NOT executable in the
#       repo, so run them as `sh "$REPO_ROOT/git-credential-ghtoken"` etc.
#
# STUBS
#   stub_bin NAME [BODY]   executable NAME at the front of $PATH. It records
#                          the call first, then runs BODY (bash) with the
#                          original "$@"; BODY may exit with any status. In
#                          BODY: $STUB_DIR $STUB_NAME $STUB_CALL.
#   stub_calls NAME            -> call count (0 if never called)
#   stub_argv NAME [N]         -> argv of call N (default last), one per line
#   stub_argv_line NAME [N]    -> the same, joined with single spaces
#   stub_pwd NAME [N]          -> the cwd the stub was called from
#   stub_reset NAME            -> forget recorded calls, keep the stub
#
# RUNNER
#   ./tests/run.sh [-k PATTERN] [-q] [-l] [--keep] [--no-color] [TARGET...]
#   TARGET is a path, a file name or a fragment ("statusline").
#   Env: AB_FILTER, AB_QUIET=1, AB_KEEP_SCRATCH=1, NO_COLOR, AB_COLOR=0.
#   Exit 0 only if nothing failed, nothing crashed and something actually ran.
# =============================================================================
