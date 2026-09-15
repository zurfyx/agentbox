#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v shellcheck > /dev/null 2>&1; then
  echo "shellcheck is required (brew install shellcheck)" >&2
  exit 127
fi

mapfile -t files < <(
  git ls-files -co --exclude-standard -- \
    '*.sh' 'bin/*' 'libexec/*.sh' 'runtime/*' 'scripts/*.sh' '.husky/*' |
    while IFS= read -r file; do
      [[ -f $file ]] || continue
      head -c 256 "$file" | grep -qE '^#!.*(ba|z|k)?sh|^#! */usr/bin/env +bash' || [[ $file == *.sh ]] || continue
      printf '%s\n' "$file"
    done
)

if ((${#files[@]})); then
  shellcheck --severity=warning -- "${files[@]}"
fi
