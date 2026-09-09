#!/usr/bin/env bash
# tests/install.test.sh — install.sh wires agentbox into the user's shell rc and
# provisions $AGENTBOX_HOME. It EDITS REAL DOTFILES, so the interesting failure
# mode is corrupting a hand-maintained ~/.zshrc: a duplicated block, a dropped
# user line, or a marker glued onto the last line of a file with no trailing
# newline. Every case below runs against the per-case fake $HOME with ZDOTDIR
# and AGENTBOX_HOME pointed inside $SCRATCH, so the real rc is never reachable.
#
# Git identity: these tests use a REAL git against the fake $HOME rather than a
# `git` stub. install.sh both READS the identity (`git config --global ...`) and
# WRITES it back (`git config --file ...`), and the write is load-bearing —
# `--file` must MERGE into an existing personal .gitconfig, never clobber it. A
# stub would have to reimplement that merge to say anything, so the real binary
# with HOME/XDG_CONFIG_HOME scoped to $SCRATCH is both simpler and stronger.

. "$(dirname "$0")/lib.sh"

# install.sh runs `set -euo pipefail` and pipes both config merges through
# python3; without it the script cannot get past the settings.json step at all.
skip_unless python3 "install.sh merges settings.json and config.toml with python3"

MARK=">>> agentbox >>>"
END_MARK="<<< agentbox <<<"
LEGACY_MARK="# >>> clauded (my-clauded) >>>"
LEGACY_END="# <<< clauded (my-clauded) <<<"

# ------------------------------------------------------------------ helpers --

# Point every dotfile the installer touches inside $SCRATCH. Belt and braces:
# HOME is already fake (the harness), ZDOTDIR redirects the rc a second time,
# and XDG_CONFIG_HOME/GIT_CONFIG_GLOBAL are cleared so a real git cannot reach
# the developer's own config.
env_setup() {
  ZDOTDIR="$SCRATCH/zdot"
  AGENTBOX_HOME="$SCRATCH/abhome"
  mkdir -p "$ZDOTDIR" "$AGENTBOX_HOME"
  export ZDOTDIR AGENTBOX_HOME
  unset XDG_CONFIG_HOME GIT_CONFIG_GLOBAL
  RC="$ZDOTDIR/.zshrc"
  SETTINGS="$AGENTBOX_HOME/.claude/settings.json"
  CODEX_TOML="$AGENTBOX_HOME/.codex/config.toml"
}

run_install() {
  capture bash "$REPO_ROOT/install.sh"
}

# run_install_from DIR RELPATH — invoke the installer the way a human does,
# with a RELATIVE path from some working directory. `make install` runs
# `./install.sh`, so this is the only shape the documented install path uses.
run_install_from() {
  capture bash -c 'cd "$1" && exec bash "$2"' _ "$1" "$2"
}

# How many lines of $RC are EXACTLY the literal NEEDLE. Whole-line (-x), not
# substring: a user line that merely quotes the marker inside a string must not
# be counted as a marker, which is the same distinction install.sh's awk makes.
# Always a number — grep -c prints 0 (and exits 1) with no match, and the guard
# covers a missing file, where a bare pipeline would return the empty string.
rc_count() {
  [ -f "$RC" ] || { printf '0'; return 0; }
  grep -cxF "$1" "$RC" | tr -d ' '
}

# The managed block, markers included.
rc_block() {
  awk -v s="# $MARK" -v e="# $END_MARK" '$0==s{f=1} f{print} $0==e{f=0}' "$RC"
}

# Everything in $RC that is NOT the managed block — i.e. the user's own lines,
# in their original order. This is what must survive a re-install untouched.
rc_user_lines() {
  awk -v s="# $MARK" -v e="# $END_MARK" '$0==s{f=1} !f{print} $0==e{f=0}' "$RC"
}

# Portable mode string (`ls -l` works the same on GNU and BSD; `stat` does not).
file_mode() {
  ls -l "$1" | cut -c1-10
}

