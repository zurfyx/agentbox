#!/usr/bin/env bash
# tests/harness.test.sh — tests for the test harness itself.
#
# The trick used throughout: to prove that a FAILING assertion is really
# detected, we write a throwaway test file into $SCRATCH and run the real
# ./tests/run.sh against it in a child process, then assert on that child's
# output and exit status. A nested red run leaves this run green.

. "$(dirname "$0")/lib.sh"

# Run the real runner over files in $SCRATCH, with a clean harness env.
# Sets $STDOUT / $STDERR / $STATUS (see capture).
nested() {
  capture env AB_FILTER= AB_QUIET=0 AB_COLOR=0 NO_COLOR=1 \
    bash "$AB_TESTS_DIR/run.sh" "$@"
}

# --------------------------------------------------------------------------
case_assertions_pass() {
  assert_eq "abc" "abc" "assert_eq on equal strings"
  assert_ne "abc" "abd" "assert_ne on different strings"
  assert_contains "the quick brown fox" "quick" "assert_contains finds a substring"
  assert_not_contains "the quick brown fox" "slow" "assert_not_contains"
  assert_matches "v1.24.3" "^v[0-9]+\.[0-9]+\.[0-9]+$" "assert_matches on an ERE"
  assert_empty "" "assert_empty on an empty string"
  assert_not_empty "x" "assert_not_empty"
  assert_status 0 true
  assert_status 3 sh -c 'exit 3'
  assert_status -m "assert_status takes an explicit message with -m" 2 sh -c 'exit 2'
  printf 'hello\nworld\n' > file.txt
  assert_file_exists file.txt
  assert_file_contains file.txt "world" "assert_file_contains"
  # Multi-line and empty values must survive the comparison intact.
  assert_eq "$(printf 'a\nb')" "$(printf 'a\nb')" "multi-line equality"
}
test_case "assertions pass on good input" case_assertions_pass

# --------------------------------------------------------------------------
case_capture() {
  capture sh -c 'echo out; echo err >&2; exit 4'
  assert_eq "out" "$STDOUT" "capture sets STDOUT"
  assert_eq "err" "$STDERR" "capture sets STDERR"
  assert_eq "4" "$STATUS" "capture sets STATUS"
  capture_input "hello stdin" cat
  assert_eq "hello stdin" "$STDOUT" "capture_input feeds stdin"
}
test_case "capture and capture_input" case_capture

# --------------------------------------------------------------------------
case_fail_is_detected() {
  cat > inner.test.sh <<'INNER'
. "$AB_TESTS_DIR/lib.sh"
c() {
  assert_eq "wanted value" "got value" "deliberate failure"
  assert_eq 1 1 "this one passes"
}
test_case "a failing case" c
INNER
  nested inner.test.sh
  assert_eq "1" "$STATUS" "runner exits 1 when an assertion fails"
  assert_contains "$STDOUT" "FAIL" "failure line is printed"
  assert_contains "$STDOUT" "deliberate failure" "failure message is printed"
  assert_contains "$STDOUT" "expected: 'wanted value'" "expected value is shown"
  assert_contains "$STDOUT" "actual: 'got value'" "actual value is shown"
  assert_contains "$STDOUT" "a failing case" "the test name is shown"
  assert_contains "$STDOUT" "1 passed, 1 failed" "summary counts both"
}
test_case "a failing assertion is detected and reported" case_fail_is_detected

# --------------------------------------------------------------------------
case_skip_counted() {
  cat > inner.test.sh <<'INNER'
. "$AB_TESTS_DIR/lib.sh"
c() {
  skip_unless ab_missing_tool_9000 "needed for the zsh launcher"
  fail "must not be reached after a skip"
}
d() { assert_eq 1 1 "a real assertion"; }
test_case "needs a missing tool" c
test_case "ordinary case" d
INNER
  nested inner.test.sh
  assert_eq "0" "$STATUS" "a skip is not a failure"
  assert_contains "$STDOUT" "skip" "skip line is printed"
  assert_contains "$STDOUT" "ab_missing_tool_9000" "skip names the missing tool"
  assert_contains "$STDOUT" "needed for the zsh launcher" "skip prints the reason"
  assert_contains "$STDOUT" "1 passed, 0 failed, 1 skipped" "skips are counted in the summary"
  assert_contains "$STDOUT" "skipped:" "skips are listed, not silent"
  assert_not_contains "$STDOUT" "must not be reached" "skip_unless aborts the case"
}
test_case "skip is counted and printed, never silent" case_skip_counted

