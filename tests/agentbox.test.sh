#!/usr/bin/env bash
# tests/agentbox.test.sh — the `agentbox` zsh launcher.
#
# agentbox.sh is a zsh script (it uses `local -a`, `extra+=(…)` and the
# `${${(%):-%x}:A:h}` prompt-expansion trick to find its own directory), so the
# whole file is skipped where zsh is unavailable and runs on CI, where
# ubuntu-latest installs zsh and macos-latest ships it.
#
# Everything under test is "did it build the right `docker run` argv", so the
# shape of every case is the same: source agentbox.sh inside a `zsh -f` driver
# script, call one function, and inspect what the `docker` stub recorded.
#
# The load-bearing case is the token one: GH_TOKEN must reach the container by
# NAME (`-e GH_TOKEN`, with the value in docker's environment) and its value
# must never appear in the argv, which is visible to every user via `ps`.

. "$(dirname "$0")/lib.sh"

skip_unless zsh 'agentbox.sh is zsh-only'
skip_unless_file "$REPO_ROOT/agentbox.sh" 'the launcher under test'

# A value that could not plausibly come from anywhere else, so a grep of the
# recorded argv for it is conclusive.
AB_TOKEN_SENTINEL='ghs_SENTINEL_must_never_reach_argv_7f3a91'

# The default docker stub. It records argv (lib.sh does that first, always) and
# additionally dumps the two secrets from its OWN environment, which is how we
# prove pass-by-name actually passed something.
AB_DOCKER_BODY='
printf "%s" "${GH_TOKEN-@unset@}" > "$STUB_DIR/docker.env.GH_TOKEN"
printf "%s" "${OPENAI_API_KEY-@unset@}" > "$STUB_DIR/docker.env.OPENAI_API_KEY"
exit 0
'

# ---------------------------------------------------------------- fixtures --

# ab_setup — a hermetic environment plus a `zsh -f` driver that sources
# agentbox.sh and calls the function named by its first argument.
#
# AGENTBOX_REPO is set explicitly here so no argv assertion depends on the
# fragile ${${(%):-%x}:A:h} expansion; that expansion gets its own case below.
ab_setup() {
  export AGENTBOX_SRC="$REPO_ROOT/agentbox.sh"
  export AGENTBOX_REPO="$REPO_ROOT"
  export AGENTBOX_IMAGE="agentbox-test-img"
  export AGENTBOX_HOME="$SCRATCH/abhome"
  export AGENTBOX_AUTO_UPDATE=0
  export AGENTBOX_HOST=testhost
  export AGENTBOX_HOST_USER=testuser
  export GH_TOKEN="$AB_TOKEN_SENTINEL"
  unset OPENAI_API_KEY
  stub_bin docker "$AB_DOCKER_BODY"
  cat > "$SCRATCH/drive.zsh" <<'EOZSH'
source "$AGENTBOX_SRC" || exit 90
fn=$1; shift
"$fn" "$@"
EOZSH
}

# ab_run FUNC [ARGS...] — run one agentbox function; sets $STDOUT/$STDERR/$STATUS.
ab_run() {
  capture zsh -f "$SCRATCH/drive.zsh" "$@"
}

# ab_assert_tail MSG WORD... — the last N recorded docker arguments, exactly.
# Comparing the tail (rather than just "contains") is what pins the ordering:
# image name last, then the in-container command, then the agent's own flags,
# then the user's arguments.
ab_assert_tail() {
  local msg n
  msg=$1; shift
  n=$#
  assert_eq "$(printf '%s\n' "$@")" "$(stub_argv docker | tail -n "$n")" "$msg"
}

# ------------------------------------------------------- the docker run argv --