# json_get FILE KEY [KEY...] — walk a JSON document; a numeric KEY indexes a list.
json_get() {
  python3 -c 'import json,sys
d = json.load(open(sys.argv[1]))
for k in sys.argv[2:]:
    d = d[int(k)] if isinstance(d, list) else d[k]
print(d)' "$@" 2>/dev/null
}

# ------------------------------------------------------- fresh install / rc --

case_fresh_install() {
  env_setup
  run_install

  assert_eq 0 "$STATUS" "installer exits 0 on a clean machine"
  assert_contains "$STDOUT" "Installed." "prints the follow-up instructions"
  assert_file_exists "$RC" "creates \$ZDOTDIR/.zshrc when it does not exist"

  # The whole point of the block: source agentbox.sh from THIS checkout, by
  # absolute path, so the rc keeps working from any cwd.
  assert_eq "# $MARK
source \"$REPO_ROOT/agentbox.sh\"
# $END_MARK" "$(rc_block)" "block is exactly marker + absolute source + end marker"

  assert_eq "1" "$(rc_count "# $MARK")" "exactly one start marker"
  assert_eq "1" "$(rc_count "# $END_MARK")" "exactly one end marker"
  assert_empty "$(rc_user_lines)" "a brand-new rc contains nothing but the block"
}
test_case "fresh install writes one marked block sourcing this checkout" case_fresh_install

# THE case for install.sh:6. Every other case runs `bash /abs/path/install.sh`,
# where `dirname` already yields an absolute directory and the assertion above
# cannot fail for the reason it exists. `make install` runs `./install.sh`, and
# without the `cd … && pwd` the rc would end up with `source "./agentbox.sh"` —
# every new shell then sources whatever ./agentbox.sh the cwd happens to hold,
# or errors.
case_relative_invocation_still_absolute() {
  env_setup
  local want
  want="source \"$REPO_ROOT/agentbox.sh\""

  # 1. `./install.sh` from the checkout root — exactly what the Makefile does.
  run_install_from "$REPO_ROOT" ./install.sh
  assert_eq 0 "$STATUS" "\`./install.sh\` from the checkout root exits 0"
  assert_eq "$want" "$(sed -n '2p' "$RC")" \
    "an installer invoked by relative path still writes an ABSOLUTE source line"

  # 2. `../install.sh` from a subdirectory — a relative dirname that is not '.'.
  : > "$RC"
  run_install_from "$REPO_ROOT/tests" ../install.sh
  assert_eq 0 "$STATUS" "\`../install.sh\` from a subdirectory exits 0"
  assert_eq "$want" "$(sed -n '2p' "$RC")" \
    "and so does one invoked as ../install.sh"
  assert_not_contains "$(cat "$RC")" 'source "."' "no relative source line anywhere"
  assert_not_contains "$(cat "$RC")" 'source ".."' "not even a ../ one"
}
test_case "installed by RELATIVE path (make install) still writes an absolute source" case_relative_invocation_still_absolute

# Every other case exports AGENTBOX_HOME, so the suite never once ran the
# installer in the configuration every first-time user is in. `set -u` plus a
# dropped default there is an unbound-variable death AFTER the rc has already
# been rewritten — a half-install.
case_default_agentbox_home() {
  env_setup
  unset AGENTBOX_HOME
  run_install
  assert_eq 0 "$STATUS" "the installer runs with AGENTBOX_HOME unset"
  assert_file_exists "$HOME/.agentbox/.claude/statusline.sh" \
    "AGENTBOX_HOME defaults to \$HOME/.agentbox for the Claude config"
  assert_file_exists "$HOME/.agentbox/.codex/config.toml" \
    "and for the Codex config"
  assert_status -m "nothing was written to the overridden location" \
    1 test -e "$SCRATCH/abhome/.claude"
  assert_file_contains "$RC" "source \"$REPO_ROOT/agentbox.sh\"" \
    "and the rc block is still written"
}
test_case "default AGENTBOX_HOME (\$HOME/.agentbox) is what a first install uses" case_default_agentbox_home

