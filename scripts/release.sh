#!/usr/bin/env bash

set -Eeuo pipefail

input=release-inputs.json
output_dir=dist
version=
source_commit=
index_digest=
amd64_digest=
arm64_digest=
dry_run=false

usage() {
  cat << 'EOF'
Usage: scripts/release.sh [--dry-run] [--input PATH] [--output-dir DIR]
                          [--version X.Y.Z] [--source-commit 40HEX]
                          [--index-digest sha256:HEX]
                          [--amd64-digest sha256:HEX]
                          [--arm64-digest sha256:HEX]

Render the final exact-digest manifest and deterministic Homebrew archive.
In --dry-run mode omitted identities are filled with obvious non-publishable
sentinels and no output directory is created. Publication must pass every
identity explicitly.
EOF
}

die() {
  printf 'release: %s\n' "$*" >&2
  exit 1
}

sha256_file() {
  if command -v sha256sum > /dev/null; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

while (($#)); do
  case "$1" in
    --dry-run) dry_run=true ;;
    --input | --output-dir | --version | --source-commit | --index-digest | --amd64-digest | --arm64-digest)
      (($# >= 2)) || die "$1 requires a value"
      case "$1" in
        --input) input=$2 ;;
        --output-dir) output_dir=$2 ;;
        --version) version=$2 ;;
        --source-commit) source_commit=$2 ;;
        --index-digest) index_digest=$2 ;;
        --amd64-digest) amd64_digest=$2 ;;
        --arm64-digest) arm64_digest=$2 ;;
      esac
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
command -v git > /dev/null || die "git is required"
command -v jq > /dev/null || die "jq is required"
[[ -f $input ]] || die "missing release inputs: $input"

input_version=$(jq -er '.agentbox_version | select(type == "string")' "$input")
version=${version:-$input_version}
source_commit=${source_commit:-$(git rev-parse HEAD)}
if [[ $dry_run == true ]]; then
  index_digest=${index_digest:-sha256:0000000000000000000000000000000000000000000000000000000000000000}
  amd64_digest=${amd64_digest:-sha256:1111111111111111111111111111111111111111111111111111111111111111}
  arm64_digest=${arm64_digest:-sha256:2222222222222222222222222222222222222222222222222222222222222222}
fi

