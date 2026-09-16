#!/usr/bin/env bash

set -Eeuo pipefail

readonly CLAUDE_LATEST_URL="https://downloads.claude.ai/claude-code-releases/latest"
readonly CLAUDE_RELEASE_ROOT="https://downloads.claude.ai/claude-code-releases"
readonly CODEX_LATEST_URL="https://releases.openai.com/codex/channels/latest"
readonly CODEX_RELEASE_ROOT="https://releases.openai.com/codex/releases"
readonly MAX_ARTIFACT_SIZE=$((512 * 1024 * 1024))
readonly SOURCE_VERSION_SENTINEL="0.0.0"
readonly STABLE_SEMVER_RE='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'

mode=dry-run
verify_downloads=false
input=release-inputs.json

usage() {
  cat << 'EOF'
Usage: scripts/update-versions.sh [--dry-run|--write] [--verify-downloads]
                                  [--input PATH]

Resolve the moving vendor channels into exact, version-addressed release inputs.
The default is a non-mutating dry run. --write is intended for the update bot;
--verify-downloads additionally downloads and hashes all four Linux artifacts.
EOF
}

die() {
  printf 'update-versions: %s\n' "$*" >&2
  exit 1
}

while (($#)); do
  case "$1" in
    --dry-run) mode=dry-run ;;
    --write) mode='write' ;;
    --verify-downloads) verify_downloads=true ;;
    --input)
      (($# >= 2)) || die "--input requires a path"
      input=$2
      shift
      ;;
    --help | -h)
      usage
      exit 0
      ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

((BASH_VERSINFO[0] >= 5)) || die "Bash 5 or newer is required"
command -v curl > /dev/null || die "curl is required"
command -v jq > /dev/null || die "jq is required"
command -v python3 > /dev/null || die "Python 3 is required"
[[ -f $input ]] || die "missing reviewed input file: $input"
[[ -f VERSION ]] || die "missing source VERSION template"
script_dir=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly CODEX_INSPECTOR="$script_dir/inspect-codex-package.py"
[[ -x $CODEX_INSPECTOR ]] || die "Codex package inspector is missing or not executable"
cmp -s VERSION <(printf '%s\n' "$SOURCE_VERSION_SENTINEL") ||
  die "VERSION must contain the canonical source sentinel $SOURCE_VERSION_SENTINEL"
[[ "$(jq -er '.agentbox_version | select(type == "string")' "$input")" == "$SOURCE_VERSION_SENTINEL" ]] ||
  die "release-inputs.json must retain the source version sentinel"
[[ "$(jq -er '.version | select(type == "string")' package.json)" == "$SOURCE_VERSION_SENTINEL" ]] ||
  die "package.json must retain the source version sentinel"
[[ "$(jq -er '.version | select(type == "string")' package-lock.json)" == "$SOURCE_VERSION_SENTINEL" ]] ||
  die "package-lock.json must retain the source version sentinel"
[[ "$(jq -er '.packages[""].version | select(type == "string")' package-lock.json)" == "$SOURCE_VERSION_SENTINEL" ]] ||
  die "package-lock root package must retain the source version sentinel"

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/agentbox-update.XXXXXX")
trap 'rm -rf -- "$tmp_dir"' EXIT

python3 - "$input" << 'PY'
import json
import sys

def unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result

with open(sys.argv[1], encoding="utf-8") as source:
    json.load(source, object_pairs_hook=unique)
PY
jq -cS '
  .runtime.image_repository as $repository |
  del(.runtime) + {runtime: {image: ($repository + "@sha256:0000000000000000000000000000000000000000000000000000000000000000")}}
' "$input" > "$tmp_dir/input-manifest.json"
python3 libexec/state.py --expected-version "$SOURCE_VERSION_SENTINEL" validate-manifest "$tmp_dir/input-manifest.json" > /dev/null ||
  die "release inputs do not satisfy the strict manifest contract"

curl_text() {
  curl --fail --silent --show-error \
    --proto '=https' --tlsv1.2 --max-time 60 --retry 3 "$1"
}

head_size() {
  local value
  value=$(
    curl --fail --silent --show-error --head \
      --proto '=https' --tlsv1.2 --max-time 60 --retry 3 "$1" |
      awk 'BEGIN { IGNORECASE=1 } /^content-length:/ { gsub("\\r", "", $2); n=$2 } END { print n }'
  )
  [[ $value =~ ^[1-9][0-9]*$ ]] || die "missing Content-Length for $1"
  ((value <= MAX_ARTIFACT_SIZE)) || die "artifact is over the 512 MiB limit: $1"
  printf '%s\n' "$value"
}

sha256_file() {
  if command -v sha256sum > /dev/null; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

file_size() {
  if stat -f '%z' "$1" > /dev/null 2>&1; then
    stat -f '%z' "$1"
  else
    stat -c '%s' "$1"
  fi
}

verify_artifact() {
  local url=$1 expected_size=$2 expected_sha=$3 destination=$4
  curl --fail --silent --show-error \
    --proto '=https' --tlsv1.2 --max-time 900 --retry 3 \
    --output "$destination" "$url"
  [[ "$(file_size "$destination")" == "$expected_size" ]] ||
    die "download size mismatch for $url"
  [[ "$(sha256_file "$destination")" == "$expected_sha" ]] ||
    die "download checksum mismatch for $url"
}

claude_version=$(curl_text "$CLAUDE_LATEST_URL")
[[ $claude_version =~ $STABLE_SEMVER_RE ]] ||
  die "Claude latest channel did not return a stable semantic version"
claude_manifest=$(curl_text "$CLAUDE_RELEASE_ROOT/$claude_version/manifest.json")
jq -e --arg version "$claude_version" '
  (keys == ["buildDate", "commit", "manifestSignatureEnforcement", "modsCommit", "platforms", "sdkCompat", "version"]) and
  .version == $version and
  (.platforms["linux-arm64"] | keys == ["binary", "checksum", "size"]) and
  (.platforms["linux-x64"] | keys == ["binary", "checksum", "size"])
' <<< "$claude_manifest" > /dev/null || die "Claude manifest schema changed"

read_claude_field() {
  jq -er --arg platform "$1" --arg field "$2" \
    '.platforms[$platform][$field]' <<< "$claude_manifest"
}

claude_arm_sha=$(read_claude_field linux-arm64 checksum)
claude_arm_size=$(read_claude_field linux-arm64 size)
claude_amd_sha=$(read_claude_field linux-x64 checksum)
claude_amd_size=$(read_claude_field linux-x64 size)
for value in "$claude_arm_sha" "$claude_amd_sha"; do
  [[ $value =~ ^[0-9a-f]{64}$ ]] || die "invalid Claude checksum metadata"
done
for value in "$claude_arm_size" "$claude_amd_size"; do
  if [[ ! $value =~ ^[1-9][0-9]*$ ]] || ((value > MAX_ARTIFACT_SIZE)); then
    die "invalid Claude size metadata"
  fi
done
[[ "$(read_claude_field linux-arm64 binary)" == claude ]] || die "unexpected Claude arm64 artifact"
[[ "$(read_claude_field linux-x64 binary)" == claude ]] || die "unexpected Claude amd64 artifact"

claude_arm_url="$CLAUDE_RELEASE_ROOT/$claude_version/linux-arm64/claude"
claude_amd_url="$CLAUDE_RELEASE_ROOT/$claude_version/linux-x64/claude"
[[ "$(head_size "$claude_arm_url")" == "$claude_arm_size" ]] || die "Claude arm64 HEAD size mismatch"
[[ "$(head_size "$claude_amd_url")" == "$claude_amd_size" ]] || die "Claude amd64 HEAD size mismatch"

codex_feed=$(curl_text "$CODEX_LATEST_URL")
jq -e 'keys == ["assets", "tag_name"] and (.assets | type == "array")' <<< "$codex_feed" > /dev/null ||
  die "Codex latest channel schema changed"
codex_tag=$(jq -er '.tag_name | select(type == "string")' <<< "$codex_feed")
[[ $codex_tag =~ ^rust-v((0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*))$ ]] ||
  die "Codex latest channel did not return an expected stable tag"
codex_version=${BASH_REMATCH[1]}

codex_asset() {
  local name=$1 field=$2
  jq -er --arg name "$name" --arg field "$field" \
    '[.assets[] | select(.name == $name)] as $matches |
      if ($matches | length) == 1 and ($matches[0] | keys) == ["browser_download_url", "digest", "name"]
      then $matches[0][$field] else error("asset must be unique and schema-exact") end' \
    <<< "$codex_feed"
}

codex_arm_name=codex-package-aarch64-unknown-linux-musl.tar.gz
codex_amd_name=codex-package-x86_64-unknown-linux-musl.tar.gz
codex_arm_url="$CODEX_RELEASE_ROOT/$codex_version/$codex_arm_name"
codex_amd_url="$CODEX_RELEASE_ROOT/$codex_version/$codex_amd_name"
[[ "$(codex_asset "$codex_arm_name" browser_download_url)" == "$codex_arm_url" ]] ||
  die "Codex arm64 URL is not exactly version-addressed"
[[ "$(codex_asset "$codex_amd_name" browser_download_url)" == "$codex_amd_url" ]] ||
  die "Codex amd64 URL is not exactly version-addressed"
codex_arm_sha=$(codex_asset "$codex_arm_name" digest)
codex_amd_sha=$(codex_asset "$codex_amd_name" digest)
codex_arm_sha=${codex_arm_sha#sha256:}
codex_amd_sha=${codex_amd_sha#sha256:}
[[ $codex_arm_sha =~ ^[0-9a-f]{64}$ ]] || die "invalid Codex arm64 digest"
[[ $codex_amd_sha =~ ^[0-9a-f]{64}$ ]] || die "invalid Codex amd64 digest"
codex_arm_size=$(head_size "$codex_arm_url")
codex_amd_size=$(head_size "$codex_amd_url")

if [[ $verify_downloads == true ]]; then
  verify_artifact "$claude_arm_url" "$claude_arm_size" "$claude_arm_sha" "$tmp_dir/claude-arm64"
  verify_artifact "$claude_amd_url" "$claude_amd_size" "$claude_amd_sha" "$tmp_dir/claude-amd64"
  verify_artifact "$codex_arm_url" "$codex_arm_size" "$codex_arm_sha" "$tmp_dir/codex-arm64.tar.gz"
  verify_artifact "$codex_amd_url" "$codex_amd_size" "$codex_amd_sha" "$tmp_dir/codex-amd64.tar.gz"

  jq -r '.tools.codex.allowed_members[]' "$input" | LC_ALL=C sort > "$tmp_dir/expected-members"
  "$CODEX_INSPECTOR" "$tmp_dir/codex-arm64.tar.gz" \
    --version "$codex_version" --target aarch64-unknown-linux-musl \
    --members-file "$tmp_dir/expected-members"
  "$CODEX_INSPECTOR" "$tmp_dir/codex-amd64.tar.gz" \
    --version "$codex_version" --target x86_64-unknown-linux-musl \
    --members-file "$tmp_dir/expected-members"
fi

old_claude=$(jq -er '.tools.claude.version' "$input")
old_codex=$(jq -er '.tools.codex.version' "$input")
[[ $old_claude =~ $STABLE_SEMVER_RE ]] || die "stored Claude version is not stable SemVer"
[[ $old_codex =~ $STABLE_SEMVER_RE ]] || die "stored Codex version is not stable SemVer"

jq -S \
  --arg claude_version "$claude_version" \
  --arg claude_arm_url "$claude_arm_url" --arg claude_arm_sha "$claude_arm_sha" --argjson claude_arm_size "$claude_arm_size" \
  --arg claude_amd_url "$claude_amd_url" --arg claude_amd_sha "$claude_amd_sha" --argjson claude_amd_size "$claude_amd_size" \
  --arg codex_version "$codex_version" \
  --arg codex_arm_url "$codex_arm_url" --arg codex_arm_sha "$codex_arm_sha" --argjson codex_arm_size "$codex_arm_size" \
  --arg codex_amd_url "$codex_amd_url" --arg codex_amd_sha "$codex_amd_sha" --argjson codex_amd_size "$codex_amd_size" '
    .tools.claude.version = $claude_version |
    (.tools.claude.platforms[] | select(.platform == "linux/arm64")) |=
      (.url = $claude_arm_url | .sha256 = $claude_arm_sha | .size = $claude_arm_size) |
    (.tools.claude.platforms[] | select(.platform == "linux/amd64")) |=
      (.url = $claude_amd_url | .sha256 = $claude_amd_sha | .size = $claude_amd_size) |
    .tools.codex.version = $codex_version |
    (.tools.codex.platforms[] | select(.platform == "linux/arm64")) |=
      (.url = $codex_arm_url | .sha256 = $codex_arm_sha | .size = $codex_arm_size) |
    (.tools.codex.platforms[] | select(.platform == "linux/amd64")) |=
      (.url = $codex_amd_url | .sha256 = $codex_amd_sha | .size = $codex_amd_size)
  ' "$input" > "$tmp_dir/release-inputs.json"

semver_compare() {
  python3 - "$1" "$2" << 'PY'
import sys

left = tuple(int(part) for part in sys.argv[1].split("."))
right = tuple(int(part) for part in sys.argv[2].split("."))
print((left > right) - (left < right))
PY
}

claude_order=$(semver_compare "$claude_version" "$old_claude")
codex_order=$(semver_compare "$codex_version" "$old_codex")
((claude_order >= 0)) || die "Claude channel moved backwards: $old_claude -> $claude_version"
((codex_order >= 0)) || die "Codex channel moved backwards: $old_codex -> $codex_version"

for vendor in claude codex; do
  old_record="$tmp_dir/$vendor-old.json"
  new_record="$tmp_dir/$vendor-new.json"
  jq -cS --arg vendor "$vendor" '.tools[$vendor]' "$input" > "$old_record"
  jq -cS --arg vendor "$vendor" '.tools[$vendor]' "$tmp_dir/release-inputs.json" > "$new_record"
  order_name="${vendor}_order"
  if [[ ${!order_name} == 0 ]] && ! cmp -s "$old_record" "$new_record"; then
    die "$vendor metadata changed without a version change; refusing same-version drift"
  fi
done

if ((claude_order == 0 && codex_order == 0)); then
  printf 'Vendor inputs already current (Claude %s, Codex %s).\n' "$claude_version" "$codex_version"
  exit 0
fi

jq -cS '
  .runtime.image_repository as $repository |
  del(.runtime) + {runtime: {image: ($repository + "@sha256:0000000000000000000000000000000000000000000000000000000000000000")}}
' "$tmp_dir/release-inputs.json" > "$tmp_dir/updated-manifest.json"
python3 libexec/state.py --expected-version "$SOURCE_VERSION_SENTINEL" validate-manifest "$tmp_dir/updated-manifest.json" > /dev/null ||
  die "updated release inputs do not satisfy the strict manifest contract"

if [[ $mode == write ]]; then
  chmod --reference="$input" "$tmp_dir/release-inputs.json" 2> /dev/null || chmod 0644 "$tmp_dir/release-inputs.json"
  mv "$tmp_dir/release-inputs.json" "$input"
  printf 'Updated vendor inputs only: Claude %s -> %s, Codex %s -> %s.\n' \
    "$old_claude" "$claude_version" "$old_codex" "$codex_version"
else
  printf 'Would update vendor inputs only: Claude %s -> %s, Codex %s -> %s.\n' \
    "$old_claude" "$claude_version" "$old_codex" "$codex_version"
  jq -S . "$tmp_dir/release-inputs.json"
fi