case_idempotent_three_runs() {
  env_setup
  printf 'export FIRST=1\nalias ll="ls -la"\nexport LAST=9\n' > "$RC"

  run_install; assert_eq 0 "$STATUS" "run 1 exits 0"
  run_install; assert_eq 0 "$STATUS" "run 2 exits 0"
  run_install; assert_eq 0 "$STATUS" "run 3 exits 0"

  assert_eq "1" "$(rc_count "# $MARK")" "3 installs leave exactly one start marker"
  assert_eq "1" "$(rc_count "# $END_MARK")" "3 installs leave exactly one end marker"
  assert_eq "1" "$(rc_count "source \"$REPO_ROOT/agentbox.sh\"")" \
    "the source line is written exactly once"

  # Nothing of the user's is duplicated, dropped or reordered.
  assert_eq 'export FIRST=1
alias ll="ls -la"
export LAST=9' "$(rc_user_lines)" "surrounding user lines survive intact and in order"
}
test_case "idempotency: three runs leave one block and untouched user content" case_idempotent_three_runs

case_legacy_migration() {
  env_setup
  {
    printf '# user prologue\n'
    printf 'export BEFORE=1\n'
    printf '%s\n' "$LEGACY_MARK"
    printf 'source "/opt/old/clauded/clauded.sh"\n'
    printf '%s\n' "$LEGACY_END"
    printf 'export AFTER=2\n'
  } > "$RC"

  run_install
  assert_eq 0 "$STATUS" "migration run exits 0"

  body=$(cat "$RC")
  assert_not_contains "$body" "$LEGACY_MARK" "legacy start marker is gone"
  assert_not_contains "$body" "$LEGACY_END" "legacy end marker is gone"
  assert_not_contains "$body" "/opt/old/clauded/clauded.sh" "legacy source line is gone"
  assert_contains "$body" "source \"$REPO_ROOT/agentbox.sh\"" "new source line is present"
  assert_eq "1" "$(rc_count "# $MARK")" "exactly one new block after migrating"

  assert_eq '# user prologue
export BEFORE=1
export AFTER=2' "$(rc_user_lines)" "user lines either side of the legacy block survive, in order"
}
test_case "migration: legacy clauded block is replaced, user lines survive" case_legacy_migration

# strip_block matches whole lines (`$0==s`), not substrings. Loosen that to
# `index($0,s)` and a user line that merely MENTIONS the marker starts the
# deletion: on a first install there is no end marker to stop at, so everything
# from that line to the end of the rc is eaten. Silently destroying a
# hand-maintained ~/.zshrc is the one failure this file exists to prevent.
case_marker_inside_a_user_line() {
  env_setup
  local user_lines
  user_lines="export BEFORE=1
alias show='echo \"# $MARK\"'
export AFTER=2"
  printf '%s\n' "$user_lines" > "$RC"

  run_install
  assert_eq 0 "$STATUS" "install over an rc that mentions the marker exits 0"
  assert_eq "$user_lines" "$(rc_user_lines)" \
    "a user line CONTAINING the marker is not treated as one — nothing is eaten"

  # And again, now that a real end marker exists further down the file.
  run_install
  assert_eq 0 "$STATUS" "a second install exits 0"
  assert_eq "$user_lines" "$(rc_user_lines)" "still byte-identical after re-installing"
  assert_eq "1" "$(rc_count "# $MARK")" "and still exactly one managed block"
}
test_case "an rc line that merely mentions the marker is left alone" case_marker_inside_a_user_line

