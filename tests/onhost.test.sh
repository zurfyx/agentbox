#!/usr/bin/env bash
# tests/onhost.test.sh — the `onhost` ssh wrapper.
#
# The interesting part of onhost is the argv re-quoting loop: for argv-style
# calls it single-quotes every argument, joins them into ONE string and hands
# that to ssh, which then feeds it to the *remote* shell. A naive assertion on
# the recorded argv would happily pass an escaping bug, so the ssh stub here
# actually evaluates the joined string with `sh -c` and prints the resulting
# positional parameters — that is the real end-to-end contract.
#
# The Makefile sanity block at the bottom is cheap and lives here rather than
# in a file of its own.

. "$(dirname "$0")/lib.sh"

ONHOST=$REPO_ROOT/onhost

# ---------------------------------------------------------------- fixtures --

# The key file onhost insists on, inside the per-case $HOME.
make_key() {
  mkdir -p "$HOME/.ssh"
  : > "$HOME/.ssh/id_agentbox_host"
}

# A working environment: key present, launcher-injected user present.
#
# AGENTBOX_HOST is scrubbed, not merely left alone: the agentbox launcher
# EXPORTS it into the container this repo builds, so without this every case
# that asserts a destination would fail for anyone running the suite inside
# agentbox itself. lib.sh sandboxes HOME/TMPDIR/PATH but knows nothing about
# the variables the script under test reads.
good_env() {
  make_key
  unset AGENTBOX_HOST
  AGENTBOX_HOST_USER=alice
  export AGENTBOX_HOST_USER
}

# ssh stub that records argv and nothing else.
stub_ssh_recorder() {
  stub_bin ssh
}

# ssh stub that ALSO evaluates the command string the way the remote shell
# would, printing one <word> per positional parameter. This is what catches a
# quoting bug: an unquoted `*` globs against the cwd, a mis-escaped `'` either
# splits a word or makes `sh -c` fail outright.
SSH_EVAL_BODY=$(cat <<'BODY'
for __a in "$@"; do __cmd=$__a; done
sh -c "set -- $__cmd; printf '<%s>\n' \"\$@\""
BODY
)

stub_ssh_eval() {
  stub_bin ssh "$SSH_EVAL_BODY"
}

# The fixed ssh argv onhost must always produce, given $HOME and alice@host.
expected_opts() {
  printf '%s\n' \
    "-i" \
    "$HOME/.ssh/id_agentbox_host" \
    "-o" \
    "IdentitiesOnly=yes" \
    "-o" \
    "StrictHostKeyChecking=accept-new" \
    "-o" \
    "UserKnownHostsFile=$HOME/.ssh/known_hosts" \
    "alice@host.docker.internal"
}

# ------------------------------------------------------------ preconditions --

case_missing_key() {
  stub_ssh_recorder
  unset AGENTBOX_HOST
  AGENTBOX_HOST_USER=alice; export AGENTBOX_HOST_USER
  # deliberately no ~/.ssh/id_agentbox_host
  assert_status -m "missing key exits 1" 1 "$ONHOST" echo hi
  assert_contains "$STDERR" "$HOME/.ssh/id_agentbox_host" \
    "the error names the key path it looked for"
  assert_contains "$STDERR" "setup-host-bridge.sh" "the error says how to fix it"
  assert_empty "$STDOUT" "nothing is printed on stdout"
  assert_eq "0" "$(stub_calls ssh)" "ssh is never invoked without a key"
}

case_missing_host_user() {
  stub_ssh_recorder
  unset AGENTBOX_HOST
  make_key
  unset AGENTBOX_HOST_USER
  assert_status -m "unset AGENTBOX_HOST_USER exits 1" 1 "$ONHOST" echo hi
  assert_contains "$STDERR" "AGENTBOX_HOST_USER" \
    "the error is about AGENTBOX_HOST_USER, not the key"
  assert_not_contains "$STDERR" "missing key" "it is a distinct error message"
  assert_eq "0" "$(stub_calls ssh)" "ssh is never invoked without a host user"
}

case_empty_host_user() {
  stub_ssh_recorder
  unset AGENTBOX_HOST
  make_key
  AGENTBOX_HOST_USER=""; export AGENTBOX_HOST_USER
  assert_status -m "empty AGENTBOX_HOST_USER exits 1" 1 "$ONHOST" echo hi
  assert_contains "$STDERR" "AGENTBOX_HOST_USER" "empty is treated like unset"
  assert_eq "0" "$(stub_calls ssh)" "ssh is not invoked with an empty user"
}

