#!/bin/bash
set -euo pipefail
HOST_DIR="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly HOST_DIR
readonly STATE_HELPER="$HOST_DIR/state.py"
[[ -r $STATE_HELPER ]] || {
  printf 'agentbox: installation is incomplete (state.py is missing)\n' >&2
  exit 70
}
if [[ -r "$HOST_DIR/../../share/agentbox/VERSION" ]]; then
  VERSION_FILE="$HOST_DIR/../../share/agentbox/VERSION"
elif [[ -r "$HOST_DIR/../VERSION" ]]; then
  VERSION_FILE="$HOST_DIR/../VERSION"
else
  printf 'agentbox: installation is incomplete (VERSION is missing)\n' >&2
  exit 70
fi
AGENTBOX_VERSION="$(< "$VERSION_FILE")"
[[ $AGENTBOX_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  printf 'agentbox: packaged VERSION is invalid\n' >&2
  exit 70
}
readonly VERSION_FILE AGENTBOX_VERSION
SOURCE_CHECKOUT=0
[[ -r "$HOST_DIR/../release-inputs.json" && -r "$HOST_DIR/../bin/agentbox" ]] && SOURCE_CHECKOUT=1
readonly SOURCE_CHECKOUT
TEST_MODE=0
DEV_MODE=0
[[ $SOURCE_CHECKOUT == 1 && ${AGENTBOX_TEST_MODE:-} == 1 ]] && TEST_MODE=1
[[ $SOURCE_CHECKOUT == 1 && ${AGENTBOX_DEV_MODE:-} == 1 ]] && DEV_MODE=1
readonly TEST_MODE DEV_MODE
if [[ $SOURCE_CHECKOUT == 1 ]]; then
  LAUNCHER_PATH="$HOST_DIR/../bin/agentbox"
else
  LAUNCHER_PATH="$HOST_DIR/../../bin/agentbox"
fi
LAUNCHER_PATH="$(cd -P -- "$(dirname -- "$LAUNCHER_PATH")" && pwd)/$(basename -- "$LAUNCHER_PATH")"
readonly LAUNCHER_PATH

resolve_manifest() {
  local candidate
  if [[ $DEV_MODE == 1 ]]; then
    [[ ${AGENTBOX_DEV_MANIFEST:-} == /* && -r ${AGENTBOX_DEV_MANIFEST:-} ]] || {
      printf 'agentbox: AGENTBOX_DEV_MODE requires an absolute readable AGENTBOX_DEV_MANIFEST\n' >&2
      return 64
    }
    candidate="$AGENTBOX_DEV_MANIFEST"
  elif [[ $TEST_MODE == 1 && -n ${AGENTBOX_TEST_MANIFEST:-} ]]; then
    candidate="$AGENTBOX_TEST_MANIFEST"
  elif [[ -r "$HOST_DIR/../../share/agentbox/release-manifest.json" ]]; then
    candidate="$HOST_DIR/../../share/agentbox/release-manifest.json"
  elif [[ -r "$HOST_DIR/../release-manifest.json" ]]; then
    candidate="$HOST_DIR/../release-manifest.json"
  else
    printf 'agentbox: release-manifest.json is missing; this checkout is not a rendered release\n' >&2
    return 70
  fi
  [[ $candidate == /* ]] || candidate="$(pwd -P)/$candidate"
  candidate="$(cd -P -- "$(dirname -- "$candidate")" && pwd)/$(basename -- "$candidate")"
  printf '%s\n' "$candidate"
}

# Follow only fixed Homebrew links whose target remains in that prefix's
# versioned Cellar. Other symlinks are not trusted as host helpers.
trusted_helper_path() {
  local candidate="$1" name="$2" target cellar
  [[ $candidate == /* && -x $candidate ]] || return 1
  if [[ ! -L $candidate ]]; then
    printf '%s\n' "$candidate"
    return
  fi
  case "$candidate" in
    /opt/homebrew/bin/*) cellar=/opt/homebrew/Cellar ;;
    /usr/local/bin/*) cellar=/usr/local/Cellar ;;
    /usr/bin/* | /bin/*)
      target="$(cd -P -- "$(dirname -- "$candidate")" && pwd)/$(basename -- "$candidate")"
      [[ $target == /usr/bin/* || $target == /bin/* ]] || return 1
      printf '%s\n' "$target"
      return
      ;;
    *) return 1 ;;
  esac
  target="$(/usr/bin/readlink "$candidate")" || return 1
  if [[ $target != /* ]]; then
    target="$(cd -P -- "$(dirname -- "$candidate")/$(dirname -- "$target")" && pwd)/$(basename -- "$target")"
  fi
  [[ $target == "$cellar"/* && ${target##*/} == "$name" && -x $target ]] || return 1
  printf '%s\n' "$target"
}