case_no_trailing_newline() {
  env_setup
  # A hand-edited rc whose last line has no newline. Without the guard in
  # install.sh the marker would be appended to that line and the rc would
  # execute `export PATH=/opt/bin:$PATH# >>> agentbox >>>`.
  printf 'export PATH=/opt/bin:$PATH' > "$RC"

  run_install
  assert_eq 0 "$STATUS" "install over a newline-less rc exits 0"

  assert_eq 'export PATH=/opt/bin:$PATH' "$(sed -n '1p' "$RC")" \
    "the last user line stays on its own line"
  assert_eq "# $MARK" "$(sed -n '2p' "$RC")" "the marker starts a fresh line"
  assert_not_contains "$(cat "$RC")" 'PATH# >>> agentbox' \
    "the marker is never glued onto the previous line"
  assert_eq "1" "$(rc_count "# $MARK")" "still exactly one block"
}
test_case "rc with no trailing newline: marker does not glue onto the last line" case_no_trailing_newline

case_empty_rc() {
  env_setup
  : > "$RC"

  run_install
  assert_eq 0 "$STATUS" "install over an empty rc exits 0"
  assert_eq "# $MARK" "$(sed -n '1p' "$RC")" "no spurious blank line ahead of the block"
  assert_eq "3" "$(wc -l < "$RC" | tr -d ' ')" "an empty rc ends up as exactly the 3 block lines"
}
test_case "empty rc gets the block with no leading blank line" case_empty_rc

# Named for the behaviour, not for install.sh:11: `touch "$RC"` is in fact dead
# today — `grep -qF` on a missing file simply fails inside the `if`, the
# `[ -s "$RC" ]` guard is false, and `>> "$RC"` creates the file. What is pinned
# here is that a missing rc ends up correct, however that happens.
case_missing_rc_is_created() {
  env_setup
  rm -f "$RC"
  assert_status -m "no rc exists before install" 1 test -e "$RC"

  run_install
  assert_eq 0 "$STATUS" "install creates the rc and exits 0"
  assert_file_contains "$RC" "source \"$REPO_ROOT/agentbox.sh\"" "created rc sources agentbox.sh"
  assert_empty "$(rc_user_lines)" "created rc has no stray content"
}
test_case "a missing rc is created, with nothing but the block in it" case_missing_rc_is_created

case_default_rc_location_is_home() {
  env_setup
  # Prove RC="${ZDOTDIR:-$HOME}/.zshrc" falls back to $HOME when ZDOTDIR is
  # unset — still the fake HOME, never the developer's.
  unset ZDOTDIR
  rm -f "$HOME/.zshrc"

  run_install
  assert_eq 0 "$STATUS" "install without ZDOTDIR exits 0"
  assert_file_contains "$HOME/.zshrc" "source \"$REPO_ROOT/agentbox.sh\"" \
    "falls back to \$HOME/.zshrc"
  assert_status -m "the ZDOTDIR rc was not written" 1 test -e "$SCRATCH/zdot/.zshrc"
}
test_case "no ZDOTDIR falls back to \$HOME/.zshrc" case_default_rc_location_is_home

# ------------------------------------------------------------- statusline.sh --

case_statusline_installed() {
  env_setup
  run_install
  assert_eq 0 "$STATUS" "installer exits 0"

  dest="$AGENTBOX_HOME/.claude/statusline.sh"
  assert_file_exists "$dest" "statusline.sh is copied into \$AGENTBOX_HOME/.claude"
  assert_eq "-rwxr-xr-x" "$(file_mode "$dest")" "copied statusline.sh is mode 0755"
  assert_status -m "the copy is byte-identical to the checkout's statusline.sh" \
    0 cmp -s "$REPO_ROOT/statusline.sh" "$dest"
}
test_case "statusline.sh is installed executable (0755)" case_statusline_installed