case_default_argv() {
  ab_setup
  ab_run agentbox
  assert_eq 0 "$STATUS" "agentbox with no arguments exits 0"
  assert_eq 1 "$(stub_calls docker)" "docker run invoked exactly once"
  assert_eq \
    "run --rm -it -v $AGENTBOX_HOME:/home/node -v /Users:/Users -v /Volumes:/Volumes -v /tmp:/tmp -w $PWD -e AGENTBOX_HOST=testhost -e AGENTBOX_HOST_USER=testuser -e GH_TOKEN $AGENTBOX_IMAGE claude" \
    "$(stub_argv_line docker)" \
    "the whole docker argv: mounts, workdir, env, image last, then the command"
}
test_case "no args: full docker run argv, defaulting to claude" case_default_argv

case_host_env_defaults() {
  ab_setup
  unset AGENTBOX_HOST
  unset AGENTBOX_HOST_USER
  export USER=someuser
  ab_run agentbox
  local argv
  argv=$(stub_argv_line docker)
  assert_contains "$argv" "-e AGENTBOX_HOST=host.docker.internal" \
    "AGENTBOX_HOST defaults to host.docker.internal"
  assert_contains "$argv" "-e AGENTBOX_HOST_USER=someuser" \
    "AGENTBOX_HOST_USER defaults to \$USER"
}
test_case "AGENTBOX_HOST / AGENTBOX_HOST_USER defaults" case_host_env_defaults

case_propagates_status() {
  ab_setup
  stub_bin docker 'exit 42'
  ab_run agentbox
  assert_eq 42 "$STATUS" "agentbox returns docker's exit status"
}
test_case "docker's exit status is the launcher's exit status" case_propagates_status

case_creates_agentbox_home() {
  ab_setup
  export AGENTBOX_HOME="$SCRATCH/nested/deeper/abhome"
  ab_run agentbox
  assert_file_exists "$AGENTBOX_HOME" "AGENTBOX_HOME is created when missing"
  assert_contains "$(stub_argv_line docker)" "-v $AGENTBOX_HOME:/home/node" \
    "the freshly created AGENTBOX_HOME is what gets mounted as /home/node"
}
test_case "AGENTBOX_HOME is created if missing" case_creates_agentbox_home

# ---------------------------------------------------------- module defaults --
# ab_setup exports AGENTBOX_HOME and AGENTBOX_IMAGE, so no other case in this
# file ever evaluates the `: "${X:=default}"` lines at the top of agentbox.sh.
# AGENTBOX_HOME's default is the line that keeps the personal agent's login out
# of the work ~/.claude — the entire isolation model the README sells — and it
# was dead code to this suite.
case_module_defaults() {
  ab_setup
  unset AGENTBOX_HOME AGENTBOX_IMAGE
  ab_run agentbox
  assert_eq 0 "$STATUS" "the launcher runs with neither variable set"
  assert_eq 1 "$(stub_calls docker)" "docker was invoked"
  assert_file_exists "$HOME/.agentbox" "AGENTBOX_HOME defaults to \$HOME/.agentbox"
  assert_contains "$(stub_argv docker)" "$(printf '%s\n' -v "$HOME/.agentbox:/home/node")" \
    "and that is what is mounted as the container HOME"
  assert_not_contains "$(stub_argv docker)" "$HOME/.claude" \
    "the work ~/.claude is never the mount source"
  ab_assert_tail "AGENTBOX_IMAGE defaults to the name the Makefile builds" \
    agentbox claude
}
test_case "AGENTBOX_HOME / AGENTBOX_IMAGE defaults are the documented ones" case_module_defaults

case_home_with_spaces() {
  ab_setup
  export AGENTBOX_HOME="$SCRATCH/dir with spaces/home"
  ab_run agentbox
  assert_eq 0 "$STATUS" "a \$AGENTBOX_HOME containing spaces still launches"
  assert_file_exists "$AGENTBOX_HOME" "the directory is created"
  # stub_argv, not stub_argv_line: the latter joins on spaces and could not tell
  # one argument containing a space from two arguments.
  assert_contains "$(stub_argv docker)" "$(printf '%s\n' -v "$AGENTBOX_HOME:/home/node")" \
    "-v and the mount spec are exactly two argv entries"
}
test_case "AGENTBOX_HOME with spaces is one docker argument" case_home_with_spaces

