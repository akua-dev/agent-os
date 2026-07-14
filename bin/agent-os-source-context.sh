#!/usr/bin/env bash
# Build a credential-free source context from one committed Git tree.
# Usage: bin/agent-os-source-context.sh <empty-destination> [<commit-ish>]
set -euo pipefail

usage() {
  echo "usage: $0 <empty-destination> [<commit-ish>]" >&2
  exit 2
}

[ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage

destination=$1
revision=${2:-HEAD}
script_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
repository=${AGENT_OS_SOURCE_REPO:-$script_root}

commit=$(git -C "$repository" rev-parse --verify "$revision^{commit}")

if [ -e "$destination" ]; then
  [ -d "$destination" ] || { echo "error: destination exists and is not a directory: $destination" >&2; exit 1; }
  [ -z "$(find "$destination" -mindepth 1 -maxdepth 1 -print -quit)" ] \
    || { echo "error: destination must be empty: $destination" >&2; exit 1; }
else
  mkdir -p "$destination"
fi

git -C "$repository" archive --format=tar "$commit" | tar -xf - -C "$destination"

printf 'source_commit=%s\n' "$commit"
printf 'source_tree=%s\n' "$(git -C "$repository" rev-parse "$commit^{tree}")"
