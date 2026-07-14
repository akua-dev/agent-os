#!/usr/bin/env bash
set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUTPUT=${1:-"$ROOT/image/agent-os-source.bundle"}
SOURCE_BRANCH=${AGENT_OS_SOURCE_BRANCH:-main}
SOURCE_ORIGIN=${AGENT_OS_SOURCE_ORIGIN:-https://github.com/akua-dev/agent-os.git}
[ "$SOURCE_BRANCH" = main ] || { echo "error: source branch must be the declared default branch 'main'" >&2; exit 2; }
[ "$SOURCE_ORIGIN" = https://github.com/akua-dev/agent-os.git ] || { echo "error: source origin is not allowlisted" >&2; exit 2; }

[ -z "$(git -C "$ROOT" status --porcelain --untracked-files=all)" ] || {
  echo "error: exact-source image builds require a clean worktree" >&2
  exit 2
}

SOURCE_COMMIT=$(git -C "$ROOT" rev-parse --verify HEAD)
SOURCE_TREE=$(git -C "$ROOT" rev-parse --verify 'HEAD^{tree}')
mkdir -p "$(dirname "$OUTPUT")"
TEMP="$OUTPUT.tmp.$$"
trap 'rm -f "$TEMP"' EXIT
git -C "$ROOT" bundle create "$TEMP" HEAD
git -C "$ROOT" bundle verify "$TEMP" >/dev/null
mv "$TEMP" "$OUTPUT"
trap - EXIT

printf 'commit=%s\n' "$SOURCE_COMMIT"
printf 'tree=%s\n' "$SOURCE_TREE"
printf 'branch=%s\n' "$SOURCE_BRANCH"
printf 'origin=%s\n' "$SOURCE_ORIGIN"
