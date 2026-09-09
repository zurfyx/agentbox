#!/usr/bin/env bash
# tests/git-credential-ghtoken.test.sh — the token-handing helper.
#
# This helper is registered system-wide, so git invokes it for EVERY https auth
# challenge and it must hand the live GH_TOKEN to github.com and to nobody else.
# The tests below are therefore weighted towards refusals: every non-serving
# path must print NOTHING, write nothing to stderr, exit 0, and — asserted
# explicitly every single time — never let the sentinel token appear anywhere
# in the captured output.
#
# The helper is `#!/bin/sh` and is NOT executable in the repo, so it is always
# run as `<shell> <path>`. Every security-relevant case runs under BOTH `sh`
# (dash on ubuntu-latest, bash-in-posix-mode on macos-latest) and `bash`, which
# is what the two-OS CI matrix is for.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

TOKEN='ghp_SENTINEL_DO_NOT_LEAK'
HELPER="$REPO_ROOT/git-credential-ghtoken"
SERVED="username=x-access-token
password=$TOKEN"
NL='
'
SHELLS='sh bash'

# ------------------------------------------------------------------ plumbing --
# run_helper SHELL OP STDIN  — feed STDIN verbatim (no newline added, so the
# tests control the exact bytes) to `SHELL HELPER [OP]`. Sets $STDOUT/$STDERR/
# $STATUS.
#
# Bounded on purpose. stdin being a regular file means a helper that reads to
# EOF cannot hang, but that is a property of the CURRENT read loop, not one the
# harness enforces: a loop restructured into `while :; do read ...` spins
# forever and, without this, wedges the run rather than failing it. There is no
# timeout(1) on macOS, hence capture_bounded.
run_helper() {
  local sh_ op input
  sh_=$1; op=$2; input=$3
  printf '%s' "$input" > "$SCRATCH/req.in"
  if [ -n "$op" ]; then
    capture_bounded 10 bash -c 'exec "$1" "$2" "$3" < "$4"' _ "$sh_" "$HELPER" "$op" "$SCRATCH/req.in"
  else
    capture_bounded 10 bash -c 'exec "$1" "$2" < "$3"' _ "$sh_" "$HELPER" "$SCRATCH/req.in"
  fi
  [ "$CAPTURE_TIMEDOUT" = 0 ] || fail "the helper did not terminate — it hung reading stdin"
}

# assert_refused LABEL — the four properties every refusal must have. Reads the
# CAPTURE_* files that run_helper's capture_bounded just wrote; call it directly
# after a run_helper and nothing else.
#
# The last assertion greps the RAW files with grep -lF rather than re-checking
# the shell variables. That is not redundant with the first two: $STDOUT and
# $STDERR have their trailing newlines stripped by command substitution, so
# output consisting only of newlines reads as empty there and not here. -F
# because $TOKEN is a variable and a future sentinel containing `.` or `[`
# would silently turn this sweep into a different question.
assert_refused() {
  local label hits
  label=$1
  assert_eq "" "$STDOUT" "$label: stdout is empty"
  assert_eq "" "$STDERR" "$label: stderr is empty"
  assert_eq "0" "$STATUS" "$label: exits 0"
  hits=$(grep -lF -- "$TOKEN" "$CAPTURE_OUT" "$CAPTURE_ERR" 2>/dev/null | tr '\n' ' ')
  assert_empty "$hits" "$label: the token is in neither raw output file"
}

# assert_served LABEL — exactly the two credential lines, nothing else.
assert_served() {
  local label lines
  label=$1
  lines=$(wc -l < "$CAPTURE_OUT" | tr -d ' ')
  assert_eq "$SERVED" "$STDOUT" "$label: serves username + password"
  assert_eq "2" "$lines" "$label: exactly two newline-terminated lines"
  assert_eq "" "$STDERR" "$label: stderr is empty"
  assert_eq "0" "$STATUS" "$label: exits 0"
}

