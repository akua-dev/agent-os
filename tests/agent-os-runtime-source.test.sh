#!/usr/bin/env bash
set -u

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MATERIALIZE="$ROOT/bin/agent-os-runtime-source.sh"
TMP=$(fm_test_tmproot agent-os-runtime-source)
HOME_DIR="$TMP/home"

fm_git_identity fmtest fmtest@example.com

make_source() {
  local name=$1 value=$2 work bare
  work="$TMP/$name-work"
  bare="$TMP/$name.git"
  git init -q "$work"
  git -C "$work" checkout -q -b main
  printf '%s\n' "$value" > "$work/version"
  git -C "$work" add version
  git -C "$work" commit -qm "$name"
  git clone -q --bare "$work" "$bare"
  git -C "$bare" symbolic-ref HEAD refs/heads/main
}

materialize() {
  local source=$1 sha=$2 commit tree
  commit=$(git --git-dir="$source" rev-parse refs/heads/main)
  tree=$(git --git-dir="$source" rev-parse "$commit^{tree}")
  FM_HOME="$HOME_DIR" AGENT_OS_IMAGE_SOURCE="$source" \
    AGENT_OS_SOURCE_COMMIT="$commit" AGENT_OS_SOURCE_TREE="$tree" \
    AGENT_OS_SOURCE_SHA256="$sha" AGENT_OS_SOURCE_BRANCH=main \
    AGENT_OS_SOURCE_ORIGIN=https://github.com/akua-dev/agent-os.git \
    AGENT_OS_SOURCE_MODE=candidate "$MATERIALIZE"
}

make_source a A
make_source b B
mkdir -p "$HOME_DIR/data"
printf 'persistent\n' > "$HOME_DIR/data/captain-state"

A_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
B_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
A_ROOT=$(materialize "$TMP/a.git" "$A_SHA") || fail "release A materialization failed"
B_ROOT=$(materialize "$TMP/b.git" "$B_SHA") || fail "release B materialization failed"
A_AGAIN=$(materialize "$TMP/a.git" "$A_SHA") || fail "release A rollback selection failed"

[ "$A_ROOT" = "$A_AGAIN" ] || fail "A to B to A did not select the original exact source"
[ "$A_ROOT" != "$B_ROOT" ] || fail "different releases shared one mutable source checkout"
[ "$(cat "$A_ROOT/version")" = A ] || fail "release A source changed after B materialization"
[ "$(cat "$B_ROOT/version")" = B ] || fail "release B source was not selected"
[ "$(cat "$HOME_DIR/data/captain-state")" = persistent ] || fail "persistent home state changed"
pass "content-addressed sources support A to B to A without changing home state"

PARTIAL_SHA=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
PARTIAL_COMMIT=$(git --git-dir="$TMP/b.git" rev-parse refs/heads/main)
mkdir -p "$HOME_DIR/runtime-sources/.${PARTIAL_COMMIT}-${PARTIAL_SHA}.materializing"
if materialize "$TMP/b.git" "$PARTIAL_SHA" >/dev/null 2>&1; then
  fail "partial immutable source materialization was accepted"
fi
[ "$(cat "$B_ROOT/version")" = B ] || fail "failed B materialization damaged retained release B"
A_AFTER_FAILED_B=$(materialize "$TMP/a.git" "$A_SHA") || fail "failed B compensation could not reselect release A"
[ "$A_AFTER_FAILED_B" = "$A_ROOT" ] || fail "failed B compensation did not preserve release A"
pass "partial materialization fails closed without damaging retained sources"

printf 'tampered\n' > "$A_ROOT/version"
if materialize "$TMP/a.git" "$A_SHA" >/dev/null 2>&1; then
  fail "tampered immutable source was accepted"
fi
pass "tampered immutable source fails closed"

echo "# all Agent OS runtime source tests passed"