resolve_python() {
  if [[ $TEST_MODE == 1 && -n ${AGENTBOX_TEST_PYTHON:-} ]]; then
    [[ $AGENTBOX_TEST_PYTHON == /* && -x $AGENTBOX_TEST_PYTHON ]] || {
      printf 'agentbox: AGENTBOX_TEST_PYTHON must be an absolute executable\n' >&2
      return 70
    }
    printf '%s\n' "$AGENTBOX_TEST_PYTHON"
    return
  fi
  local candidate
  for candidate in /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
    candidate="$(trusted_helper_path "$candidate" python3 2> /dev/null || true)"
    [[ -n $candidate ]] && {
      printf '%s\n' "$candidate"
      return
    }
  done
  printf 'agentbox: Python 3 is required\n' >&2
  return 69
}

resolve_engine() {
  if [[ $TEST_MODE == 1 && -n ${AGENTBOX_TEST_ENGINE:-} ]]; then
    [[ $AGENTBOX_TEST_ENGINE == /* && -x $AGENTBOX_TEST_ENGINE ]] || {
      printf 'agentbox: AGENTBOX_TEST_ENGINE must be an absolute executable\n' >&2
      return 70
    }
    printf '%s\n' "$AGENTBOX_TEST_ENGINE"
    return
  fi
  local candidate
  for candidate in /Applications/Docker.app/Contents/Resources/bin/docker /opt/homebrew/bin/docker /usr/local/bin/docker /usr/bin/docker; do
    candidate="$(trusted_helper_path "$candidate" docker 2> /dev/null || true)"
    [[ -n $candidate ]] && {
      printf '%s\n' "$candidate"
      return
    }
  done
  printf 'agentbox: Docker Desktop CLI is required; install or start Docker Desktop\n' >&2
  return 69
}

account_home() {
  local value python account
  if [[ $SOURCE_CHECKOUT == 0 && ${AGENTBOX_HOME+x} ]]; then
    printf 'agentbox: AGENTBOX_HOME is a source-checkout-only override and is rejected by the installed launcher\n' >&2
    return 64
  fi
  if [[ $SOURCE_CHECKOUT == 1 && -n ${AGENTBOX_HOME:-} ]]; then
    value="$AGENTBOX_HOME"
  else
    python="$(resolve_python)" || return
    account="$(env -i PATH=/usr/bin:/bin HOME=/var/empty LC_ALL=C "$python" -I -c 'import os,pwd; print(pwd.getpwuid(os.getuid()).pw_dir)')" || return
    value="$account/.agentbox"
  fi
  [[ $value == /* ]] || {
    printf 'agentbox: AGENTBOX_HOME must be absolute\n' >&2
    return 64
  }
  printf '%s\n' "$value"
}

runtime_root() {
  local home="$1"
  if [[ $DEV_MODE == 1 ]]; then
    printf '%s/dev-runtime\n' "$home"
  else
    printf '%s/runtime\n' "$home"
  fi
}

usage() {
  cat << 'EOF'
usage: agentbox [--no-update] [claude|clauded|codex] [--] [ARG ...]
       agentbox setup [--reset-selector] | update | rollback --accept-vendor-state-risk
       agentbox doctor [--json] | info [--json]

Claude is the default. `clauded` disables Claude permission prompts; Codex
uses its approvals/sandbox bypass mode. Codex browser login is unsupported;
use `agentbox codex login --device-auth` or OPENAI_API_KEY.
EOF
}

reject_browser_login() {
  [[ $1 == codex ]] || return 0
  shift
  [[ ${1:-} == login ]] || return 0
  shift
  local arg method=""
  for arg in "$@"; do
    case "$arg" in
      --device-auth | --with-api-key | --with-access-token)
        [[ -z $method ]] || {
          printf 'agentbox: choose exactly one supported Codex login method\n' >&2
          return 64
        }
        method="$arg"
        ;;
      *)
        printf 'agentbox: unsupported Codex login option %q; use login --device-auth or API-key authentication\n' "$arg" >&2
        return 64
        ;;
    esac
  done
  [[ -n $method ]] || {
    printf 'agentbox: browser callback login is unsupported; use `agentbox codex login --device-auth` or OPENAI_API_KEY\n' >&2
    return 64
  }
}

reject_vendor_update() {
  local mode="$1"
  shift
  case "$mode:${1:-}:${2:-}" in
    claude:install:* | claude:update:* | claude:upgrade:* | clauded:install:* | clauded:update:* | clauded:upgrade:* | codex:update:* | codex:remote-control:* | codex:agents:* | codex:app-server:daemon)
      printf 'agentbox: vendor self-update/daemon commands are disabled; use `agentbox update` for the managed release\n' >&2
      return 64
      ;;
  esac
}

run_state() {
  local python
  python="$(resolve_python)" || return
  if [[ $TEST_MODE == 1 ]]; then
    if [[ $DEV_MODE == 1 ]]; then
      env -i PATH=/usr/bin:/bin HOME=/var/empty LC_ALL=C AGENTBOX_TEST_MODE=1 \
        AGENTBOX_TEST_DOWNLOAD_DIR="${AGENTBOX_TEST_DOWNLOAD_DIR:-}" "$python" -I "$STATE_HELPER" --expected-version "$AGENTBOX_VERSION" --development "$@"
    else
      env -i PATH=/usr/bin:/bin HOME=/var/empty LC_ALL=C AGENTBOX_TEST_MODE=1 \
        AGENTBOX_TEST_DOWNLOAD_DIR="${AGENTBOX_TEST_DOWNLOAD_DIR:-}" "$python" -I "$STATE_HELPER" --expected-version "$AGENTBOX_VERSION" "$@"
    fi
  elif [[ $DEV_MODE == 1 ]]; then
    env -i PATH=/usr/bin:/bin HOME=/var/empty LC_ALL=C "$python" -I "$STATE_HELPER" --expected-version "$AGENTBOX_VERSION" --development "$@"
  else
    env -i PATH=/usr/bin:/bin HOME=/var/empty LC_ALL=C "$python" -I "$STATE_HELPER" --expected-version "$AGENTBOX_VERSION" "$@"
  fi
}

setup_release() {
  local reset_selector="${1:-}" manifest engine home root
  manifest="$(resolve_manifest)" || return
  engine="$(resolve_engine)" || return
  home="$(account_home)" || return
  root="$(runtime_root "$home")"
  run_state validate-manifest "$manifest" > /dev/null || return
  if [[ $reset_selector == --reset-selector ]]; then
    run_state prepare --reset-selector --root "$root" --manifest "$manifest" --engine "$engine" || return
  else
    run_state prepare --root "$root" --manifest "$manifest" --engine "$engine" || return
  fi
  printf 'Agentbox %s is prepared.\n' "$AGENTBOX_VERSION"
}

info_command() {
  local option="${1:-}" manifest python home root engine="" state
  [[ -z $option || $option == --json ]] || {
    printf 'usage: agentbox info [--json]\n' >&2
    return 64
  }
  if ! manifest="$(resolve_manifest 2> /dev/null)"; then
    if [[ $option == --json ]]; then
      printf '{"agentbox_version":"%s","manifest":null,"state":"uninstalled"}\n' "$AGENTBOX_VERSION"
    else
      printf 'Agentbox: %s\nManifest: missing (this is not a rendered release)\nState: uninstalled\n' "$AGENTBOX_VERSION"
    fi
    return 0
  fi
  python="$(resolve_python)" || return
  home="$(account_home)" || return
  root="$(runtime_root "$home")"
  state="$(run_state inspect --root "$root" --manifest "$manifest")" || return
  engine="$(resolve_engine 2> /dev/null || true)"
  if [[ $option == --json ]]; then
    "$python" -I -c 'import json,sys;s=json.loads(sys.argv[1]);s.update({"agentbox_version":sys.argv[2],"launcher":sys.argv[3],"manifest":sys.argv[4],"engine":sys.argv[5] or None});print(json.dumps(s,sort_keys=True))' "$state" "$AGENTBOX_VERSION" "$LAUNCHER_PATH" "$manifest" "$engine"
  else
    printf 'Agentbox: %s\nLauncher: %s\nManifest: %s\nEngine: %s\n' "$AGENTBOX_VERSION" "$LAUNCHER_PATH" "$manifest" "${engine:-unavailable}"
    "$python" -I -c 'import json,sys;s=json.loads(sys.argv[1]);i=s["installed"];c=s.get("current");p=s.get("previous");print("State: {}\nRuntime: {}\nClaude: {}\nCodex: {}\nActive: {}\nPrevious: {}".format(s["state"],i["runtime_image"],i["claude_version"],i["codex_version"],c["release_id"] if c else "none",p["release_id"] if p else "none"))' "$state"
  fi
}

doctor_command() {
  local option="${1:-}" manifest python home root engine="" state state_name=invalid engine_status=unavailable image_status=not-prepared status=0 image=""
  [[ -z $option || $option == --json ]] || {
    printf 'usage: agentbox doctor [--json]\n' >&2
    return 64
  }
  manifest="$(resolve_manifest)" || return
  python="$(resolve_python)" || return
  home="$(account_home)" || return
  root="$(runtime_root "$home")"
  if ! state="$(run_state inspect --root "$root" --manifest "$manifest")"; then
    state='{"state":"invalid"}'
    status=1
  fi
  state_name="$("$python" -I -c 'import json,sys;print(json.loads(sys.argv[1])["state"])' "$state")"
  [[ $state_name == ready || $state_name == manual-rollback-hold ]] || status=1
  if engine="$(resolve_engine 2> /dev/null)" && env -i PATH=/usr/bin:/bin HOME=/var/empty LC_ALL=C "$engine" version > /dev/null 2>&1; then
    engine_status=ok
    if image="$(run_state current-field --root "$root" runtime_image 2> /dev/null)"; then
      if env -i PATH=/usr/bin:/bin HOME=/var/empty LC_ALL=C "$engine" image inspect "$image" > /dev/null 2>&1; then image_status=ok; else
        image_status=missing
        status=1
      fi
    fi
  else
    status=1
  fi
  if [[ $option == --json ]]; then
    "$python" -I -c 'import json,sys;print(json.dumps({"agentbox_version":sys.argv[1],"state":json.loads(sys.argv[2])["state"],"engine":sys.argv[3],"image":sys.argv[4]},sort_keys=True))' "$AGENTBOX_VERSION" "$state" "$engine_status" "$image_status"
  else
    printf 'manifest: ok\nstate: '
    "$python" -I -c 'import json,sys;print(json.loads(sys.argv[1])["state"])' "$state"
    printf 'engine: %s\nimage: %s\n' "$engine_status" "$image_status"
  fi
  return "$status"
}

update_command() {
  local brew="" prefix
  if [[ $DEV_MODE == 1 ]]; then
    printf 'agentbox: update is unavailable in development mode; rebuild with scripts/dev.sh\n' >&2
    return 64
  fi
  case "$HOST_DIR" in */Cellar/agentbox/* | */opt/agentbox/*)
    [[ -x /opt/homebrew/bin/brew ]] && brew=/opt/homebrew/bin/brew
    [[ -z $brew && -x /usr/local/bin/brew ]] && brew=/usr/local/bin/brew
    ;;
  esac
  [[ -n $brew ]] || {
    printf 'agentbox: update is available only for Homebrew; update this checkout with git, then run `agentbox setup`\n' >&2
    return 64
  }
  env -i PATH="$(dirname "$brew"):/usr/bin:/bin" HOME="$HOME" LC_ALL=C HOMEBREW_NO_INSECURE_REDIRECT=1 "$brew" upgrade agentbox
  prefix="$(env -i PATH="$(dirname "$brew"):/usr/bin:/bin" HOME="$HOME" LC_ALL=C "$brew" --prefix agentbox)"
  exec "$prefix/bin/agentbox" setup
}

rollback_command() {
  local home root
  home="$(account_home)" || return
  root="$(runtime_root "$home")"
  run_state rollback --root "$root" --accept-vendor-state-risk
  printf 'Agentbox managed release rolled back; automatic reconciliation is held.\n'
}

launch_agent() {
  local mode="$1" no_update="$2"
  shift 2
  reject_browser_login "$mode" "$@" || return
  reject_vendor_update "$mode" "$@" || return
  local manifest="" engine python home root physical_root release image plan plan_fields cwd gh_token="${GH_TOKEN:-}" user_name state gh
  local prior_hash="" after_state="" after_hash="" prepare_status=0 reconciliation_failed=0
  python="$(resolve_python)" || return
  home="$(account_home)" || return
  root="$(runtime_root "$home")"
  if [[ $no_update == 1 ]]; then
    state="$(run_state inspect --root "$root" 2> /dev/null || true)"
    if [[ -z $state ]] || ! "$python" -I -c 'import json,sys;raise SystemExit(0 if json.loads(sys.argv[1])["state"] in ("ready","manual-rollback-hold") else 1)' "$state"; then
      printf 'agentbox: --no-update requires an existing valid active release; run `agentbox setup` first\n' >&2
      return 69
    fi
  else
    manifest="$(resolve_manifest)" || return
    run_state validate-manifest "$manifest" > /dev/null
    state="$(run_state inspect --root "$root" --manifest "$manifest" 2> /dev/null || true)"
    if [[ -n $state ]]; then
      prior_hash="$("$python" -I -c 'import json,sys;v=json.loads(sys.argv[1]);print((v.get("current") or {}).get("manifest_sha256", ""))' "$state")"
    fi
    if [[ -z $state ]] || ! "$python" -I -c 'import json,sys;raise SystemExit(0 if json.loads(sys.argv[1])["state"] in ("ready","manual-rollback-hold") else 1)' "$state"; then
      if setup_release >&2; then
        :
      else
        prepare_status=$?
        if [[ -n $prior_hash ]]; then
          after_state="$(run_state inspect --root "$root" 2> /dev/null || true)"
          if [[ -n $after_state ]]; then
            after_hash="$("$python" -I -c 'import json,sys;v=json.loads(sys.argv[1]);print((v.get("current") or {}).get("manifest_sha256", ""))' "$after_state")"
          fi
        fi
        if [[ -n $prior_hash && $after_hash == "$prior_hash" ]]; then
          printf 'agentbox: warning: installed release preparation failed; running unchanged active release\n' >&2
          reconciliation_failed=1
        else
          return "$prepare_status"
        fi
      fi
    fi
  fi
  engine="$(resolve_engine)" || return
  plan="$(run_state launch-plan --root "$root")" || return
  plan_fields="$("$python" -I -c 'import json,sys;p=json.loads(sys.argv[1]);v=p["current"];print(v["release_path"]+"\t"+v["runtime_image"]+"\t"+p["runtime_root"])' "$plan")"
  release="${plan_fields%%$'\t'*}"
  plan_fields="${plan_fields#*$'\t'}"
  image="${plan_fields%%$'\t'*}"
  physical_root="${plan_fields#*$'\t'}"
  if ! env -i PATH=/usr/bin:/bin HOME=/var/empty LC_ALL=C "$engine" image inspect "$image" > /dev/null 2>&1; then
    if [[ $no_update == 1 ]]; then
      printf 'agentbox: --no-update active runtime image is unavailable; run `agentbox setup`\n' >&2
      return 69
    fi
    if [[ $reconciliation_failed == 1 ]]; then
      printf 'agentbox: unchanged active fallback image is unavailable; retry `agentbox setup`\n' >&2
      return 69
    fi
    setup_release >&2
    plan="$(run_state launch-plan --root "$root")" || return
    plan_fields="$("$python" -I -c 'import json,sys;p=json.loads(sys.argv[1]);v=p["current"];print(v["release_path"]+"\t"+v["runtime_image"]+"\t"+p["runtime_root"])' "$plan")"
    release="${plan_fields%%$'\t'*}"
    plan_fields="${plan_fields#*$'\t'}"
    image="${plan_fields%%$'\t'*}"
    physical_root="${plan_fields#*$'\t'}"
  fi
  cwd="$(pwd -P)"
  user_name="${USER:-$(id -un)}"
  if [[ -z $gh_token ]]; then
    for gh in /opt/homebrew/bin/gh /usr/local/bin/gh /usr/bin/gh; do
      gh="$(trusted_helper_path "$gh" gh 2> /dev/null || true)"
      if [[ -n $gh ]]; then
        gh_token="$(env -i PATH=/usr/bin:/bin HOME="$HOME" LC_ALL=C "$gh" auth token --hostname github.com 2> /dev/null || true)"
        break
      fi
    done
  fi
  [[ -n $gh_token ]] || printf 'agentbox: warning: no GitHub token; private GitHub HTTPS access will fail\n' >&2
  local -a docker_args=(run --rm)
  [[ -t 0 ]] && docker_args+=(-i)
  [[ -t 1 ]] && docker_args+=(-t)
  docker_args+=(--mount "type=bind,src=$home,dst=/home/node" --mount "type=bind,src=$physical_root,dst=/home/node/runtime,readonly" --mount "type=bind,src=$physical_root,dst=$physical_root,readonly" --mount "type=bind,src=$release/vendor,dst=/opt/agentbox/vendor,readonly" --mount "type=bind,src=$release/manifest.json,dst=/opt/agentbox/release/manifest.json,readonly")
  [[ $root == "$physical_root" ]] || docker_args+=(--mount "type=bind,src=$physical_root,dst=$root,readonly")
  local mount
  for mount in /Users /Volumes /tmp /private/tmp; do [[ -d $mount ]] && docker_args+=(--mount "type=bind,src=$mount,dst=$mount"); done
  docker_args+=(-w "$cwd" -e GH_TOKEN -e "AGENTBOX_HOST=${AGENTBOX_HOST:-host.docker.internal}" -e "AGENTBOX_HOST_USER=${AGENTBOX_HOST_USER:-$user_name}")
  [[ $mode == codex && -n ${OPENAI_API_KEY:-} ]] && docker_args+=(-e OPENAI_API_KEY)
  docker_args+=("$image" run --protocol 1 --mode "$mode" --release "$(basename "$release")" -- "$@")
  local -a state_command=(exec-engine -- "$engine" "${docker_args[@]}")
  [[ $mode == codex && (${1:-} == login || ${1:-} == logout) ]] && state_command=(exec-locked --root "$root" -- "$engine" "${docker_args[@]}")
  if [[ $mode == codex && -n ${OPENAI_API_KEY:-} ]]; then
    if [[ $DEV_MODE == 1 ]]; then
      GH_TOKEN="$gh_token" OPENAI_API_KEY="$OPENAI_API_KEY" "$python" -I "$STATE_HELPER" --development "${state_command[@]}"
    else
      GH_TOKEN="$gh_token" OPENAI_API_KEY="$OPENAI_API_KEY" "$python" -I "$STATE_HELPER" "${state_command[@]}"
    fi
  else
    if [[ $DEV_MODE == 1 ]]; then
      GH_TOKEN="$gh_token" OPENAI_API_KEY='' "$python" -I "$STATE_HELPER" --development "${state_command[@]}"
    else
      GH_TOKEN="$gh_token" OPENAI_API_KEY='' "$python" -I "$STATE_HELPER" "${state_command[@]}"
    fi
  fi
}

main() {
  local no_update=0 mode=claude
  if [[ ${1:-} == --no-update ]]; then
    no_update=1
    shift
  fi
  if [[ $no_update == 1 ]]; then
    case "${1:-}" in
      setup | update | rollback | doctor | info)
        printf 'agentbox: --no-update applies only to agent launches\n' >&2
        return 64
        ;;
    esac
  fi
  case "${1:-}" in
    -h | --help | help)
      [[ $# -eq 1 ]] || {
        usage >&2
        return 64
      }
      usage
      return 0
      ;;
    --version)
      [[ $# -eq 1 ]] || {
        printf 'usage: agentbox --version\n' >&2
        return 64
      }
      printf 'agentbox %s\n' "$AGENTBOX_VERSION"
      return 0
      ;;
    setup)
      shift
      [[ $# -eq 0 || ($# -eq 1 && $1 == --reset-selector) ]] || {
        printf 'usage: agentbox setup [--reset-selector]\n' >&2
        return 64
      }
      setup_release "${1:-}"
      return
      ;;
    update)
      shift
      [[ $# -eq 0 ]] || {
        printf 'usage: agentbox update\n' >&2
        return 64
      }
      update_command
      return
      ;;
    rollback)
      shift
      [[ $# -eq 1 && $1 == --accept-vendor-state-risk ]] || {
        printf 'usage: agentbox rollback --accept-vendor-state-risk\n' >&2
        return 64
      }
      rollback_command
      return
      ;;
    info)
      shift
      [[ $# -le 1 ]] || {
        printf 'usage: agentbox info [--json]\n' >&2
        return 64
      }
      info_command "${1:-}"
      return
      ;;
    doctor)
      shift
      [[ $# -le 1 ]] || {
        printf 'usage: agentbox doctor [--json]\n' >&2
        return 64
      }
      doctor_command "${1:-}"
      return
      ;;
    claude | clauded | codex)
      mode="$1"
      shift
      [[ ${1:-} == -- ]] && shift
      ;;
    --) shift ;;
  esac
  launch_agent "$mode" "$no_update" "$@"
}
main "$@"