# request PROTOCOL HOST — sets $REQ to a well-formed, blank-line terminated
# request. It is a variable and not a $(...) because command substitution
# strips exactly the trailing newlines that terminate the request.
request() { REQ="protocol=$1${NL}host=$2${NL}${NL}"; }

# ------------------------------------------------------------------- the file --
case_shebang() {
  assert_file_exists "$HELPER" "the helper exists at the repo root"
  assert_eq '#!/bin/sh' "$(head -1 "$HELPER")" \
    "it is a /bin/sh script — hence the dash + bash matrix below"
}
test_case "helper is a POSIX sh script" case_shebang

# ------------------------------------------------------------------- serving --
case_serves_github() {
  local s
  export GH_TOKEN=$TOKEN
  for s in $SHELLS; do
    request https github.com
    run_helper "$s" get "$REQ"
    assert_served "get https://github.com under $s"
  done
}
test_case "serves the token for https + github.com" case_serves_github

case_serves_subdomains() {
  local s h
  export GH_TOKEN=$TOKEN
  for s in $SHELLS; do
    for h in gist.github.com api.github.com codeload.github.com uploads.github.com; do
      request https "$h"
      run_helper "$s" get "$REQ"
      assert_served "get https://$h under $s"
    done
  done
}
test_case "serves the *.github.com arm" case_serves_subdomains

# served_is LABEL — like assert_served, but for a token other than $TOKEN.
served_is() { # expected_token label
  local lines
  lines=$(wc -l < "$CAPTURE_OUT" | tr -d ' ')
  assert_eq "username=x-access-token${NL}password=$1" "$STDOUT" "$2: byte-exact credential"
  assert_eq "2" "$lines" "$2: exactly two newline-terminated lines"
  assert_eq "" "$STDERR" "$2: stderr is empty"
  assert_eq "0" "$STATUS" "$2: exits 0"
}

case_token_verbatim() {
  # A realistic fine-grained PAT shape: the password line must be byte-exact,
  # no mangling, no truncation at the underscores.
  local s pat
  pat='github_pat_11ABCDEFG0aBcDeFgHiJk_LmNoPqRsTuVwXyZ0123456789'
  export GH_TOKEN=$pat
  for s in $SHELLS; do
    request https github.com
    run_helper "$s" get "$REQ"
    served_is "$pat" "a fine-grained PAT under $s"
  done
}
test_case "passes a real-shaped token through unchanged" case_token_verbatim

# The token is DATA, and every real token this suite ever fed the helper was
# [A-Za-z0-9_] — so `echo "password=$GH_TOKEN"` losing its quotes (word-split
# and re-joined on single spaces) was invisible. git would then authenticate
# with a mangled password and the user would see an opaque 403.
case_token_with_awkward_bytes() {
  local s tok
  for s in $SHELLS; do
    for tok in 'tok with  two spaces' \
               'ghp_*' \
               'a$b`c' \
               'tok"with quotes'\''and'; do
      export GH_TOKEN=$tok
      request https github.com
      run_helper "$s" get "$REQ"
      served_is "$tok" "token [$tok] under $s"
    done
    # A tab, which word-splitting would turn into a single space.
    GH_TOKEN="$(printf 'a\tb')"
    export GH_TOKEN
    request https github.com
    run_helper "$s" get "$REQ"
    served_is "$(printf 'a\tb')" "a tab inside the token under $s"
  done
}
test_case "an awkward token is served byte-exact, not word-split" case_token_with_awkward_bytes

# sh_echo_mangles_backslash — does THIS platform's /bin/sh interpret backslash
# escapes in `echo`? dash does (ubuntu), bash-in-posix-mode does not (macOS).
# That divergence is precisely what the sh+bash matrix is for, so the test below
# asserts the correct behaviour unconditionally and marks it xfail only on the
# platform where the shipped `echo` cannot deliver it.
sh_echo_mangles_backslash() {
  [ "$(sh -c 'echo "a\tb"')" != 'a\tb' ]
}