# --------------------------------------------------------------------------
case_fail_aborts() {
  cat > inner.test.sh <<'INNER'
. "$AB_TESTS_DIR/lib.sh"
c() {
  fail "boom"
  assert_eq 1 1 "unreachable assertion"
}
test_case "explicit fail" c
INNER
  nested inner.test.sh
  assert_eq "1" "$STATUS" "fail makes the run red"
  assert_contains "$STDOUT" "boom" "fail message is printed"
  assert_not_contains "$STDOUT" "unreachable assertion" "fail aborts the rest of the case"
}
test_case "fail aborts the case and fails the run" case_fail_aborts

# --------------------------------------------------------------------------
# xfail: a known-broken script must leave the suite GREEN and the bug VISIBLE.
case_xfail_records_a_skip() {
  cat > inner.test.sh <<'INNER'
. "$AB_TESTS_DIR/lib.sh"
c() {
  assert_eq 1 1 "an ordinary assertion before the marker"
  xfail "onhost eats a trailing newline"
  assert_eq "wanted" "got" "the known-broken behaviour"
  assert_eq "also wanted" "also got" "assertions after an xfail still run"
  xfail_off
  assert_contains "abc" "b" "xfail_off restores ordinary reporting"
}
test_case "a known bug" c
INNER
  nested inner.test.sh
  assert_eq "0" "$STATUS" "an xfailed assertion does not make the run red"
  assert_contains "$STDOUT" "KNOWN BUG: onhost eats a trailing newline" \
    "the reason is printed on the skip line"
  assert_contains "$STDOUT" "the known-broken behaviour" \
    "and so is the assertion it came from"
  assert_contains "$STDOUT" "skipped:" "the bug is listed in the run summary"
  assert_contains "$STDOUT" "2 passed, 0 failed, 2 skipped" \
    "assertions inside the region are skips; those outside it are unaffected"
}
test_case "xfail turns a failing assertion into a listed skip" case_xfail_records_a_skip

case_xfail_xpass_is_red() {
  cat > inner.test.sh <<'INNER'
. "$AB_TESTS_DIR/lib.sh"
c() {
  xfail "a bug that has since been fixed"
  assert_eq 1 1 "the behaviour the marker claims is broken"
}
test_case "a stale xfail" c
INNER
  nested inner.test.sh
  assert_eq "1" "$STATUS" "an xfail that starts passing makes the run red"
  assert_contains "$STDOUT" "XPASS" "the report says the marker is stale"
  assert_contains "$STDOUT" "delete the xfail" "and says what to do about it"
}
test_case "an xfail that starts passing is a failure, not a silent pass" case_xfail_xpass_is_red

# --------------------------------------------------------------------------
case_capture_bounded() {
  capture_bounded 5 sh -c 'echo out; echo err >&2; exit 4'
  assert_eq "out" "$STDOUT" "capture_bounded sets STDOUT"
  assert_eq "err" "$STDERR" "capture_bounded sets STDERR"
  assert_eq "4" "$STATUS" "capture_bounded propagates the exit status"
  assert_eq "0" "$CAPTURE_TIMEDOUT" "a command that finishes did not time out"

  # The reason this exists: a hung command has to fail the case, not the run.
  capture_bounded 1 sh -c 'while :; do sleep 1; done'
  assert_eq "1" "$CAPTURE_TIMEDOUT" "a command that outlives the deadline is killed"
  assert_eq "124" "$STATUS" "and reports status 124, the way timeout(1) would"
}
test_case "capture_bounded kills a command that hangs" case_capture_bounded