# -------------------------------------------------------------- subcommands --

case_default_mode_flag_is_an_arg() {
  ab_setup
  ab_run agentbox --resume
  assert_eq 1 "$(stub_calls docker)" "--resume did not abort before docker"
  ab_assert_tail "--resume is an argument to claude, not a subcommand" \
    "$AGENTBOX_IMAGE" claude --resume
}
test_case "default mode: --resume is passed through to claude" case_default_mode_flag_is_an_arg

case_default_mode_prompt_is_one_arg() {
  ab_setup
  ab_run agentbox "fix bug"
  ab_assert_tail "a prompt survives as a single argv entry" \
    "$AGENTBOX_IMAGE" claude "fix bug"
}
test_case "default mode: a quoted prompt stays one argument" case_default_mode_prompt_is_one_arg

case_claude_subcommand() {
  ab_setup
  ab_run agentbox claude -p
  ab_assert_tail "\`agentbox claude\` runs plain claude with the user's args" \
    "$AGENTBOX_IMAGE" claude -p
  assert_not_contains "$(stub_argv docker)" "--dangerously-skip-permissions" \
    "\`agentbox claude\` does NOT skip permissions"
}
test_case "agentbox claude ARGS -> claude ARGS" case_claude_subcommand

case_clauded_subcommand() {
  ab_setup
  ab_run agentbox clauded "fix bug"
  ab_assert_tail "agent flags come before the user's args" \
    "$AGENTBOX_IMAGE" claude --dangerously-skip-permissions "fix bug"
}
test_case "agentbox clauded ARGS -> claude --dangerously-skip-permissions ARGS" case_clauded_subcommand

case_codex_subcommand() {
  ab_setup
  ab_run agentbox codex "fix bug"
  ab_assert_tail "agent flags come before the user's args" \
    "$AGENTBOX_IMAGE" codex --dangerously-bypass-approvals-and-sandbox "fix bug"
  assert_contains "$(stub_argv docker)" "$(printf '%s\n' -p 127.0.0.1:1455:1455)" \
    "codex publishes the 1455 OAuth callback port, loopback-only"
}
test_case "agentbox codex ARGS -> codex --dangerously-bypass… ARGS, port published" case_codex_subcommand

case_no_port_for_claude() {
  ab_setup
  ab_run agentbox clauded
  # stub_argv prints NOTHING when the stub was never called, so a bare
  # assert_not_contains here would pass for a run in which docker never ran —
  # i.e. for a launcher that is completely broken. Pin the call count first.
  assert_eq 1 "$(stub_calls docker)" "docker really was invoked"
  assert_not_contains "$(stub_argv docker)" "1455" \
    "the codex OAuth port is not published for claude"
}
test_case "no 1455 port published for claude" case_no_port_for_claude

# The dispatcher matches three exact words. Broaden it to `claude* | codex*` and
# a typo is silently swallowed as a subcommand instead of reaching claude as an
# argument — and the default-mode contract can be widened without anyone
# noticing.
case_unknown_word_is_an_argument() {
  ab_setup
  ab_run agentbox claudex hi
  assert_eq 1 "$(stub_calls docker)" "an unknown first word does not abort the launch"
  ab_assert_tail "a near-miss subcommand is an ARGUMENT to claude, not a subcommand" \
    "$AGENTBOX_IMAGE" claude claudex hi
  assert_not_contains "$(stub_argv docker)" "--dangerously-skip-permissions" \
    "and it certainly does not select the permission-skipping mode"
}
test_case "an unknown first word is an argument, not a subcommand" case_unknown_word_is_an_argument

# --------------------------------------------------------------------- help --

case_help() {
  ab_setup
  local flag
  for flag in help -h --help; do
    stub_reset docker
    ab_run agentbox "$flag"
    assert_eq 0 "$STATUS" "agentbox $flag exits 0"
    assert_contains "$STDERR" "usage: agentbox [claude|clauded|codex] [args...]" \
      "agentbox $flag prints usage on stderr"
    assert_empty "$STDOUT" "agentbox $flag writes nothing to stdout"
    assert_eq 0 "$(stub_calls docker)" "agentbox $flag never invokes docker"
  done
}
test_case "help / -h / --help: usage on stderr, exit 0, no docker" case_help