# KNOWN SOURCE BUG, xfail on dash-like platforms only. git-credential-ghtoken
# lines 28-29 use `echo`, not `printf`. Under dash, a backslash in GH_TOKEN is
# expanded: `a\nb` is served as TWO lines, which breaks the credential protocol
# outright rather than merely mangling the value. Unreachable for a GitHub-issued
# token ([A-Za-z0-9_] only) and reachable the moment GH_TOKEN comes from anywhere
# else. Fix: `printf 'password=%s\n' "$GH_TOKEN"` (and the same for username).
case_token_with_backslashes() {
  local s tok lines
  tok='a\nb\tc'
  export GH_TOKEN=$tok
  for s in $SHELLS; do
    request https github.com
    run_helper "$s" get "$REQ"
    # Outside the xfail region: the bug mangles the VALUE, it does not make the
    # helper noisy or non-zero, and those two properties must hold everywhere.
    assert_eq "" "$STDERR" "a backslash in the token is not an error ($s)"
    assert_eq "0" "$STATUS" "and does not change the exit status ($s)"
    # Inside it: the two assertions the bug actually breaks, and nothing else.
    if [ "$s" = sh ] && sh_echo_mangles_backslash; then
      xfail "git-credential-ghtoken:29 uses echo, so dash expands a backslash in GH_TOKEN"
    fi
    lines=$(wc -l < "$CAPTURE_OUT" | tr -d ' ')
    assert_eq "username=x-access-token${NL}password=$tok" "$STDOUT" \
      "a backslash in the token is served literally ($s)"
    assert_eq "2" "$lines" "and the credential is still exactly two lines ($s)"
    xfail_off
  done
}
test_case "a backslash in the token is not expanded (KNOWN SOURCE BUG under dash)" case_token_with_backslashes

# ------------------------------------------------------- host scoping (leaks) --
case_refuses_foreign_hosts() {
  local s h
  export GH_TOKEN=$TOKEN
  for s in $SHELLS; do
    # Each of these is a host an attacker (or a stray submodule / redirect)
    # could plausibly steer git at. None of them may see the token.
    for h in evil.com \
             github.com.evil.com \
             notgithub.com \
             evilgithub.com \
             github.comevil.com \
             raw.githubusercontent.com \
             github.com. \
             xgithub.com; do
      request https "$h"
      run_helper "$s" get "$REQ"
      assert_refused "host=$h under $s"
    done
  done
}
test_case "refuses every non-github.com host" case_refuses_foreign_hosts

# The other half of the parser, and the one nothing tested: the KEY matcher.
# `host)` broadened to `host*)` is a live token leak — git sends `hostname=` for
# some transports, and a request naming evil.com in `host=` would then be
# re-pointed at github.com by a later `hostname=github.com` and served. Same
# shape for `protocol`, where the consequence is only that a stray key can
# satisfy the protocol guard.
case_key_names_are_matched_exactly() {
  local s k
  export GH_TOKEN=$TOKEN
  for s in $SHELLS; do
    # The host is evil.com. No key that merely STARTS with "host" may change it.
    for k in hostname host_alias hosts hostx; do
      run_helper "$s" get "protocol=https${NL}host=evil.com${NL}$k=github.com$NL$NL"
      assert_refused "a $k= key must not be read as host= ($s)"
    done
    # And with no host= line at all, such a key must not supply one either.
    for k in hostname hosts; do
      run_helper "$s" get "protocol=https${NL}$k=github.com$NL$NL"
      assert_refused "a $k= key alone does not establish the host ($s)"
    done
    # The protocol guard is exact too: only a literal `protocol=` sets it.
    for k in protocolx protocol_version protocols; do
      run_helper "$s" get "$k=https${NL}host=github.com$NL$NL"
      assert_refused "a $k= key must not satisfy the protocol guard ($s)"
    done
  done
}
test_case "protocol= and host= are matched as exact keys, not prefixes" case_key_names_are_matched_exactly