# --------------------------------------------------------------------------
case_crash_isolated() {
  cat > a_crash.test.sh <<'INNER'
. "$AB_TESTS_DIR/lib.sh"
c() { assert_eq 1 1 "before the crash"; }
test_case "fine" c
exit 3
INNER
  cat > b_ok.test.sh <<'INNER'
. "$AB_TESTS_DIR/lib.sh"
c() { assert_eq 1 1 "still ran"; }
test_case "later file" c
INNER
  nested a_crash.test.sh b_ok.test.sh
  assert_eq "1" "$STATUS" "a crashing file makes the run red"
  assert_contains "$STDOUT" "crashed" "the crash is reported"
  assert_contains "$STDOUT" "still ran" "a later file still runs after a crash"
}
test_case "a crashing file does not kill the run" case_crash_isolated

# --------------------------------------------------------------------------
case_empty_run() {
  cat > inner.test.sh <<'INNER'
. "$AB_TESTS_DIR/lib.sh"
INNER
  nested inner.test.sh
  assert_eq "1" "$STATUS" "a run with no assertions is a failure"
  assert_contains "$STDOUT" "no assertions ran" "and says so"
}
test_case "a run that asserts nothing is red" case_empty_run

# --------------------------------------------------------------------------
case_filter() {
  cat > inner.test.sh <<'INNER'
. "$AB_TESTS_DIR/lib.sh"
c() { assert_eq 1 1 "alpha ran"; }
d() { assert_eq 1 1 "beta ran"; }
test_case "alpha case" c
test_case "beta case" d
INNER
  capture env AB_FILTER= AB_QUIET=0 AB_COLOR=0 NO_COLOR=1 \
    bash "$AB_TESTS_DIR/run.sh" -k 'alpha' inner.test.sh
  assert_eq "0" "$STATUS" "filtered run is green"
  assert_contains "$STDOUT" "alpha ran" "matching case runs"
  assert_not_contains "$STDOUT" "beta ran" "non-matching case does not run"
  assert_contains "$STDOUT" "1 filtered out" "filtered cases are reported"
}
test_case "-k filters by test name" case_filter

# --------------------------------------------------------------------------
case_missing_function() {
  cat > inner.test.sh <<'INNER'
. "$AB_TESTS_DIR/lib.sh"
test_case "declared before it exists" case_defined_later
case_defined_later() { assert_eq 1 1 "never"; }
INNER
  nested inner.test.sh
  assert_eq "1" "$STATUS" "a test_case naming an undefined function fails"
  assert_contains "$STDOUT" "define it ABOVE" "and explains the ordering rule"
}
test_case "test_case with an undefined function is a failure" case_missing_function

# --------------------------------------------------------------------------
case_stub_records() {
  stub_bin docker
  docker run --rm -it -v /Users:/Users agentbox claude
  assert_eq "1" "$(stub_calls docker)" "stub_calls counts the call"
  assert_eq "run" "$(stub_argv docker | sed -n 1p)" "first arg recorded"
  assert_eq "--rm" "$(stub_argv docker | sed -n 2p)" "second arg recorded"
  assert_eq "7" "$(stub_argv docker | wc -l | tr -d ' ')" "every arg recorded, one per line"
  assert_contains "$(stub_argv_line docker)" "-v /Users:/Users" "stub_argv_line joins argv"
  assert_eq "$(pwd -P)" "$(cd "$(stub_pwd docker)" && pwd -P)" "stub records its cwd"
  docker version
  assert_eq "2" "$(stub_calls docker)" "second call counted"
  assert_eq "version" "$(stub_argv docker)" "stub_argv defaults to the last call"
  assert_eq "run" "$(stub_argv docker 1 | sed -n 1p)" "an earlier call is still readable"
  stub_reset docker
  assert_eq "0" "$(stub_calls docker)" "stub_reset forgets the calls"
}
test_case "stub_bin records argv, cwd and call count" case_stub_records

# --------------------------------------------------------------------------
case_stub_body() {
  stub_bin ssh 'echo "connected to $2" ; echo "warned" >&2 ; exit 7'
  assert_status 7 ssh -i key host.example
  assert_contains "$STDOUT" "connected to key" "stub body sees the original argv"
  assert_contains "$STDERR" "warned" "stub body writes stderr"
  assert_eq "host.example" "$(stub_argv ssh | sed -n 3p)" "argv recorded even when the body exits non-zero"

  stub_bin jq 'cat > "$STUB_DIR/jq.stdin"; echo consumed'
  printf 'stdin payload\n' | jq -r .model > /dev/null
  assert_file_contains "$STUB_DIR/jq.stdin" "stdin payload" "a stub can capture stdin"

  # A stub with no args at all still records an (empty) call.
  stub_bin bare
  bare
  assert_eq "1" "$(stub_calls bare)" "no-arg call counted"
  assert_empty "$(stub_argv bare)" "no-arg call records an empty argv"
}
test_case "stub_bin bodies run, propagate status and can read stdin" case_stub_body