# ----------------------------------------------------------------- secrets --

case_token_never_in_argv() {
  ab_setup
  ab_run agentbox
  local argv
  assert_eq 1 "$(stub_calls docker)" "docker really was invoked"
  argv=$(stub_argv docker)
  assert_not_contains "$argv" "$AB_TOKEN_SENTINEL" \
    "the GH_TOKEN value never appears in the ps-visible docker argv"
  assert_not_contains "$argv" "GH_TOKEN=" \
    "GH_TOKEN is passed by name, never as -e NAME=VALUE"
  assert_contains "$argv" "$(printf '%s\n' -e GH_TOKEN)" \
    "-e GH_TOKEN is in the argv"
  assert_eq "$AB_TOKEN_SENTINEL" "$(cat "$STUB_DIR/docker.env.GH_TOKEN")" \
    "the token reaches docker through the environment instead"
}
test_case "SECURITY: GH_TOKEN passed by name, value never in argv" case_token_never_in_argv

case_token_from_gh() {
  ab_setup
  export GH_TOKEN=""
  export AB_GH_TOKEN="$AB_TOKEN_SENTINEL"
  stub_bin gh 'printf "%s\n" "$AB_GH_TOKEN"'
  ab_run agentbox
  assert_not_contains "$(stub_argv docker)" "$AB_TOKEN_SENTINEL" \
    "a token fetched from \`gh auth token\` also stays out of the argv"
  assert_eq "$AB_TOKEN_SENTINEL" "$(cat "$STUB_DIR/docker.env.GH_TOKEN")" \
    "\`gh auth token\` supplies GH_TOKEN when the env var is empty"
  assert_not_contains "$STDERR" "no GH_TOKEN" "no warning when gh supplies a token"
}
test_case "SECURITY: token from gh auth token is not leaked either" case_token_from_gh

case_warns_without_token() {
  ab_setup
  export GH_TOKEN=""
  stub_bin gh 'exit 1'
  ab_run agentbox
  assert_contains "$STDERR" "no GH_TOKEN" "warns when no token can be found"
  assert_eq 1 "$(stub_calls docker)" "a missing token does not stop the launch"
}
test_case "missing GH_TOKEN warns but still launches" case_warns_without_token

case_openai_key_present() {
  ab_setup
  export OPENAI_API_KEY="sk-openai-sentinel-4242"
  ab_run agentbox codex
  local argv
  argv=$(stub_argv docker)
  assert_contains "$argv" "$(printf '%s\n' -e OPENAI_API_KEY)" \
    "-e OPENAI_API_KEY is forwarded when the var is set"
  assert_not_contains "$argv" "sk-openai-sentinel-4242" \
    "OPENAI_API_KEY is passed by name too, never by value"
  assert_eq "sk-openai-sentinel-4242" "$(cat "$STUB_DIR/docker.env.OPENAI_API_KEY")" \
    "OPENAI_API_KEY reaches docker through the environment"
}
test_case "OPENAI_API_KEY forwarded by name when set" case_openai_key_present

case_openai_key_absent() {
  ab_setup
  unset OPENAI_API_KEY
  ab_run agentbox codex
  assert_eq 1 "$(stub_calls docker)" "docker really was invoked (unset case)"
  assert_not_contains "$(stub_argv docker)" "OPENAI_API_KEY" \
    "unset OPENAI_API_KEY is not forwarded"
  stub_reset docker
  export OPENAI_API_KEY=""
  ab_run agentbox codex
  assert_eq 1 "$(stub_calls docker)" "docker really was invoked (empty case)"
  assert_not_contains "$(stub_argv docker)" "OPENAI_API_KEY" \
    "empty OPENAI_API_KEY is not forwarded either"
}
test_case "OPENAI_API_KEY not forwarded when unset or empty" case_openai_key_absent