case_no_command() {
  stub_ssh_recorder
  good_env
  assert_status -m "no command exits exactly 2" 2 "$ONHOST"
  assert_contains "$STDERR" "no command given" "it says what is missing"
  assert_eq "0" "$(stub_calls ssh)" "ssh is not invoked with no command"
}

case_no_command_after_t() {
  stub_ssh_recorder
  good_env
  assert_status -m "-t with nothing after it also exits 2" 2 "$ONHOST" -t
  assert_eq "0" "$(stub_calls ssh)" "ssh is not invoked for a bare -t"
}

test_case "missing key file errors out and never runs ssh" case_missing_key
test_case "unset AGENTBOX_HOST_USER is its own error" case_missing_host_user
test_case "empty AGENTBOX_HOST_USER is its own error" case_empty_host_user
test_case "no command exits 2" case_no_command
test_case "-t with no command exits 2" case_no_command_after_t

# ------------------------------------------------------------- the ssh argv --

# The whole argv in one assertion: the exact options, the exact destination,
# and — because TTY_FLAG is intentionally unquoted in the source — proof that
# an empty TTY_FLAG leaves NO stray empty first argument.
case_argv_shape() {
  stub_ssh_recorder
  good_env
  capture "$ONHOST" 'echo hi'
  # Not a status-propagation test — the recorder stub always exits 0. That
  # contract is case_status_propagates'. This only says onhost itself survived.
  assert_eq "0" "$STATUS" "onhost reaches its exec without dying"
  assert_eq "$(expected_opts)
echo hi" "$(stub_argv ssh)" "full ssh argv: options, destination, command"
  assert_eq "-i" "$(stub_argv ssh | head -1)" \
    "an empty TTY_FLAG contributes no argument at all"
  assert_eq "10" "$(stub_argv ssh | wc -l | tr -d ' ')" "exactly 10 ssh arguments"
}

case_host_default_and_override() {
  stub_ssh_recorder
  good_env
  unset AGENTBOX_HOST
  capture "$ONHOST" 'true'
  assert_contains "$(stub_argv ssh)" "alice@host.docker.internal" \
    "AGENTBOX_HOST defaults to host.docker.internal"

  # Empty is not the same as unset anywhere else in this file, and it must not
  # be here either: `-e AGENTBOX_HOST` with nothing behind it is the realistic
  # launcher failure, and `${AGENTBOX_HOST-default}` would silently ssh to
  # "alice@". The source writes `:-`, so empty falls back to the default.
  stub_reset ssh
  AGENTBOX_HOST=""; export AGENTBOX_HOST
  capture "$ONHOST" 'true'
  assert_eq "alice@host.docker.internal" "$(stub_argv ssh | sed -n 9p)" \
    "an empty AGENTBOX_HOST falls back to the default, not to a bare user@"

  stub_reset ssh
  AGENTBOX_HOST=hs1.example.ts.net; export AGENTBOX_HOST
  AGENTBOX_HOST_USER=gerard; export AGENTBOX_HOST_USER
  capture "$ONHOST" 'true'
  assert_eq "gerard@hs1.example.ts.net" "$(stub_argv ssh | sed -n 9p)" \
    "destination is exactly \$AGENTBOX_HOST_USER@\$AGENTBOX_HOST"
}

# $HOME is interpolated into two ssh options unquoted-looking but quoted in the
# source. Nothing else in this file ever produces a path with a space in it, so
# the "exactly 10 arguments" claim was never actually tested against splitting.
case_home_with_a_space() {
  stub_ssh_recorder
  HOME="$SCRATCH/ho me"; export HOME
  mkdir -p "$HOME"
  good_env
  capture "$ONHOST" 'true'
  assert_eq "10" "$(stub_argv ssh | wc -l | tr -d ' ')" \
    "a \$HOME with a space still produces exactly 10 ssh arguments"
  assert_eq "$HOME/.ssh/id_agentbox_host" "$(stub_argv ssh | sed -n 2p)" \
    "the key path is one argument, not two"
  assert_eq "UserKnownHostsFile=$HOME/.ssh/known_hosts" "$(stub_argv ssh | sed -n 8p)" \
    "and so is the known_hosts option"
}

test_case "ssh argv: options, destination, no stray empty arg" case_argv_shape
test_case "AGENTBOX_HOST default, empty and override" case_host_default_and_override
test_case "a \$HOME containing a space does not split the ssh argv" case_home_with_a_space

# ------------------------------------------------------- the single-arg form --

