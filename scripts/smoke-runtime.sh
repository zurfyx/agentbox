#!/usr/bin/env bash

set -Eeuo pipefail

die() {
  printf 'smoke-runtime: %s\n' "$*" >&2
  exit 1
}

[[ $# == 2 ]] || die "usage: scripts/smoke-runtime.sh IMAGE linux/amd64|linux/arm64"
image=$1
platform=$2
case "$platform" in
  linux/amd64) target=x86_64-unknown-linux-musl ;;
  linux/arm64) target=aarch64-unknown-linux-musl ;;
  *) die "unsupported platform: $platform" ;;
esac

command -v docker > /dev/null || die "Docker is required"
command -v jq > /dev/null || die "jq is required"
readonly VERSION=9.9.9
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/agentbox-runtime-smoke.XXXXXX")
trap 'rm -rf -- "$tmp_dir"' EXIT
mkdir -p \
  "$tmp_dir/downloads" \
  "$tmp_dir/package/bin" \
  "$tmp_dir/package/codex-path" \
  "$tmp_dir/package/codex-resources/zsh/bin" \
  "$tmp_dir/output"
chmod 0777 "$tmp_dir/output"

cat > "$tmp_dir/downloads/claude" << 'EOF'
#!/bin/sh
case " $* " in
  *' --version '*) printf 'Claude Code 9.9.9\n' ;;
  *' --help '*) printf 'usage: claude [options]\n' ;;
  *) printf 'fake-claude:%s\n' "$*" ;;
esac
EOF
cat > "$tmp_dir/package/bin/codex" << 'EOF'
#!/bin/sh
case " $* " in
  *' --version '*) printf 'codex-cli 9.9.9\n' ;;
  *' --help '*) printf 'usage: codex [options]\n' ;;
  *) printf 'fake-codex:%s\n' "$*" ;;
esac
EOF
cat > "$tmp_dir/package/bin/codex-code-mode-host" << 'EOF'
#!/bin/sh
exit 0
EOF
cat > "$tmp_dir/package/codex-path/rg" << 'EOF'
#!/bin/sh
exit 0
EOF
cat > "$tmp_dir/package/codex-resources/bwrap" << 'EOF'
#!/bin/sh
exit 0
EOF
cat > "$tmp_dir/package/codex-resources/zsh/bin/zsh" << 'EOF'
#!/bin/sh
exit 0
EOF
cat > "$tmp_dir/package/codex-package.json" << EOF
{"layoutVersion":1,"version":"$VERSION","target":"$target","variant":"codex","entrypoint":"bin/codex","resourcesDir":"codex-resources","pathDir":"codex-path"}
EOF
chmod 0555 \
  "$tmp_dir/downloads/claude" \
  "$tmp_dir/package/bin/codex" \
  "$tmp_dir/package/bin/codex-code-mode-host" \
  "$tmp_dir/package/codex-path/rg" \
  "$tmp_dir/package/codex-resources/bwrap" \
  "$tmp_dir/package/codex-resources/zsh/bin/zsh"
COPYFILE_DISABLE=1 tar -C "$tmp_dir/package" -czf "$tmp_dir/downloads/codex.tar.gz" \
  bin codex-package.json codex-path codex-resources

sha256_file() {
  sha256sum "$1" | awk '{print $1}'
}
file_size() {
  if stat -f '%z' "$1" > /dev/null 2>&1; then
    stat -f '%z' "$1"
  else
    stat -c '%s' "$1"
  fi
}

claude_sha=$(sha256_file "$tmp_dir/downloads/claude")
claude_size=$(file_size "$tmp_dir/downloads/claude")
codex_sha=$(sha256_file "$tmp_dir/downloads/codex.tar.gz")
codex_size=$(file_size "$tmp_dir/downloads/codex.tar.gz")

jq -cS \
  --arg image 'ghcr.io/zurfyx/agentbox-runtime@sha256:0000000000000000000000000000000000000000000000000000000000000000' \
  --arg platform "$platform" --arg target "$target" --arg version "$VERSION" \
  --arg claude_sha "$claude_sha" --argjson claude_size "$claude_size" \
  --arg codex_sha "$codex_sha" --argjson codex_size "$codex_size" '
    del(.runtime) + {runtime:{image:$image}} |
    .agentbox_version = $version |
    .tools.claude.version = $version |
    (.tools.claude.platforms[] | select(.platform == $platform)) |=
      (.sha256 = $claude_sha | .size = $claude_size) |
    .tools.codex.version = $version |
    (.tools.codex.platforms[] | select(.platform == $platform)) |=
      (.sha256 = $codex_sha | .size = $codex_size | .target = $target)
  ' release-inputs.json > "$tmp_dir/manifest.json"

common=(--rm --platform "$platform" --network none --read-only)
docker run "${common[@]}" --entrypoint /usr/bin/node "$image" --input-type=module -e \
  'import {createHash} from "node:crypto"; import {rmSync} from "node:fs"; if (!createHash || !rmSync) process.exit(1)'
docker run "${common[@]}" \
  --mount "type=bind,src=$tmp_dir/manifest.json,dst=/run/agentbox/manifest.json,readonly" \
  --mount "type=bind,src=$tmp_dir/downloads,dst=/run/agentbox/downloads,readonly" \
  --mount "type=bind,src=$tmp_dir/output,dst=/run/agentbox/output" \
  "$image" prepare --protocol 1 --platform "$platform" \
  --manifest /run/agentbox/manifest.json \
  --downloads /run/agentbox/downloads --output /run/agentbox/output/candidate |
  jq -e '.ok == true and .protocol == 1' > /dev/null

docker run "${common[@]}" \
  --tmpfs /home/node:rw,noexec,nosuid,nodev,size=32m \
  --mount "type=bind,src=$tmp_dir/manifest.json,dst=/run/agentbox/manifest.json,readonly" \
  --mount "type=bind,src=$tmp_dir/output/candidate,dst=/opt/agentbox/vendor,readonly" \
  "$image" validate --protocol 1 --platform "$platform" \
  --manifest /run/agentbox/manifest.json --candidate /opt/agentbox/vendor |
  jq -e '.ok == true and (.assertions | all)' > /dev/null

docker run "${common[@]}" \
  --tmpfs /home/node:rw,nosuid,nodev,size=32m \
  --mount "type=bind,src=$tmp_dir/output/candidate,dst=/opt/agentbox/vendor,readonly" \
  "$image" run --protocol 1 --mode claude --release "$VERSION" -- smoke-sentinel |
  grep -F smoke-sentinel > /dev/null

# The runtime runs as uid 1000, while GitHub's Linux runner commonly owns the
# checkout as uid 1001. Restore cleanup access without requiring sudo on the
# host and without weakening the production mount contract.
docker run --rm --platform "$platform" --user root \
  --mount "type=bind,src=$tmp_dir/output,dst=/run/agentbox/output" \
  --entrypoint /bin/chmod "$image" -R ugo+rwX /run/agentbox/output

printf 'runtime smoke passed for %s\n' "$platform"
