#!/usr/bin/env bash
set -eu

SCRIPT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ROOT=$(cd "${AGENT_OS_SOURCE_ROOT:-$SCRIPT_ROOT}" && pwd)
OUTPUT_DIR=${1:-"$ROOT/image"}
SOURCE_BRANCH=${AGENT_OS_SOURCE_BRANCH:-main}
SOURCE_ORIGIN=${AGENT_OS_SOURCE_ORIGIN:-https://github.com/akua-dev/agent-os.git}
SOURCE_REF="refs/heads/$SOURCE_BRANCH"
SOURCE_ARCHIVE="$OUTPUT_DIR/agent-os-source.tar"
BOOTSTRAP_ARCHIVE="$OUTPUT_DIR/agent-os-bootstrap.tar"
ATTESTATION="$OUTPUT_DIR/agent-os-source.attestation"
TEMP="$OUTPUT_DIR/.agent-os-source.$$"

[ "$SOURCE_BRANCH" = main ] || { echo "error: source branch must be the declared default branch 'main'" >&2; exit 2; }
[ "$SOURCE_ORIGIN" = https://github.com/akua-dev/agent-os.git ] || { echo "error: source origin is not allowlisted" >&2; exit 2; }
case "$(git -C "$ROOT" remote get-url origin)" in
  https://github.com/akua-dev/agent-os.git|ssh://git@github.com/akua-dev/agent-os.git|git@github.com:akua-dev/agent-os.git) ;;
  *) echo "error: repository origin is not allowlisted" >&2; exit 2 ;;
esac

[ -z "$(git -C "$ROOT" status --porcelain --untracked-files=all)" ] || {
  echo "error: exact-source image builds require a clean worktree" >&2
  exit 2
}

mkdir -p "$OUTPUT_DIR"
rm -rf "$TEMP"
mkdir -p "$TEMP"
trap 'rm -rf "$TEMP" "$SOURCE_ARCHIVE.tmp.$$" "$BOOTSTRAP_ARCHIVE.tmp.$$" "$ATTESTATION.tmp.$$"' EXIT

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

git init --bare "$TEMP/bootstrap.git" >/dev/null
GIT_TERMINAL_PROMPT=0 git -c credential.helper= --git-dir="$TEMP/bootstrap.git" fetch --depth=1 --no-tags "$SOURCE_ORIGIN" \
  "$SOURCE_REF:refs/heads/$SOURCE_BRANCH"
SOURCE_COMMIT=$(git --git-dir="$TEMP/bootstrap.git" rev-parse --verify "refs/heads/$SOURCE_BRANCH")
SOURCE_TREE=$(git --git-dir="$TEMP/bootstrap.git" rev-parse --verify "$SOURCE_COMMIT^{tree}")
[ "$(git -C "$ROOT" rev-parse --verify HEAD)" = "$SOURCE_COMMIT" ] || {
  echo "error: local HEAD does not exactly match the freshly fetched trusted source ref" >&2
  exit 2
}
[ "$(git -C "$ROOT" rev-parse --verify 'HEAD^{tree}')" = "$SOURCE_TREE" ] || {
  echo "error: local source tree does not exactly match the trusted source ref" >&2
  exit 2
}

git --git-dir="$TEMP/bootstrap.git" symbolic-ref HEAD "refs/heads/$SOURCE_BRANCH"
git --git-dir="$TEMP/bootstrap.git" remote add origin "$SOURCE_ORIGIN"
rm -rf "$TEMP/bootstrap.git/hooks" "$TEMP/bootstrap.git/logs"
rm -f "$TEMP/bootstrap.git/FETCH_HEAD" "$TEMP/bootstrap.git/ORIG_HEAD"
git -C "$ROOT" archive --format=tar --output="$SOURCE_ARCHIVE.tmp.$$" "$SOURCE_COMMIT"
(cd "$TEMP" && find bootstrap.git -exec touch -t 197001010000 {} + && \
  find bootstrap.git -print | LC_ALL=C sort | COPYFILE_DISABLE=1 tar -cf "$BOOTSTRAP_ARCHIVE.tmp.$$" -T -)
SOURCE_SHA=$(sha256_file "$SOURCE_ARCHIVE.tmp.$$")
BOOTSTRAP_SHA=$(sha256_file "$BOOTSTRAP_ARCHIVE.tmp.$$")
{
  printf 'commit=%s\n' "$SOURCE_COMMIT"
  printf 'tree=%s\n' "$SOURCE_TREE"
  printf 'branch=%s\n' "$SOURCE_BRANCH"
  printf 'origin=%s\n' "$SOURCE_ORIGIN"
  printf 'ref=%s\n' "$SOURCE_REF"
  printf 'source_sha256=%s\n' "$SOURCE_SHA"
  printf 'bootstrap_sha256=%s\n' "$BOOTSTRAP_SHA"
} > "$ATTESTATION.tmp.$$"
mv "$SOURCE_ARCHIVE.tmp.$$" "$SOURCE_ARCHIVE"
mv "$BOOTSTRAP_ARCHIVE.tmp.$$" "$BOOTSTRAP_ARCHIVE"
mv "$ATTESTATION.tmp.$$" "$ATTESTATION"
trap - EXIT
rm -rf "$TEMP"

cat "$ATTESTATION"