# The checked-in statusline.sh happens to be mode 755, so `install -m 0755` and
# a plain `cp` are indistinguishable in the case above — cp preserves the source
# mode masked by umask, and 755 & ~022 is 755. Run the installer out of a
# checkout where the executable bit was lost (a downloaded zip, a Windows-touched
# clone, `umask 077`) and only `install -m` still produces a runnable script.
case_statusline_mode_from_a_non_executable_source() {
  env_setup
  local checkout
  checkout=$SCRATCH/fake-checkout
  mkdir -p "$checkout"
  cp "$REPO_ROOT/install.sh" "$checkout/install.sh"
  cp "$REPO_ROOT/statusline.sh" "$checkout/statusline.sh"
  chmod 0644 "$checkout/statusline.sh"
  assert_eq "-rw-r--r--" "$(file_mode "$checkout/statusline.sh")" \
    "the fixture really did lose the executable bit"

  run_install_from "$checkout" ./install.sh
  assert_eq 0 "$STATUS" "installing from that checkout exits 0"
  assert_eq "-rwxr-xr-x" "$(file_mode "$AGENTBOX_HOME/.claude/statusline.sh")" \
    "the installed copy is 0755 regardless of the source file's mode"
}
test_case "statusline.sh is made executable even from a mode-644 checkout" case_statusline_mode_from_a_non_executable_source

# ------------------------------------------------------------ settings.json --

case_settings_merge_preserves_user_keys() {
  env_setup
  mkdir -p "$AGENTBOX_HOME/.claude"
  # theme and statusLine are seeded with DIFFERENT existing values on purpose:
  # install.sh uses setdefault for one and plain assignment for the other, and
  # the README promises the status line is refreshed on every install. Without
  # a pre-existing statusLine here, setdefault and assignment look identical.
  cat > "$SETTINGS" <<'JSON'
{
  "theme": "dark",
  "customKey": {"deeply": ["nested", "value"]},
  "permissions": {"allow": ["Bash(ls:*)"]},
  "statusLine": {"type": "command", "command": "/old/absolute/statusline.sh"}
}
JSON

  run_install
  assert_eq 0 "$STATUS" "installer exits 0 with a pre-existing settings.json"

  assert_status -m "settings.json is still valid JSON" \
    0 python3 -m json.tool "$SETTINGS"
  assert_eq "nested" "$(json_get "$SETTINGS" customKey deeply 0)" \
    "the user's custom key survives the merge"
  assert_eq "Bash(ls:*)" "$(json_get "$SETTINGS" permissions allow 0)" \
    "unrelated existing settings survive"
  assert_eq "dark" "$(json_get "$SETTINGS" theme)" \
    "an already-chosen theme is not overwritten with 'auto'"
  assert_eq "command" "$(json_get "$SETTINGS" statusLine type)" \
    "statusLine is registered in the command form"
  assert_eq "~/.claude/statusline.sh" "$(json_get "$SETTINGS" statusLine command)" \
    "a stale statusLine command is REPLACED, not preserved"
}
test_case "settings.json merge keeps custom keys and sets statusLine" case_settings_merge_preserves_user_keys

case_settings_corrupt_is_rewritten() {
  env_setup
  mkdir -p "$AGENTBOX_HOME/.claude"
  printf '{ this is not json,,, ]]\n' > "$SETTINGS"

  run_install
  assert_eq 0 "$STATUS" "a corrupt settings.json does not crash the installer"
  assert_status -m "corrupt settings.json is rewritten as valid JSON" \
    0 python3 -m json.tool "$SETTINGS"
  assert_eq "command" "$(json_get "$SETTINGS" statusLine type)" "statusLine is set after the rewrite"
  assert_eq "auto" "$(json_get "$SETTINGS" theme)" "theme falls back to 'auto' on a rewrite"
}
test_case "corrupt settings.json is swallowed and rewritten as valid JSON" case_settings_corrupt_is_rewritten

case_settings_idempotent() {
  env_setup
  run_install
  run_install
  assert_eq 0 "$STATUS" "second run exits 0"
  assert_status -m "settings.json is still valid JSON after two runs" \
    0 python3 -m json.tool "$SETTINGS"
  assert_eq "1" "$(grep -cF '"statusLine"' "$SETTINGS" | tr -d ' ')" \
    "statusLine is not duplicated"
}
test_case "settings.json stays valid across repeated installs" case_settings_idempotent