# `onhost '<shell string>'` must hand the string to ssh untouched, as ONE
# argument — re-quoting it would break `onhost 'a && b'`.
case_single_arg_passthrough() {
  stub_ssh_recorder
  good_env
  capture "$ONHOST" 'cd /tmp && echo "$USER" | tr a-z A-Z'
  assert_eq "10" "$(stub_argv ssh | wc -l | tr -d ' ')" "still one command argument"
  assert_eq 'cd /tmp && echo "$USER" | tr a-z A-Z' "$(stub_argv ssh | sed -n 10p)" \
    "the shell string reaches ssh byte-for-byte, unquoted and unsplit"
}

test_case "single-arg form passes the string through unchanged" case_single_arg_passthrough

# ------------------------------------------------------------ the argv form --

# The core test. Four arguments that each break a different naive escaper:
# a plain word, a word with a space, a word with an embedded single quote,
# and a bare glob character. The stub evaluates the joined string the way the
# remote shell will, so we assert on the words the remote command actually sees.
case_argv_requoting() {
  stub_ssh_eval
  good_env
  : > zzz_glob_bait          # if `*` escapes unquoted, it expands to this
  capture "$ONHOST" echo 'a b' "c'd" '*'
  assert_eq "0" "$STATUS" "the remote shell parses the command string cleanly"
  assert_eq "<echo>
<a b>
<c'd>
<*>" "$STDOUT" "each argument survives as one distinct remote word"
  assert_not_contains "$STDOUT" "zzz_glob_bait" \
    "the glob character is quoted, so the remote shell does not expand it"
  assert_eq "10" "$(stub_argv ssh | wc -l | tr -d ' ')" \
    "the four arguments are joined into a single ssh argument"
}

# The re-quoting threshold is `[ "$#" -gt 1 ]`, and TWO arguments is both the
# commonest real call (`onhost ls '/Users/My Stuff'`) and the exact value the
# comparison turns on. Pin it from both sides: 2 must be re-quoted, and 1 must
# not be (case_single_arg_passthrough covers the other side).
case_argv_two_args() {
  stub_ssh_eval
  good_env
  : > zzz_glob_bait
  capture "$ONHOST" ls 'a b*'
  assert_eq "<ls>
<a b*>" "$STDOUT" "two arguments are re-quoted, not handed to ssh as two words"
  assert_not_contains "$STDOUT" "zzz_glob_bait" "the glob is still inert"
  assert_eq "10" "$(stub_argv ssh | wc -l | tr -d ' ')" \
    "and they are joined into a single ssh argument"
}

case_argv_three_args() {
  stub_ssh_eval
  good_env
  capture "$ONHOST" ls -la 'a b'
  assert_eq "<ls>
<-la>
<a b>" "$STDOUT" "three arguments are re-quoted the same way"
  assert_eq "10" "$(stub_argv ssh | wc -l | tr -d ' ')" "still one ssh argument"
}

case_argv_empty_string() {
  stub_ssh_eval
  good_env
  capture "$ONHOST" echo '' end
  assert_eq "<echo>
<>
<end>" "$STDOUT" "an empty-string argument survives as an empty remote word"
}

case_argv_embedded_newline() {
  stub_ssh_eval
  good_env
  capture "$ONHOST" echo 'x
y' end
  assert_eq "<echo>
<x
y>
<end>" "$STDOUT" "a newline inside an argument survives re-quoting"
}

# KNOWN SOURCE BUG, marked xfail so the suite stays green and the bug stays
# listed in the run summary. `esc=$(printf '%s' "$a" | sed ...)` runs the
# argument through command substitution, which strips trailing newlines, so
# `onhost printf %s "$v"` silently drops them off the wire. The one-line fix is
# `printf '%s.'` plus `esc=${esc%.}`; deleting the xfail is then the test that
# the fix worked.
case_argv_trailing_newline() {
  stub_ssh_eval
  good_env
  capture "$ONHOST" echo 'trail
' end
  xfail "onhost:42 re-quotes each argument through \$( ), which strips trailing newlines"
  assert_eq "<echo>
<trail
>
<end>" "$STDOUT" "a TRAILING newline must survive re-quoting too"
  xfail_off
}

case_argv_dollar_and_backslash() {
  stub_ssh_eval
  good_env
  FOO=leaked; export FOO
  capture "$ONHOST" echo '$FOO' 'back\slash' '$(id -u)'
  assert_eq "<echo>
<\$FOO>
<back\\slash>
<\$(id -u)>" "$STDOUT" \
    "\$ and \\ are inert on the remote side — no expansion, no injection"
}

test_case "argv form: spaces, quotes and globs survive re-quoting" case_argv_requoting
test_case "argv form: exactly two arguments are re-quoted" case_argv_two_args
test_case "argv form: exactly three arguments are re-quoted" case_argv_three_args
test_case "argv form: empty-string argument survives" case_argv_empty_string
test_case "argv form: embedded newline survives" case_argv_embedded_newline
test_case "argv form: trailing newline survives (KNOWN SOURCE BUG)" case_argv_trailing_newline
test_case "argv form: no remote expansion of \$ or backslash" case_argv_dollar_and_backslash