case_refuses_missing_host() {
  local s
  export GH_TOKEN=$TOKEN
  for s in $SHELLS; do
    request https ''
    run_helper "$s" get "$REQ"
    assert_refused "empty host= under $s"
    run_helper "$s" get "protocol=https$NL$NL"
    assert_refused "no host line at all under $s"
  done
}
test_case "refuses a request with no usable host" case_refuses_missing_host

# --------------------------------------------------------- protocol scoping --
case_refuses_non_https() {
  local s p
  export GH_TOKEN=$TOKEN
  for s in $SHELLS; do
    for p in http ftp ssh HTTPS; do
      request "$p" github.com
      run_helper "$s" get "$REQ"
      assert_refused "protocol=$p + host=github.com under $s"
    done
    run_helper "$s" get "host=github.com$NL$NL"
    assert_refused "no protocol line at all under $s"
  done
}
test_case "refuses anything that is not protocol=https" case_refuses_non_https

# --------------------------------------------------------------- operations --
case_refuses_other_operations() {
  local s op
  export GH_TOKEN=$TOKEN
  for s in $SHELLS; do
    for op in store erase approve reject GET; do
      request https github.com
      run_helper "$s" "$op" "$REQ"
      assert_refused "operation '$op' under $s"
    done
  done
}
test_case "refuses store / erase / unknown operations" case_refuses_other_operations

case_refuses_no_operation() {
  local s
  export GH_TOKEN=$TOKEN
  for s in $SHELLS; do
    request https github.com
    run_helper "$s" "" "$REQ"
    assert_refused "no operation argument under $s"
  done
}
test_case "refuses when given no operation argument" case_refuses_no_operation

# ---------------------------------------------------------------- no token --
case_refuses_without_token() {
  local s
  for s in $SHELLS; do
    unset GH_TOKEN
    request https github.com
    run_helper "$s" get "$REQ"
    assert_refused "GH_TOKEN unset under $s"
    export GH_TOKEN=""
    request https github.com
    run_helper "$s" get "$REQ"
    assert_refused "GH_TOKEN empty under $s"
  done
}
test_case "refuses when GH_TOKEN is unset or empty" case_refuses_without_token

# ------------------------------------------------------------ stdin parsing --
case_blank_line_terminates() {
  local s
  export GH_TOKEN=$TOKEN
  for s in $SHELLS; do
    # Junk after the terminating blank line is not part of the request and
    # must not be able to *revoke* a legitimate github.com grant...
    request https github.com
    run_helper "$s" get "${REQ}host=evil.com${NL}protocol=http$NL"
    assert_served "trailing junk after the blank line is ignored ($s)"
    # ...nor to *retro-fit* a github.com grant onto a foreign request.
    request https evil.com
    run_helper "$s" get "${REQ}protocol=https${NL}host=github.com$NL$NL"
    assert_refused "a second request block cannot upgrade host=evil.com ($s)"
  done
}
test_case "the blank line really terminates the request" case_blank_line_terminates

case_key_order() {
  local s
  export GH_TOKEN=$TOKEN
  for s in $SHELLS; do
    run_helper "$s" get "host=github.com${NL}protocol=https$NL$NL"
    assert_served "host= before protocol= ($s)"
    run_helper "$s" get "protocol=https${NL}host=github.com$NL$NL"
    assert_served "protocol= before host= ($s)"
    # A later host= wins, as git's own last-key-wins parsing implies — and the
    # loser here is the safe direction: github first, evil second => refused.
    run_helper "$s" get "host=github.com${NL}protocol=https${NL}host=evil.com$NL$NL"
    assert_refused "a later host=evil.com overrides an earlier github.com ($s)"
  done
}
test_case "key order does not change the decision" case_key_order

