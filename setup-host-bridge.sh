#!/usr/bin/env bash
# One-time setup for the container -> macOS-host command bridge (`onhost`).
# Run this ON THE MAC. Idempotent — safe to re-run.
#
# It:
#   1. generates a dedicated SSH keypair in the personal config dir,
#   2. authorizes that key for SSH login to this Mac,
#   3. checks that Remote Login is enabled (and tells you how if not),
#   4. verifies the bridge end-to-end from inside the container.
set -euo pipefail

PERSONAL_HOME="${MY_CLAUDED_HOME:-$HOME/.claude-personal}"
SSH_DIR="$PERSONAL_HOME/.ssh"
KEY="$SSH_DIR/id_clauded_host"
IMAGE="${MY_CLAUDED_IMAGE:-claude-personal}"

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

# 1. Dedicated keypair — never overwrite an existing one.
if [ ! -f "$KEY" ]; then
  ssh-keygen -t ed25519 -N "" -C "clauded-host-bridge" -f "$KEY"
  echo "Generated $KEY"
else
  echo "Key already exists: $KEY"
fi
chmod 600 "$KEY"

# 2. Authorize the key for login to this Mac (idempotent).
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
touch "$HOME/.ssh/authorized_keys"
chmod 600 "$HOME/.ssh/authorized_keys"
PUB="$(cat "$KEY.pub")"
if grep -qF "$PUB" "$HOME/.ssh/authorized_keys"; then
  echo "Key already authorized in ~/.ssh/authorized_keys"
else
  # Ensure a trailing newline so the new key can't merge onto an existing line.
  if [ -s "$HOME/.ssh/authorized_keys" ] && [ "$(tail -c1 "$HOME/.ssh/authorized_keys")" != "" ]; then
    printf '\n' >> "$HOME/.ssh/authorized_keys"
  fi
  printf '%s\n' "$PUB" >> "$HOME/.ssh/authorized_keys"
  echo "Added key to ~/.ssh/authorized_keys"
fi

# 3. Remote Login must be on. (systemsetup may need Full Disk Access to *report*
#    status even when it's on, so treat an unclear answer as "check manually".)
STATUS="$(systemsetup -getremotelogin 2>/dev/null || true)"
case "$STATUS" in
  *[Oo]n) echo "Remote Login: On" ;;
  *[Oo]ff) echo "Remote Login is OFF — enable it:";
           echo "  sudo systemsetup -setremotelogin on";
           echo "  (or System Settings -> General -> Sharing -> Remote Login)" ;;
  *) echo "Could not read Remote Login status. Make sure it's on:";
     echo "  System Settings -> General -> Sharing -> Remote Login" ;;
esac

# 4. Verify the bridge from inside the container.
echo "Verifying bridge from the container..."
if docker run --rm \
    -v "$PERSONAL_HOME:/home/node" \
    -e CLAUDED_HOST=host.docker.internal \
    -e CLAUDED_HOST_USER="$USER" \
    --entrypoint onhost "$IMAGE" 'echo onhost reached $(hostname) as $(whoami)'; then
  echo "Bridge works. Inside my-clauded, run:  onhost <cmd>   (or: onhost -t <cmd>)"
else
  echo "Bridge test FAILED — check Remote Login is on and the image is built (make build)." >&2
  exit 1
fi