# ---------------------------------------------------------- codex config.toml --

case_codex_absent_file() {
  env_setup
  run_install
  assert_eq 0 "$STATUS" "installer exits 0"

  assert_file_exists "$CODEX_TOML" "config.toml is created"
  assert_eq "[tui]" "$(sed -n '1p' "$CODEX_TOML")" "a fresh file starts with the [tui] table"
  assert_file_contains "$CODEX_TOML" \
    'status_line = ["model-with-reasoning", "git-branch", "context-used", "five-hour-limit", "weekly-limit"]' \
    "the verified status_line token list is written"
  assert_file_contains "$CODEX_TOML" "status_line_use_colors = true" "colors are enabled"
}
test_case "codex config.toml: absent file gets a fresh [tui] table" case_codex_absent_file

case_codex_existing_tui_header() {
  env_setup
  mkdir -p "$AGENTBOX_HOME/.codex"
  cat > "$CODEX_TOML" <<'TOML'
model = "gpt-5-codex"

[tui]
theme = "dark"
notifications = true

[history]
persistence = "none"
TOML

  run_install
  assert_eq 0 "$STATUS" "installer exits 0 with an existing [tui] table"

  # The keys must land UNDER [tui], not at the end of the file (where they would
  # belong to [history] and be silently ignored).
  assert_eq "[tui]" "$(grep -n 'status_line = \[' "$CODEX_TOML" | cut -d: -f1 | while read -r n; do sed -n "$((n-1))p" "$CODEX_TOML"; done)" \
    "status_line is inserted immediately under the [tui] header"

  body=$(cat "$CODEX_TOML")
  assert_contains "$body" 'model = "gpt-5-codex"' "the pre-[tui] top-level key survives"
  assert_contains "$body" 'theme = "dark"' "existing [tui] keys survive"
  assert_contains "$body" "notifications = true" "all existing [tui] keys survive"
  assert_contains "$body" 'persistence = "none"' "a later table survives"
  assert_eq "1" "$(grep -c '^\[tui\]$' "$CODEX_TOML" | tr -d ' ')" "no duplicate [tui] header"
}
test_case "codex config.toml: keys are inserted under an existing [tui] header" case_codex_existing_tui_header

case_codex_existing_status_line_untouched() {
  env_setup
  mkdir -p "$AGENTBOX_HOME/.codex"
  # Deliberately no trailing newline, so "byte-identical" also proves the
  # installer did not helpfully normalise the file.
  printf '[tui]\nstatus_line = ["model"]\ntheme = "light"' > "$CODEX_TOML"
  cp "$CODEX_TOML" "$SCRATCH/config.toml.orig"

  run_install
  assert_eq 0 "$STATUS" "installer exits 0"
  assert_status -m "a config.toml that already sets status_line is left byte-identical" \
    0 cmp -s "$SCRATCH/config.toml.orig" "$CODEX_TOML"
}
test_case "codex config.toml: an existing status_line is left completely untouched" case_codex_existing_status_line_untouched

