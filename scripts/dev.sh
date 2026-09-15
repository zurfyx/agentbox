#!/usr/bin/env bash

set -Eeuo pipefail

skip_build=false

usage() {
  cat << 'EOF'
Usage: scripts/dev.sh [--no-build] [--] [AGENTBOX_ARGUMENT ...]

Build the payload-free runtime from this checkout, render an explicit
development manifest bound to the local image ID, and invoke Agentbox in its
isolated development mode. Use --no-build only to reuse this commit's existing
local image tag; the manifest still records the inspected immutable image ID.
EOF
}

die() {
  printf 'dev: %s\n' "$*" >&2
  exit 1
}

while (($#)); do
  case "$1" in
    --no-build)
      skip_build=true
      shift
      ;;
    --help | -h)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    *) break ;;
  esac
done

((BASH_VERSINFO[0] >= 5)) || die "Bash 5 or newer is required"
command -v docker > /dev/null || die "Docker is required"
command -v git > /dev/null || die "git is required"
command -v jq > /dev/null || die "jq is required"

script_dir=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -P -- "$script_dir/.." && pwd)
cd "$repo_root"

readonly INPUT="$repo_root/release-inputs.json"
readonly VERSION_FILE="$repo_root/VERSION"
SOURCE_COMMIT=$(git rev-parse HEAD)
readonly SOURCE_COMMIT
readonly IMAGE_TAG="agentbox-dev:$SOURCE_COMMIT"
[[ -f $INPUT ]] || die "release-inputs.json is missing"
[[ -f $VERSION_FILE ]] || die "VERSION is missing"
[[ $SOURCE_COMMIT =~ ^[0-9a-f]{40}$ ]] || die "HEAD is not a full Git commit"
agentbox_version=$(< "$VERSION_FILE")
[[ $agentbox_version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "VERSION is invalid"
cmp -s "$VERSION_FILE" <(printf '%s\n' "$agentbox_version") || die "VERSION must be one canonical line"
[[ "$(jq -er .agentbox_version "$INPUT")" == "$agentbox_version" ]] ||
  die "VERSION and release-inputs.json disagree"

sha256_file() {
  if command -v sha256sum > /dev/null; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

instructions_sha=$(sha256_file runtime/instructions.md)
statusline_sha=$(sha256_file runtime/statusline.sh)
[[ "$(jq -er .managed_files.runtime_instructions.sha256 "$INPUT")" == "$instructions_sha" ]] ||
  die "runtime instructions differ from the reviewed release inputs"
[[ "$(jq -er .managed_files.statusline.sha256 "$INPUT")" == "$statusline_sha" ]] ||
  die "runtime status line differs from the reviewed release inputs"

if [[ $skip_build == false ]]; then
  if ! git diff --quiet --ignore-submodules -- || ! git diff --cached --quiet --ignore-submodules --; then
    printf 'dev: warning: building a dirty checkout; the immutable local image ID remains authoritative\n' >&2
  fi
  docker build \
    --tag "$IMAGE_TAG" \
    --build-arg "AGENTBOX_VERSION=$agentbox_version" \
    --build-arg "SOURCE_COMMIT=$SOURCE_COMMIT" \
    --build-arg 'RUNTIME_PROTOCOL=1' \
    --build-arg "INSTRUCTIONS_SHA256=$instructions_sha" \
    --build-arg "STATUSLINE_SHA256=$statusline_sha" \
    .
fi

image_id=$(docker image inspect --format '{{.Id}}' "$IMAGE_TAG")
[[ $image_id =~ ^sha256:[0-9a-f]{64}$ ]] || die "Docker returned an invalid local image ID"

docker run --rm --entrypoint /bin/sh "$image_id" -eu -c \
  '! command -v claude && ! command -v codex && test ! -e /usr/local/lib/node_modules/@anthropic-ai/claude-code && test ! -e /usr/local/lib/node_modules/@openai/codex'

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/agentbox-dev.XXXXXX")
trap 'rm -rf -- "$tmp_dir"' EXIT
manifest="$tmp_dir/dev-manifest.json"
jq -cS --arg image "$image_id" '
  del(.runtime) + {runtime: {image: $image}}
' "$INPUT" > "$manifest"
chmod 0400 "$manifest"

printf 'dev: using %s via %s\n' "$image_id" "$manifest" >&2
AGENTBOX_DEV_MODE=1 AGENTBOX_DEV_MANIFEST="$manifest" "$repo_root/bin/agentbox" "$@"