# ------------------------------------------------------------- cwd warning --
# /var/tmp and /tmp are used deliberately: the per-case scratch dir lives under
# $TMPDIR, which is /tmp on Linux runners but /var/folders/… on macOS, so it
# would land on either side of the check depending on the runner.

case_warns_outside_mounts() {
  ab_setup
  [ -d /var/tmp ] || skip "/var/tmp is not available on this machine"
  cd /var/tmp || skip "cannot cd to /var/tmp"
  ab_run agentbox
  assert_contains "$STDERR" "not under /Users, /Volumes, or /tmp" \
    "warns that the cwd will not be visible in the container"
  assert_eq 1 "$(stub_calls docker)" "the warning does not stop the launch"
  assert_contains "$(stub_argv_line docker)" "-w /var/tmp" \
    "the unreachable cwd is still passed as the container workdir"
}
test_case "cwd outside the mounts: warns, still runs" case_warns_outside_mounts

case_no_warning_inside_tmp() {
  ab_setup
  cd /tmp || skip "cannot cd to /tmp"
  ab_run agentbox
  assert_not_contains "$STDERR" "not under /Users, /Volumes, or /tmp" \
    "no warning for a cwd under a mounted root"
  assert_contains "$(stub_argv_line docker)" "-w /tmp" "workdir is the cwd"
}
test_case "cwd inside /tmp: no warning" case_no_warning_inside_tmp

# ------------------------------------------------------------- auto-update --

case_update_disabled() {
  ab_setup
  stub_bin docker 'echo "docker must not run" >&2; exit 7'
  stub_bin npm 'echo "npm must not run" >&2; exit 7'
  local v
  for v in 0 off no; do
    stub_reset docker
    stub_reset npm
    export AGENTBOX_AUTO_UPDATE="$v"
    ab_run _agentbox_maybe_update
    assert_eq 0 "$STATUS" "AGENTBOX_AUTO_UPDATE=$v returns immediately"
    assert_eq 0 "$(stub_calls docker)" "AGENTBOX_AUTO_UPDATE=$v never touches docker"
    assert_eq 0 "$(stub_calls npm)" "AGENTBOX_AUTO_UPDATE=$v never touches npm"
  done
}
test_case "auto-update gate: 0/off/no short-circuit before any command" case_update_disabled

case_update_throttled() {
  ab_setup
  export AGENTBOX_AUTO_UPDATE=1
  mkdir -p "$AGENTBOX_HOME"
  date +%s > "$AGENTBOX_HOME/.last-update-check"
  stub_bin docker 'exit 0'
  stub_bin npm 'echo "npm must not run" >&2; exit 7'
  ab_run _agentbox_maybe_update
  assert_eq 0 "$STATUS" "a fresh stamp returns 0"
  assert_eq 0 "$(stub_calls npm)" "a fresh stamp means no npm version check"
  assert_eq 1 "$(stub_calls docker)" "only the image-existence probe runs"
  assert_eq "image inspect $AGENTBOX_IMAGE" "$(stub_argv_line docker)" \
    "that probe is \`docker image inspect\`"
}
test_case "auto-update throttle: a fresh stamp skips the npm check" case_update_throttled

case_update_first_run_builds() {
  ab_setup
  export AGENTBOX_AUTO_UPDATE=1
  stub_bin npm 'echo "npm must not run" >&2; exit 7'
  stub_bin docker 'case "$1" in image) exit 1 ;; esac; exit 0'
  ab_run _agentbox_maybe_update
  assert_eq 0 "$STATUS" "the first-run build path returns 0"
  assert_contains "$STDERR" "not found" "announces that it is building the image"
  assert_eq 2 "$(stub_calls docker)" "image inspect, then build"
  assert_eq "build -t $AGENTBOX_IMAGE $AGENTBOX_REPO" "$(stub_argv_line docker 2)" \
    "builds the image from AGENTBOX_REPO"
  assert_eq 0 "$(stub_calls npm)" "the first-run path does not consult npm"
  assert_file_exists "$AGENTBOX_HOME/.last-update-check" \
    "a successful build stamps the update check"
}
test_case "auto-update first run: missing image is built" case_update_first_run_builds