# ------------------------------------------------------------------- -t flag --

case_t_single_arg() {
  stub_ssh_recorder
  good_env
  capture "$ONHOST" -t 'echo hi'
  assert_eq "-tt
$(expected_opts)
echo hi" "$(stub_argv ssh)" "-t becomes a leading -tt and -t itself is consumed"
  assert_eq "11" "$(stub_argv ssh | wc -l | tr -d ' ')" "exactly one extra argument"
}

case_t_argv_form() {
  stub_ssh_eval
  good_env
  capture "$ONHOST" -t echo 'a b' "c'd"
  assert_eq "-tt" "$(stub_argv ssh | head -1)" "-tt still comes first in argv form"
  assert_eq "<echo>
<a b>
<c'd>" "$STDOUT" "-t does not disturb the re-quoting of the remaining argv"
}

case_t_only_leading() {
  stub_ssh_eval
  good_env
  capture "$ONHOST" echo -t hi
  # Positive, not `assert_ne "-tt"`: stub_argv prints nothing when ssh was never
  # called, so a not-equal assertion here would be satisfied by onhost failing
  # to run ssh at all — the one outcome it most needs to rule out.
  assert_eq "-i" "$(stub_argv ssh | head -1)" \
    "a -t that is not the first argument is a command argument, not a flag"
  assert_eq "<echo>
<-t>
<hi>" "$STDOUT" "it is forwarded to the remote command verbatim"
}

# The flag test is `[ "${1:-}" = "-t" ]`, an exact match. Broaden it to a `-t*`
# pattern and `onhost -tail -f /var/log/x` silently becomes a tty request with
# the `-tail` swallowed — the same "broaden the case pattern" mistake that
# git-credential-ghtoken.test.sh exists to guard against on the other script.
case_t_near_miss_is_not_a_flag() {
  stub_ssh_eval
  good_env
  capture "$ONHOST" -tail -f /var/log/x
  assert_eq "-i" "$(stub_argv ssh | head -1)" "-tail does not turn into a tty request"
  assert_eq "<-tail>
<-f>
</var/log/x>" "$STDOUT" "-tail is the remote command's first word, not a flag"
  assert_eq "10" "$(stub_argv ssh | wc -l | tr -d ' ')" "no extra -tt argument"
}

test_case "-t adds -tt (single-arg form)" case_t_single_arg
test_case "-t adds -tt (argv form)" case_t_argv_form
test_case "-t is only a flag in first position" case_t_only_leading
test_case "-t is matched exactly: -tail is a command, not a flag" case_t_near_miss_is_not_a_flag

# ---------------------------------------------------------------- exit status --

case_status_propagates() {
  stub_bin ssh 'exit 42'
  good_env
  assert_status -m "onhost returns ssh's exit status" 42 "$ONHOST" 'false'
}

test_case "ssh's exit status is propagated" case_status_propagates

# ================================================================== Makefile ==
# Cheap sanity only: the recipes parse, the dry runs succeed, `help` is a
# complete index of the .PHONY targets, and the shared DOCKER_ARGS line still
# mounts what it is supposed to and nothing more.
#
# The Makefile is COPIED into $SCRATCH and run there, rather than `cd`-ing into
# the checkout. lib.sh promises that nothing a case does reaches the real
# filesystem, and these were the only cases breaking it: today `-n` makes that
# harmless, but a future assertion that forgets `-n` would run docker and mkdir
# against the developer's own working tree.

# make_setup — a throwaway copy of the Makefile, and a docker that screams if a
# dry run ever actually invokes it.
make_setup() {
  skip_unless make "the Makefile sanity checks need make"
  cp "$REPO_ROOT/Makefile" "$SCRATCH/Makefile" || fail "cannot copy the Makefile"
  stub_bin docker 'echo "docker must not run in a dry run" >&2; exit 1'
}

