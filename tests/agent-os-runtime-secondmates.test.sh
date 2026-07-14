#!/usr/bin/env bash
set -u

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SYNC="$ROOT/bin/agent-os-runtime-secondmates.sh"
TMP=$(fm_test_tmproot agent-os-runtime-secondmates)
FM_HOME_DIR="$TMP/home"
WORK="$TMP/work"
LEASE="$TMP/lease"

fm_git_identity fmtest fmtest@example.com

mkdir -p "$FM_HOME_DIR/state" "$FM_HOME_DIR/data"
git init -q -b main "$WORK"
printf 'data/\nstate/\nconfig/\nprojects/\n.fm-secondmate-home\n' > "$WORK/.gitignore"
printf 'A\n' > "$WORK/version"
printf 'agents\n' > "$WORK/AGENTS.md"
mkdir "$WORK/bin"
printf 'tool\n' > "$WORK/bin/tool"
git -C "$WORK" add -A
git -C "$WORK" commit -qm A
A_COMMIT=$(git -C "$WORK" rev-parse HEAD)
A_TREE=$(git -C "$WORK" rev-parse 'HEAD^{tree}')
printf 'B\n' > "$WORK/version"
git -C "$WORK" add version
git -C "$WORK" commit -qm B
B_COMMIT=$(git -C "$WORK" rev-parse HEAD)
B_TREE=$(git -C "$WORK" rev-parse 'HEAD^{tree}')

git clone -q "$WORK" "$LEASE"
git -C "$LEASE" remote set-url origin https://github.com/akua-dev/agent-os.git
git -C "$LEASE" checkout -q --detach "$A_COMMIT"
git -C "$LEASE" worktree add -q --detach "$TMP/linked" "$A_COMMIT"
git clone -q "$LEASE" "$TMP/standalone"
git -C "$TMP/standalone" checkout -q --detach "$A_COMMIT"
for id in linked standalone; do
  printf '%s\n' "$id" > "$TMP/$id/.fm-secondmate-home"
  mkdir -p "$TMP/$id/data" "$TMP/$id/state" "$TMP/$id/config" "$TMP/$id/projects"
  printf 'persistent-%s\n' "$id" > "$TMP/$id/data/state"
  {
    printf 'window=firstmate:fm-%s\n' "$id"
    printf 'kind=secondmate\n'
    printf 'home=%s/%s\n' "$TMP" "$id"
  } > "$FM_HOME_DIR/state/$id.meta"
done

make_primary() {
  local name=$1 commit=$2
  git clone -q "$WORK" "$TMP/$name"
  git -C "$TMP/$name" remote set-url origin https://github.com/akua-dev/agent-os.git
  git -C "$TMP/$name" checkout -q main
  git -C "$TMP/$name" reset -q --hard "$commit"
}

run_sync() {
  local root=$1 commit=$2 tree=$3 sha=$4
  FM_HOME="$FM_HOME_DIR" FM_ROOT_OVERRIDE="$root" \
    AGENT_OS_SOURCE_COMMIT="$commit" AGENT_OS_SOURCE_TREE="$tree" \
    AGENT_OS_SOURCE_SHA256="$sha" AGENT_OS_SOURCE_BRANCH=main \
    AGENT_OS_SOURCE_ORIGIN=https://github.com/akua-dev/agent-os.git \
    AGENT_OS_SOURCE_MODE=release "$SYNC"
}

make_primary primary-b "$B_COMMIT"
make_primary primary-a "$A_COMMIT"
B_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
A_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

run_sync "$TMP/primary-b" "$B_COMMIT" "$B_TREE" "$B_SHA" >/dev/null || \
  fail "A to B secondmate selection failed"
for id in linked standalone; do
  [ "$(git -C "$TMP/$id" rev-parse HEAD)" = "$B_COMMIT" ] || fail "$id did not select B"
  [ "$(cat "$TMP/$id/data/state")" = "persistent-$id" ] || fail "$id persistent state changed"
  gitdir=$(git -C "$TMP/$id" rev-parse --absolute-git-dir)
  [ -f "$gitdir/agent-os-runtime-source" ] || fail "$id immutable policy was not persisted"
done

run_sync "$TMP/primary-a" "$A_COMMIT" "$A_TREE" "$A_SHA" >/dev/null || \
  fail "B to A secondmate rollback selection failed"
for id in linked standalone; do
  [ "$(git -C "$TMP/$id" rev-parse HEAD)" = "$A_COMMIT" ] || fail "$id did not reselect A"
  [ "$(cat "$TMP/$id/data/state")" = "persistent-$id" ] || fail "$id persistent state changed on rollback"
done
pass "linked and standalone secondmates select exact A to B to A sources"

printf 'tampered\n' >> "$TMP/standalone/AGENTS.md"
if run_sync "$TMP/primary-b" "$B_COMMIT" "$B_TREE" "$B_SHA" >/dev/null 2>&1; then
  fail "dirty secondmate source was replaced"
fi
[ "$(git -C "$TMP/standalone" rev-parse HEAD)" = "$A_COMMIT" ] || \
  fail "dirty secondmate source moved"
pass "dirty secondmate source fails closed"

echo "# all Agent OS runtime secondmate tests passed"