# The "already configured, leave it alone" guard parses each line and compares
# the KEY: `l.split("=", 1)[0].strip() == "status_line"`. Weaken it to a
# substring test and any near miss — `status_line_use_colors`, a commented-out
# example, a mention in a comment — makes the installer silently do nothing:
# no status line, no error, exit 0.
case_codex_near_miss_keys() {
  env_setup
  local dup
  mkdir -p "$AGENTBOX_HOME/.codex"

  # (a) a different key that merely starts with the same characters
  printf '[tui]\nstatus_line_use_colors = false\n' > "$CODEX_TOML"
  run_install
  assert_eq 0 "$STATUS" "installer exits 0 over status_line_use_colors"
  assert_file_contains "$CODEX_TOML" 'status_line = ["model-with-reasoning"' \
    "status_line_use_colors is NOT status_line — the real key is still added"

  # KNOWN SOURCE BUG: install.sh writes both keys unconditionally, so a user who
  # had set only status_line_use_colors ends up with it twice under [tui] and
  # Codex cannot parse the file at all ("Cannot overwrite a value").
  dup=$(grep -c '^status_line_use_colors' "$CODEX_TOML" | tr -d ' ')
  xfail "install.sh:88-91 appends status_line_use_colors even when the key already exists"
  assert_eq "1" "$dup" "status_line_use_colors is not duplicated into invalid TOML"
  xfail_off

  # (b) a commented-out example must not count as configuration
  env_setup
  mkdir -p "$AGENTBOX_HOME/.codex"
  printf '[tui]\n# status_line = ["model"]\ntheme = "dark"\n' > "$CODEX_TOML"
  run_install
  assert_eq 0 "$STATUS" "installer exits 0 over a commented-out status_line"
  assert_file_contains "$CODEX_TOML" 'status_line = ["model-with-reasoning"' \
    "a commented-out status_line does not count as already configured"
  assert_file_contains "$CODEX_TOML" 'theme = "dark"' "and the real keys survive"
}
test_case "codex config.toml: a near-miss key does not look like status_line" case_codex_near_miss_keys

# The documented flip side, asserted rather than left as a prose note: the guard
# scans the whole file, so a status_line under ANY table means "already
# configured" and the installer keeps its hands off.
case_codex_status_line_under_another_table() {
  env_setup
  mkdir -p "$AGENTBOX_HOME/.codex"
  printf '[other]\nstatus_line = ["model"]\n' > "$CODEX_TOML"
  cp "$CODEX_TOML" "$SCRATCH/config.toml.orig"
  run_install
  assert_eq 0 "$STATUS" "installer exits 0"
  assert_status -m "a status_line under a non-[tui] table still counts as configured" \
    0 cmp -s "$SCRATCH/config.toml.orig" "$CODEX_TOML"
}
test_case "codex config.toml: a status_line anywhere counts as configured" case_codex_status_line_under_another_table

case_codex_no_trailing_newline() {
  env_setup
  mkdir -p "$AGENTBOX_HOME/.codex"
  printf 'model = "gpt-5-codex"' > "$CODEX_TOML"

  run_install
  assert_eq 0 "$STATUS" "installer exits 0 over a newline-less config.toml"

  # The old "[tui] is not glued onto the last line" assertion was a tautology:
  # the writer joins splitlines() with "\n", so gluing is structurally
  # impossible whatever you delete. What DOES vary is install.sh:104-105, the
  # blank-line separator before an appended table — assert that instead.
  assert_eq 'model = "gpt-5-codex"' "$(sed -n '1p' "$CODEX_TOML")" \
    "the existing key stays on its own line"
  assert_eq "" "$(sed -n '2p' "$CODEX_TOML")" \
    "a blank line separates the existing content from the appended table"
  assert_eq "[tui]" "$(sed -n '3p' "$CODEX_TOML")" "and [tui] starts on its own line"
  assert_file_contains "$CODEX_TOML" "status_line_use_colors = true" "the table is still appended"
}
test_case "codex config.toml: content with no trailing newline is not glued" case_codex_no_trailing_newline

case_codex_idempotent() {
  env_setup
  run_install
  cp "$CODEX_TOML" "$SCRATCH/config.toml.first"
  run_install
  assert_eq 0 "$STATUS" "second run exits 0"
  assert_status -m "a second install leaves config.toml byte-identical" \
    0 cmp -s "$SCRATCH/config.toml.first" "$CODEX_TOML"
  assert_eq "1" "$(grep -c '^\[tui\]$' "$CODEX_TOML" | tr -d ' ')" "still one [tui] header"
}
test_case "codex config.toml: re-installing changes nothing" case_codex_idempotent

