#!/usr/bin/env bash
# One-time setup for the container -> macOS-host command bridge (`onhost`).
# Stable use verifies through the runtime digest selected by Agentbox. A source
# checkout may explicitly select a local development image with --dev-image.
set -euo pipefail

die() {
  printf 'agentbox-host-bridge: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat << 'EOF'
usage: agentbox-host-bridge
       ./setup-host-bridge.sh --dev-image IMAGE

The installed command verifies with the immutable runtime selected by
`agentbox setup`. The --dev-image form is only for a source checkout; it
resolves IMAGE to its current local sha256 image ID before changing SSH files.
EOF
}

SCRIPT_DIR=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
DEV_IMAGE=""

case $# in
  0) ;;
  1)
    if [[ $1 == --help || $1 == -h ]]; then
      usage
      exit 0
    fi
    usage >&2
    exit 64
    ;;
  2)
    [[ $1 == --dev-image ]] || {
      usage >&2
      exit 64
    }
    DEV_IMAGE=$2
    ;;
  *)
    usage >&2
    exit 64
    ;;
esac

[[ ${OSTYPE:-} == darwin* ]] || die "this setup command must run on macOS"
[[ -z ${AGENTBOX_RUNTIME_IMAGE:-} && -z ${AGENTBOX_IMAGE:-} ]] ||
  die "image environment overrides are unsupported; use --dev-image in a source checkout"

ACCOUNT_USER=$(id -un)
ACCOUNT_HOME=$(dscl . -read "/Users/$ACCOUNT_USER" NFSHomeDirectory 2> /dev/null | sed -n 's/^NFSHomeDirectory: //p')
if [[ -z $ACCOUNT_HOME ]]; then
  ACCOUNT_HOME=$(dscacheutil -q user -a name "$ACCOUNT_USER" 2> /dev/null | sed -n 's/^dir: //p')