# --------------------------------------------------------------------------
# Case isolation: this pair must run in this order. The first leaves traces,
# the second proves none of them survived.
case_isolation_writer() {
  printf 'marker\n' > leaked.txt
  printf '%s\n' "$SCRATCH" > "$AB_RUN_DIR/prev_scratch"
  stub_bin ab_fake_tool_xyz
  export AB_LEAKED_VAR=1
  cd "$HOME" || fail "cannot cd to the per-case HOME"
  assert_file_exists "$SCRATCH/leaked.txt" "the writer really wrote a file"
  assert_contains "$HOME" "$SCRATCH" "HOME is inside the scratch dir"
  assert_contains "$TMPDIR" "$SCRATCH" "TMPDIR is inside the scratch dir"
}
test_case "case A leaves files, env, PATH and cwd behind" case_isolation_writer

case_isolation_reader() {
  local prev
  prev=$(cat "$AB_RUN_DIR/prev_scratch")
  assert_ne "$prev" "$SCRATCH" "each case gets its own scratch dir"
  assert_eq "$SCRATCH" "$(pwd)" "each case starts in its own scratch dir"
  [ -e "$prev" ] && fail "the previous case's scratch dir was not cleaned up"
  assert_eq "" "${AB_LEAKED_VAR:-}" "exported vars do not leak between cases"
  assert_status -m "stubs do not leak between cases" 1 command -v ab_fake_tool_xyz
  assert_status -m "files do not leak between cases" 1 test -e leaked.txt
}
test_case "case B sees a clean, isolated scratch dir" case_isolation_reader

# --------------------------------------------------------------------------
case_paths() {
  assert_file_exists "$REPO_ROOT/statusline.sh" "REPO_ROOT points at the repo"
  assert_file_exists "$AB_TESTS_DIR/lib.sh" "AB_TESTS_DIR points at tests/"
  assert_ne "$HOME" "$AB_REAL_HOME" "AB_REAL_HOME still holds the real home"
}
test_case "REPO_ROOT, AB_TESTS_DIR and AB_REAL_HOME are exported" case_paths

# --------------------------------------------------------------------------
case_strict_mode() {
  cat > inner.test.sh <<'INNER'
set -euo pipefail
. "$AB_TESTS_DIR/lib.sh"
a() { skip "deliberate skip"; }
b() { fail "deliberate failure"; }
c() { assert_eq 1 1 "later cases still run"; }
test_case "skips" a
test_case "fails" b
test_case "runs last" c
INNER
  nested inner.test.sh
  assert_eq "1" "$STATUS" "the failing case is still reported"
  assert_contains "$STDOUT" "deliberate skip" "a skip under set -e does not abort the file"
  assert_contains "$STDOUT" "later cases still run" "cases after a fail/skip still run under set -e"
  assert_contains "$STDOUT" "1 passed, 1 failed, 1 skipped" "all three outcomes counted"
  assert_not_contains "$STDOUT" "crashed" "and the file is not treated as crashed"
}
test_case "set -euo pipefail in a test file is safe" case_strict_mode

# --------------------------------------------------------------------------
case_standalone() {
  cat > inner.test.sh <<'INNER'
. "$AB_TESTS_DIR/lib.sh"
c() { assert_eq 1 1 "direct run works"; }
test_case "direct" c
INNER
  capture env AB_TALLY= AB_RUN_DIR= AB_QUIET=0 AB_COLOR=0 NO_COLOR=1 bash inner.test.sh
  assert_eq "0" "$STATUS" "a test file can be run directly, without run.sh"
  assert_contains "$STDOUT" "direct run works" "and prints its assertions"
  assert_contains "$STDOUT" "1 passed, 0 failed, 0 skipped" "and its own mini summary"
}
test_case "a test file also runs standalone" case_standalone