case_make_dry_runs() {
  make_setup
  assert_status -m "make -n build succeeds" 0 make -n build
  assert_contains "$STDOUT" "docker build" "build shells out to docker build"
  assert_contains "$STDOUT" "--build-arg CLAUDE_VERSION=" "build pins the Claude version"
  assert_contains "$STDOUT" "--build-arg CODEX_VERSION=" "build pins the Codex version"

  assert_status -m "make -n run succeeds" 0 make -n run
  assert_contains "$STDOUT" "docker run" "run shells out to docker run"

  # The two recipes whose whole point is a dangerous flag. `make help` only
  # proves the targets are NAMED; nothing else looks at what they do.
  assert_status -m "make -n run-dangerous succeeds" 0 make -n run-dangerous
  assert_contains "$STDOUT" "claude --dangerously-skip-permissions" \
    "run-dangerous is the target that skips permissions"

  assert_status -m "make -n run-codex succeeds" 0 make -n run-codex
  assert_contains "$STDOUT" "codex --dangerously-bypass-approvals-and-sandbox" \
    "run-codex bypasses approvals and the sandbox"
  assert_contains "$STDOUT" "-p 127.0.0.1:1455:1455" \
    "and publishes the OAuth callback port loopback-only, as the launcher does"
  assert_contains "$STDOUT" "-e OPENAI_API_KEY" "OPENAI_API_KEY is passed by name"

  assert_status -m "make -n shell succeeds" 0 make -n shell
  assert_contains "$STDOUT" "--entrypoint bash" "shell overrides the entrypoint"

  assert_status -m "make -n clean succeeds" 0 make -n clean
  assert_contains "$STDOUT" "docker rmi" "clean removes the image"

  assert_status -m "make help succeeds" 0 make help
  assert_eq "0" "$(stub_calls docker)" "no dry run actually invoked docker"
}

# DOCKER_ARGS decides which parts of the host filesystem the agent can write to
# and which secrets cross the boundary. It is shared by run / run-dangerous /
# run-codex / shell, so one assertion set covers all four.
case_make_docker_args() {
  make_setup
  assert_status -m "make -n run succeeds" 0 make -n run
  local argv
  argv=$STDOUT
  assert_contains "$argv" '-v "'"$HOME"'/.agentbox":/home/node' \
    "the personal config dir is the container HOME"
  assert_contains "$argv" "-v /Users:/Users" "/Users is mounted path-transparent"
  assert_contains "$argv" "-v /Volumes:/Volumes" "/Volumes is mounted path-transparent"
  assert_contains "$argv" "-v /tmp:/tmp" "/tmp is mounted path-transparent"
  assert_contains "$argv" "-w \"$SCRATCH\"" "the working dir is the caller's cwd"
  assert_contains "$argv" "-e GH_TOKEN " "GH_TOKEN is forwarded by name"
  assert_not_contains "$argv" "-e GH_TOKEN=" "never by value — argv is visible in ps"
  assert_contains "$argv" "-e AGENTBOX_HOST=host.docker.internal" \
    "the host bridge target is injected"
  assert_contains "$argv" '-e AGENTBOX_HOST_USER="$USER"' \
    "and the host user, expanded by the shell rather than by make"
  assert_contains "$argv" "--rm" "the container is removed on exit"
  # The mount set is the security boundary: broadening it must fail loudly.
  assert_not_contains "$argv" " -v /:" "the host root is never mounted"
  assert_not_contains "$argv" " -v /Users:/Users:ro" "/Users is not mounted read-only"
}

case_make_help_is_complete() {
  make_setup
  local esc phony cleaned t desc missing count want
  phony=$(sed -n 's/^\.PHONY:[[:space:]]*//p' "$SCRATCH/Makefile" | head -1)
  assert_not_empty "$phony" "the Makefile declares a .PHONY line"

  capture make help
  assert_eq "0" "$STATUS" "make help exits 0"
  esc=$(printf '\033')
  cleaned=$(sed "s/$esc\[[0-9;]*m//g" "$CAPTURE_OUT")

  missing=""
  for t in $phony; do
    desc=$(printf '%s\n' "$cleaned" |
      awk -v t="$t" '$1 == t { $1 = ""; sub(/^[[:space:]]+/, ""); print; exit }')
    [ -n "$desc" ] || missing="$missing $t"
  done
  assert_empty "$missing" "every .PHONY target has a described line in make help"

  # Count only lines that LOOK like a help row. Counting every non-blank line
  # would break on any banner make decides to print (MAKEFLAGS=w, a submake
  # "Entering directory", a warning) and blame the Makefile for it.
  want=$(printf '%s\n' $phony | wc -l | tr -d ' ')
  count=$(printf '%s\n' "$cleaned" | grep -c '^  [a-zA-Z_-][a-zA-Z_-]*  *.' )
  assert_eq "$want" "$count" "make help lists exactly the .PHONY targets, no more"
}

test_case "make dry runs: build/run/run-dangerous/run-codex/shell/clean" case_make_dry_runs
test_case "make: the shared docker mounts and env are what they claim" case_make_docker_args
test_case "make help documents every .PHONY target" case_make_help_is_complete