fi
[[ $ACCOUNT_HOME == /* && $ACCOUNT_HOME != / ]] || die "could not resolve the macOS account home"

if [[ -n $DEV_IMAGE ]]; then
  PERSONAL_HOME="${AGENTBOX_HOME:-$ACCOUNT_HOME/.agentbox}"
else
  [[ -z ${AGENTBOX_HOME+x} ]] || die "AGENTBOX_HOME is supported only with --dev-image in a source checkout"
  PERSONAL_HOME="$ACCOUNT_HOME/.agentbox"
fi
SSH_DIR="$PERSONAL_HOME/.ssh"
KEY="$SSH_DIR/id_agentbox_host"
[[ $PERSONAL_HOME == /* && $PERSONAL_HOME != / ]] || die "AGENTBOX_HOME must be a non-root absolute path"

command -v docker > /dev/null 2>&1 || die "Docker Desktop CLI is required"

if [[ -n $DEV_IMAGE ]]; then
  [[ -f $SCRIPT_DIR/Dockerfile && -x $SCRIPT_DIR/bin/agentbox ]] ||
    die "--dev-image is available only from an Agentbox source checkout"
  IMAGE=$(docker image inspect --format '{{.Id}}' "$DEV_IMAGE" 2> /dev/null) ||
    die "development image is unavailable; run make docker-build first"
  [[ $IMAGE =~ ^sha256:[0-9a-f]{64}$ ]] || die "Docker returned an invalid development image ID"
else
  AGENTBOX_BIN=""
  for candidate in "$SCRIPT_DIR/../../bin/agentbox" "$SCRIPT_DIR/bin/agentbox"; do
    if [[ -x $candidate && ! -L $candidate ]]; then
      AGENTBOX_BIN=$(cd -P -- "$(dirname -- "$candidate")" && pwd)/$(basename -- "$candidate")
      break
    fi
  done
  if [[ -z $AGENTBOX_BIN ]]; then
    candidate=$(command -v agentbox 2> /dev/null || true)
    [[ -n $candidate && -x $candidate ]] && AGENTBOX_BIN=$candidate
  fi
  [[ -n $AGENTBOX_BIN ]] || die "cannot find agentbox; install it before configuring the bridge"
  command -v jq > /dev/null 2>&1 || die "jq is required to read the selected runtime"
  INFO=$("$AGENTBOX_BIN" info --json) || die "could not read Agentbox state"
  IMAGE=$(printf '%s' "$INFO" | jq -er '.current.runtime_image | select(type == "string")' 2> /dev/null) ||
    die "Agentbox has no active runtime; run agentbox setup first"
  [[ $IMAGE =~ ^ghcr\.io/zurfyx/agentbox-runtime@sha256:[0-9a-f]{64}$ ]] ||
    die "Agentbox selected an invalid runtime identity"
  docker image inspect "$IMAGE" > /dev/null 2>&1 ||
    die "the selected runtime is unavailable locally; run agentbox setup first"
fi

LABEL_PROTOCOL=$(docker image inspect --format '{{index .Config.Labels "io.agentbox.runtime-protocol"}}' "$IMAGE")
[[ $LABEL_PROTOCOL == 1 ]] || die "selected image does not implement Agentbox runtime protocol 1"

[[ ! -L $PERSONAL_HOME && ! -L $SSH_DIR ]] || die "refusing a symlinked Agentbox home or SSH directory"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

# Generate a dedicated, unencrypted keypair, but never replace either half of
# an existing pair. Existing material must be regular and internally match.
if [[ -e $KEY || -e $KEY.pub ]]; then
  [[ -f $KEY && ! -L $KEY && -f $KEY.pub && ! -L $KEY.pub ]] ||
    die "existing host-bridge keypair is incomplete or not regular"
  chmod 600 "$KEY"
  chmod 644 "$KEY.pub"
  DERIVED=$(ssh-keygen -y -f "$KEY" 2> /dev/null) || die "existing private key is not a readable SSH key"
  PUBLIC=$(awk 'NR == 1 { print $1 " " $2 } NR > 1 { exit 2 }' "$KEY.pub") ||
    die "existing public key is not one canonical line"
  [[ $DERIVED == "$PUBLIC" && $PUBLIC == ssh-ed25519\ * ]] || die "existing host-bridge keypair does not match"
  echo "Key already exists: $KEY"
else
  ssh-keygen -t ed25519 -N "" -C "agentbox-host-bridge" -f "$KEY"
  echo "Generated $KEY"
fi
chmod 600 "$KEY"
chmod 644 "$KEY.pub"

# Authorize the key for login to this Mac. `restrict` disables forwarding and
# user rc files; `pty` deliberately re-enables the PTY needed by `onhost -t`.
[[ ! -L $ACCOUNT_HOME/.ssh ]] || die "refusing symlinked account SSH directory"
mkdir -p "$ACCOUNT_HOME/.ssh"
chmod 700 "$ACCOUNT_HOME/.ssh"
AUTHORIZED_KEYS="$ACCOUNT_HOME/.ssh/authorized_keys"
[[ ! -L $AUTHORIZED_KEYS ]] || die "refusing symlinked ~/.ssh/authorized_keys"
[[ ! -e $AUTHORIZED_KEYS || -f $AUTHORIZED_KEYS ]] || die "the authorized_keys path is not a regular file"
touch "$AUTHORIZED_KEYS"
chmod 600 "$AUTHORIZED_KEYS"
PUB=$(< "$KEY.pub")
AUTHORIZED="restrict,pty $PUB"
if grep -qF "$PUB" "$AUTHORIZED_KEYS"; then
  echo "Key already authorized in ~/.ssh/authorized_keys"
else
  if [[ -s $AUTHORIZED_KEYS && $(tail -c1 "$AUTHORIZED_KEYS") != "" ]]; then
    printf '\n' >> "$AUTHORIZED_KEYS"
  fi
  printf '%s\n' "$AUTHORIZED" >> "$AUTHORIZED_KEYS"
  echo "Added key to ~/.ssh/authorized_keys"
fi

STATUS=$(systemsetup -getremotelogin 2> /dev/null || true)
case "$STATUS" in
  *[Oo]n) echo "Remote Login: On" ;;
  *[Oo]ff)
    echo "Remote Login is OFF — enable it:"
    echo "  sudo systemsetup -setremotelogin on"
    echo "  (or System Settings -> General -> Sharing -> Remote Login)"
    ;;
  *)
    echo "Could not read Remote Login status. Make sure it is on:"
    echo "  System Settings -> General -> Sharing -> Remote Login"
    ;;
esac

HOST_USER=$ACCOUNT_USER
echo "Verifying bridge through $IMAGE..."
if docker run --rm \
  --mount "type=bind,src=$SSH_DIR,dst=/home/node/.ssh" \
  -e AGENTBOX_HOST=host.docker.internal \
  -e "AGENTBOX_HOST_USER=$HOST_USER" \
  --entrypoint onhost "$IMAGE" 'echo onhost reached $(hostname) as $(whoami)'; then
  echo "Bridge works. Inside Agentbox, run: onhost <cmd> (or: onhost -t <cmd>)"
else
  die "bridge verification failed; confirm Remote Login is enabled and run agentbox setup again"
fi