case_values_with_equals() {
  local s req
  export GH_TOKEN=$TOKEN
  # git really does send keys whose values contain '=' (paths, wwwauth
  # challenges). Splitting on the FIRST '=' only must keep host/protocol intact.
  req="protocol=https${NL}host=github.com${NL}path=a=b${NL}wwwauth[]=Basic realm=\"GitHub\"${NL}username=x=y$NL$NL"
  for s in $SHELLS; do
    run_helper "$s" get "$req"
    assert_served "values containing '=' do not corrupt parsing ($s)"
  done
  # And the reverse: an '=' inside a foreign host value must not smuggle a
  # github.com match past the case statement.
  for s in $SHELLS; do
    run_helper "$s" get "protocol=https${NL}host=evil.com=github.com$NL$NL"
    assert_refused "host=evil.com=github.com ($s)"
  done
}
test_case "a value containing '=' is parsed, not split" case_values_with_equals

case_backslashes_in_values() {
  local s
  export GH_TOKEN=$TOKEN
  # `read -r` is load-bearing. Drop the -r and a trailing backslash splices the
  # next line onto the value, so this request would parse as the (matching!)
  # host "x.github.com" and hand the token to an attacker-chosen line pair.
  # With -r the host is the literal x-plus-backslash, and the request is refused.
  for s in $SHELLS; do
    run_helper "$s" get "protocol=https${NL}host=x\\${NL}.github.com$NL$NL"
    assert_refused "a trailing backslash cannot splice a host into *.github.com ($s)"
    run_helper "$s" get "protocol=https${NL}host=github.com\\$NL$NL"
    assert_refused "a literal backslash in the host is not stripped ($s)"
  done
}
test_case "backslashes in values are literal (read -r)" case_backslashes_in_values

case_malformed_stdin() {
  local s
  export GH_TOKEN=$TOKEN
  for s in $SHELLS; do
    # CRLF line endings: the values carry a stray \r, so nothing matches and
    # the helper fails CLOSED rather than serving on a fuzzy match.
    run_helper "$s" get "protocol=https$(printf '\r')${NL}host=github.com$(printf '\r')${NL}$(printf '\r')$NL"
    assert_refused "CRLF request ($s)"
    # No terminating blank line, and no final newline either. POSIX `read`
    # returns non-zero at EOF-without-delimiter, so today the last line is
    # dropped and the request is refused. That is the SAFE direction but it is
    # not necessarily the right one — `while read ... || [ -n "$key" ]` would be
    # a legitimate fix — so this asserts only what must hold either way: no
    # hang, no half-answer, and never a lone password line.
    run_helper "$s" get "protocol=https${NL}host=github.com"
    assert_eq "0" "$STATUS" "unterminated request exits 0 ($s)"
    assert_eq "" "$STDERR" "unterminated request says nothing on stderr ($s)"
    case "$STDOUT" in
      "" | "$SERVED")
        assert_eq 1 1 "unterminated request either refuses or serves in full ($s)" ;;
      *)
        assert_eq "$SERVED" "$STDOUT" "unterminated request must not half-answer ($s)" ;;
    esac
    # Completely empty stdin.
    run_helper "$s" get ""
    assert_refused "empty stdin ($s)"
    # A leading blank line ends the request before anything is read.
    run_helper "$s" get "${NL}protocol=https${NL}host=github.com$NL$NL"
    assert_refused "leading blank line ($s)"
    # Garbage that is not key=value at all.
    run_helper "$s" get "not a request at all${NL}%%%$NL$NL"
    assert_refused "non key=value garbage ($s)"
  done
}
test_case "malformed stdin fails closed and never hangs" case_malformed_stdin

# ---------------------------------------------------------- belt and braces --
# There WAS a 16th case here that re-ran the refusal matrix and grepped the raw
# capture files for the sentinel. Every one of its twelve invocations is already
# covered by case_refuses_foreign_hosts / case_refuses_other_operations /
# case_refuses_non_https with strictly stronger assertions, and the raw-file
# grep it contributed now lives inside assert_refused, where it runs on every
# refusal in the file instead of on twelve of them.