# ------------------------------------------------------------- git identity --

case_git_identity_mirrored() {
  skip_unless git "install.sh mirrors the host git identity with git itself"
  env_setup
  # Real git, fake HOME: `git config --global` reads $HOME/.gitconfig, and the
  # harness already exports GIT_CONFIG_NOSYSTEM=1, so /etc/gitconfig is out too.
  printf '[user]\n\tname = Ada Lovelace\n\temail = ada@example.com\n' > "$HOME/.gitconfig"

  run_install
  assert_eq 0 "$STATUS" "installer exits 0"
  assert_not_contains "$STDERR" "host git identity not set" "no warning when an identity exists"

  assert_file_exists "$AGENTBOX_HOME/.gitconfig" "the personal .gitconfig is written"
  assert_eq "Ada Lovelace" "$(git config --file "$AGENTBOX_HOME/.gitconfig" user.name)" \
    "user.name is mirrored into \$AGENTBOX_HOME/.gitconfig"
  assert_eq "ada@example.com" "$(git config --file "$AGENTBOX_HOME/.gitconfig" user.email)" \
    "user.email is mirrored into \$AGENTBOX_HOME/.gitconfig"
}
test_case "git identity is mirrored into \$AGENTBOX_HOME/.gitconfig" case_git_identity_mirrored

case_git_identity_merges_not_clobbers() {
  skip_unless git "needs git to read back the merged .gitconfig"
  env_setup
  printf '[user]\n\tname = Ada Lovelace\n\temail = ada@example.com\n' > "$HOME/.gitconfig"
  # A customised personal .gitconfig that must survive — this is the comment's
  # claim in install.sh ("`git config --file` MERGES, never clobbers").
  printf '[core]\n\teditor = nvim\n[alias]\n\tlg = log --oneline\n' > "$AGENTBOX_HOME/.gitconfig"

  run_install
  assert_eq 0 "$STATUS" "installer exits 0"
  assert_eq "nvim" "$(git config --file "$AGENTBOX_HOME/.gitconfig" core.editor)" \
    "a pre-existing core.editor survives"
  assert_eq "log --oneline" "$(git config --file "$AGENTBOX_HOME/.gitconfig" alias.lg)" \
    "a pre-existing alias survives"
  assert_eq "ada@example.com" "$(git config --file "$AGENTBOX_HOME/.gitconfig" user.email)" \
    "the identity is still merged in"
}
test_case "git identity merge does not clobber a customised .gitconfig" case_git_identity_merges_not_clobbers

case_git_identity_absent_warns_but_succeeds() {
  env_setup
  rm -f "$HOME/.gitconfig"

  run_install
  assert_eq 0 "$STATUS" "a host with no git identity still installs successfully"
  assert_contains "$STDERR" "host git identity not set" "the warning is written to stderr"
  assert_contains "$STDERR" "git config --global user.email" "the warning says how to fix it"
  assert_not_contains "$STDOUT" "host git identity not set" "the warning does not pollute stdout"
  assert_status -m "no empty .gitconfig is left behind when there is no identity" \
    1 test -e "$AGENTBOX_HOME/.gitconfig"
  # The rest of the install must still have happened.
  assert_file_contains "$RC" "source \"$REPO_ROOT/agentbox.sh\"" "the rc block is still written"
  assert_file_exists "$AGENTBOX_HOME/.claude/statusline.sh" "statusline.sh is still installed"
}
test_case "no host git identity: warns on stderr, still exits 0" case_git_identity_absent_warns_but_succeeds

# ------------------------------------------------------------------ safety --
# There WAS a "the installer only ever writes inside the fake HOME" case here.
# It could not fail on any change to install.sh: all three of its distinctive
# assertions read variables the TEST itself had just set, and nothing inspected
# the real HOME. Sandboxing is a property of the harness, and harness.test.sh
# tests it properly (see its isolation writer/reader pair).