case_update_first_run_build_failure() {
  ab_setup
  export AGENTBOX_AUTO_UPDATE=1
  stub_bin npm 'echo "npm must not run" >&2; exit 7'
  stub_bin docker 'exit 1'   # the image is missing AND the build fails
  ab_run _agentbox_maybe_update
  assert_eq 0 "$STATUS" "a failed first-run build still returns 0 — the launch proceeds"
  assert_contains "$STDERR" "build failed" "and says so, with a path to the log"
  # This is the one that matters: stamping a FAILED build would consume the
  # whole interval, so the first-run-offline user gets no image, no warning on
  # the next launch, and no retry for a day.
  assert_status -m "a failed build must NOT consume the update interval" \
    1 test -e "$AGENTBOX_HOME/.last-update-check"
}
test_case "auto-update first run: a failed build does not stamp the check" case_update_first_run_build_failure

# Nothing in this file used to put a STALE stamp anywhere: every case had age 0
# or took the image-missing early return, so the whole throttle — the divisor,
# the comparison, the default interval and the stamp write — was untested.
case_update_stale_stamp() {
  ab_setup
  export AGENTBOX_AUTO_UPDATE=1
  mkdir -p "$AGENTBOX_HOME"
  local stamp was
  stamp="$AGENTBOX_HOME/.last-update-check"
  # Exactly one interval old. `age -lt 1` must be FALSE here, so this pins the
  # 86400 divisor, the `-lt` (not `-le`), and the default interval of 1 day.
  was=$(( $(date +%s) - 86400 ))
  echo "$was" > "$stamp"
  stub_bin docker 'exit 0'   # the image exists; the probe is all that may run
  stub_bin npm 'exit 1'      # offline
  ab_run _agentbox_maybe_update

  assert_eq 0 "$STATUS" "an offline version check still returns 0"
  assert_eq 2 "$(stub_calls npm)" "a stamp one day old is stale: both checks run"
  assert_eq "view @anthropic-ai/claude-code version" "$(stub_argv_line npm 1)" \
    "the first check asks npm for @anthropic-ai/claude-code"
  assert_eq "view @openai/codex version" "$(stub_argv_line npm 2)" \
    "the second asks for @openai/codex"
  # npm produced nothing, so the offline guard must stop before the version read.
  assert_eq 1 "$(stub_calls docker)" \
    "with npm unavailable nothing past the image probe runs — no read, no rebuild"
  assert_ne "$was" "$(cat "$stamp")" \
    "the stamp is refreshed UP FRONT, so a failing check is throttled too"
}
test_case "auto-update: a stale stamp triggers the npm checks and re-stamps" case_update_stale_stamp

case_update_interval_is_days_not_hours() {
  ab_setup
  export AGENTBOX_AUTO_UPDATE=1
  mkdir -p "$AGENTBOX_HOME"
  # Two hours old. In DAYS that is age 0 and still throttled; if the divisor
  # were 3600 it would be age 2 and the check would fire 24x too often.
  echo "$(( $(date +%s) - 7200 ))" > "$AGENTBOX_HOME/.last-update-check"
  stub_bin docker 'exit 0'
  stub_bin npm 'echo "npm must not run" >&2; exit 7'
  ab_run _agentbox_maybe_update
  assert_eq 0 "$STATUS" "returns 0"
  assert_eq 0 "$(stub_calls npm)" \
    "AGENTBOX_UPDATE_INTERVAL_DAYS is counted in days: two hours is not stale"
  assert_eq 1 "$(stub_calls docker)" "only the image probe runs"
}
test_case "auto-update throttle counts days, not hours" case_update_interval_is_days_not_hours