[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version must be X.Y.Z"
[[ $version == "$input_version" ]] || die "version does not equal release-inputs.json"
[[ $source_commit =~ ^[0-9a-f]{40}$ ]] || die "source commit must be 40 lowercase hex characters"
for digest in "$index_digest" "$amd64_digest" "$arm64_digest"; do
  [[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || die "all OCI digests must be exact sha256 digests"
done

repository=$(jq -er '.runtime.image_repository | select(type == "string")' "$input")
[[ $repository == ghcr.io/zurfyx/agentbox-runtime ]] || die "unexpected runtime image repository"

jq -e '
  .schema_version == 1 and
  .runtime_protocol_version == 1 and
  (.tools | keys == ["claude", "codex"]) and
  .tools.claude.kind == "raw-executable" and
  .tools.codex.kind == "tar.gz-package" and
  .tools.codex.layout_version == 1 and
  .tools.codex.entrypoint == "bin/codex" and
  ([.tools.claude.platforms[].platform] | sort == ["linux/amd64", "linux/arm64"]) and
  ([.tools.codex.platforms[].platform] | sort == ["linux/amd64", "linux/arm64"])
' "$input" > /dev/null || die "release inputs do not match schema 1"

required_files=(
  VERSION
  bin/agentbox
  libexec/host.sh
  libexec/state.py
  completions/agentbox.bash
  completions/_agentbox
  completions/agentbox.fish
  setup-host-bridge.sh
  README.md
  LICENSE
  THIRD_PARTY_NOTICES.md
)
for path in "${required_files[@]}"; do
  [[ -f $path ]] || die "required package file is missing: $path"
done
root_version=$(< VERSION)
[[ $root_version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "VERSION is invalid"
cmp -s VERSION <(printf '%s\n' "$root_version") || die "VERSION must be one canonical line"
[[ $root_version == "$version" ]] || die "VERSION does not equal the requested release version"
[[ "$(jq -er .version package.json)" == "$version" ]] || die "package.json version does not match VERSION"
[[ "$(jq -er .version package-lock.json)" == "$version" ]] || die "package-lock.json version does not match VERSION"
[[ "$(jq -er '.packages[""].version' package-lock.json)" == "$version" ]] ||
  die "package-lock root package version does not match VERSION"
[[ "$(sha256_file runtime/instructions.md)" == "$(jq -er .managed_files.runtime_instructions.sha256 "$input")" ]] ||
  die "runtime instructions do not match the reviewed release inputs"
[[ "$(sha256_file runtime/statusline.sh)" == "$(jq -er .managed_files.statusline.sha256 "$input")" ]] ||
  die "runtime status line does not match the reviewed release inputs"

if [[ $dry_run == false ]]; then
  [[ -n $index_digest && -n $amd64_digest && -n $arm64_digest ]] ||
    die "publication requires the index and both child digests"
  [[ "$(git rev-parse HEAD)" == "$source_commit" ]] || die "source commit is not checked out"
  git diff --quiet --ignore-submodules -- || die "tracked worktree changes are not releasable"
  git diff --cached --quiet --ignore-submodules -- || die "staged changes are not releasable"
fi

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/agentbox-release.XXXXXX")
trap 'rm -rf -- "$tmp_dir"' EXIT
root="$tmp_dir/agentbox-$version"
mkdir -p "$root/bin" "$root/libexec" "$root/completions" "$root/share/agentbox"

install -m 0444 VERSION "$root/VERSION"
install -m 0555 bin/agentbox "$root/bin/agentbox"
install -m 0555 libexec/host.sh "$root/libexec/host.sh"
install -m 0555 libexec/state.py "$root/libexec/state.py"
install -m 0444 completions/agentbox.bash "$root/completions/agentbox.bash"
install -m 0444 completions/_agentbox "$root/completions/_agentbox"
install -m 0444 completions/agentbox.fish "$root/completions/agentbox.fish"
install -m 0555 setup-host-bridge.sh "$root/setup-host-bridge.sh"
install -m 0444 README.md "$root/README.md"
install -m 0444 LICENSE "$root/LICENSE"
install -m 0444 THIRD_PARTY_NOTICES.md "$root/THIRD_PARTY_NOTICES.md"
install -m 0444 VERSION "$root/share/agentbox/VERSION"
install -m 0444 README.md "$root/share/agentbox/README.md"
install -m 0444 THIRD_PARTY_NOTICES.md "$root/share/agentbox/THIRD_PARTY_NOTICES.md"

jq -cS --arg image "$repository@$index_digest" '
  del(.runtime) + {runtime: {image: $image}}
' "$input" > "$root/share/agentbox/release-manifest.json"
chmod 0444 "$root/share/agentbox/release-manifest.json"

# The host validator is the release manifest contract authority.
python3 libexec/state.py --expected-version "$version" validate-manifest "$root/share/agentbox/release-manifest.json" > /dev/null

asset="agentbox-$version.tar.gz"
if [[ $dry_run == true ]]; then
  printf 'Dry run: would create %s from %s at source %s.\n' "$asset" "$repository@$index_digest" "$source_commit"
  printf 'Platform manifests: linux/amd64@%s linux/arm64@%s\n' "$amd64_digest" "$arm64_digest"
  exit 0
fi

mkdir -p "$output_dir"
[[ ! -e "$output_dir/$asset" ]] || die "refusing to replace $output_dir/$asset"
[[ ! -e "$output_dir/$asset.sha256" ]] || die "refusing to replace $output_dir/$asset.sha256"
[[ ! -e "$output_dir/agentbox-$version.provenance.json" ]] || die "refusing to replace provenance"

epoch=$(git show -s --format=%ct "$source_commit")
tar --version | grep -F 'GNU tar' > /dev/null || die "deterministic publication requires GNU tar"
tar --sort=name --format=ustar --mtime="@$epoch" --owner=0 --group=0 --numeric-owner \
  -C "$tmp_dir" -czf "$output_dir/$asset" "agentbox-$version"

archive_sha=$(sha256_file "$output_dir/$asset")
printf '%s  %s\n' "$archive_sha" "$asset" > "$output_dir/$asset.sha256"
jq -cnS \
  --arg version "$version" --arg source_commit "$source_commit" \
  --arg image "$repository@$index_digest" --arg index "$index_digest" \
  --arg amd64 "$amd64_digest" --arg arm64 "$arm64_digest" \
  --arg archive "$asset" --arg archive_sha256 "$archive_sha" \
  '{schema_version:1,agentbox_version:$version,source_commit:$source_commit,runtime_image:$image,runtime_index_digest:$index,runtime_platform_digests:{"linux/amd64":$amd64,"linux/arm64":$arm64},archive:$archive,archive_sha256:$archive_sha256}' \
  > "$output_dir/agentbox-$version.provenance.json"

printf 'Created %s (sha256:%s).\n' "$output_dir/$asset" "$archive_sha"