# The comparison that decides whether to rebuild at all, plus the two
# --build-arg values it feeds. The docker stub answers differently for `image
# inspect`, `run --entrypoint sh` and `build`, which is all the fidelity the
# version pipeline needs: one line starting with a number for claude, one line
# containing "codex" for codex.
AB_DOCKER_VERSIONED='
case "$1" in
  image) exit 0 ;;
  run)   printf "1.2.3 (Claude Code)\ncodex-cli 4.5.6\n" ;;
  build) : > "$STUB_DIR/docker.built" ;;
esac
exit 0
'

case_update_only_when_a_newer_version_exists() {
  ab_setup
  export AGENTBOX_AUTO_UPDATE=1
  mkdir -p "$AGENTBOX_HOME"
  echo 0 > "$AGENTBOX_HOME/.last-update-check"
  stub_bin docker "$AB_DOCKER_VERSIONED"
  # npm reports exactly what the image already has.
  stub_bin npm 'case "$2" in *claude-code) echo 1.2.3 ;; *codex) echo 4.5.6 ;; esac'
  ab_run _agentbox_maybe_update
  assert_eq 0 "$STATUS" "returns 0"
  assert_eq 2 "$(stub_calls docker)" "image probe + version read, and nothing else"
  assert_status -m "an image that is already current is NOT rebuilt" \
    1 test -e "$STUB_DIR/docker.built"
  assert_not_contains "$STDERR" "updating" "and nothing is announced"
}
test_case "auto-update: no rebuild when the image is already current" case_update_only_when_a_newer_version_exists

case_update_rebuilds_with_the_published_versions() {
  ab_setup
  export AGENTBOX_AUTO_UPDATE=1
  mkdir -p "$AGENTBOX_HOME"
  echo 0 > "$AGENTBOX_HOME/.last-update-check"
  stub_bin docker "$AB_DOCKER_VERSIONED"
  stub_bin npm 'case "$2" in *claude-code) echo 9.9.9 ;; *codex) echo 4.5.6 ;; esac'
  ab_run _agentbox_maybe_update
  assert_eq 0 "$STATUS" "returns 0"
  assert_eq 3 "$(stub_calls docker)" "image probe, version read, then a build"
  assert_file_exists "$STUB_DIR/docker.built" "a newer claude triggers the rebuild"
  # Each version must reach ITS OWN build arg. Swapping the two would install
  # claude-code at codex's version number — silently wrong, never an error here.
  assert_eq "build --build-arg CLAUDE_VERSION=9.9.9 --build-arg CODEX_VERSION=4.5.6 -t $AGENTBOX_IMAGE $AGENTBOX_REPO" \
    "$(stub_argv_line docker 3)" \
    "the build pins each agent to the version npm published for it"
  assert_contains "$STDERR" "1.2.3" "the notice names the version being replaced"
  assert_contains "$STDERR" "9.9.9" "and the one replacing it"
}
test_case "auto-update: a newer version rebuilds with both --build-args" case_update_rebuilds_with_the_published_versions

# ------------------------------------------------------- repo self-location --
# ${${(%):-%x}:A:h} only works when the file is SOURCED, and it is what the
# rebuild path feeds to `docker build`. Cheap to get wrong, so pin it.

case_source_resolves_repo() {
  ab_setup
  cat > "$SCRATCH/probe.zsh" <<'EOZSH'
unset AGENTBOX_REPO
source "$AGENTBOX_SRC" || exit 90
print -r -- "$AGENTBOX_REPO"
EOZSH
  cd "$HOME" || skip "no scratch home to run from"
  capture zsh -f "$SCRATCH/probe.zsh"
  assert_eq 0 "$STATUS" "sourcing agentbox.sh from an unrelated cwd succeeds"
  assert_eq "$(cd "$REPO_ROOT" && pwd -P)" "$STDOUT" \
    "AGENTBOX_REPO resolves to the checkout, not the cwd"
}
test_case "sourcing from another directory resolves AGENTBOX_REPO" case_source_resolves_repo
