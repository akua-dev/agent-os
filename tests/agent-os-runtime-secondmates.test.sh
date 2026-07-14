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
  [ -f "$TMP/$id/config/agent-os-source-policy" ] || fail "$id home policy was not persisted"
  [ -f "$TMP/$id/config/agent-os-source-policy.required" ] || \
    fail "$id immutable policy requirement was not persisted"
  cmp "$gitdir/agent-os-runtime-source" "$TMP/$id/config/agent-os-source-policy" || \
    fail "$id Git and home policies differ"
done

run_sync "$TMP/primary-a" "$A_COMMIT" "$A_TREE" "$A_SHA" >/dev/null || \
  fail "B to A secondmate rollback selection failed"
for id in linked standalone; do
  [ "$(git -C "$TMP/$id" rev-parse HEAD)" = "$A_COMMIT" ] || fail "$id did not reselect A"
  [ "$(cat "$TMP/$id/data/state")" = "persistent-$id" ] || fail "$id persistent state changed on rollback"
done
pass "linked and standalone secondmates select exact A to B to A sources"

gitdir=$(git -C "$TMP/standalone" rev-parse --absolute-git-dir)
printf 'mode=release\ncommit=%s\nsource_sha256=%s\n' "$B_COMMIT" "$B_SHA" \
  > "$TMP/standalone/config/agent-os-source-policy"
if run_sync "$TMP/primary-b" "$B_COMMIT" "$B_TREE" "$B_SHA" >/dev/null 2>&1; then
  fail "mismatched secondmate immutable policies were accepted"
fi
[ "$(git -C "$TMP/standalone" rev-parse HEAD)" = "$A_COMMIT" ] || \
  fail "mismatched secondmate immutable policy allowed source mutation"
cp "$gitdir/agent-os-runtime-source" "$TMP/standalone/config/agent-os-source-policy"
pass "secondmate selection rejects mismatched immutable policies"

gitdir=$(git -C "$TMP/standalone" rev-parse --absolute-git-dir)
printf 'immutable\n' > "$TMP/standalone/config/agent-os-source-policy.required"
printf 'mode=release\ncommit=%s\nsource_sha256=%s\n' "$B_COMMIT" "$B_SHA" \
  > "$TMP/standalone/config/agent-os-source-policy.pending"
cp "$TMP/standalone/config/agent-os-source-policy.pending" \
  "$TMP/standalone/config/agent-os-source-policy"
printf 'mode=release\ncommit=%s\nsource_sha256=%s\n' "$A_COMMIT" "$A_SHA" \
  > "$gitdir/agent-os-runtime-source"
run_sync "$TMP/primary-b" "$B_COMMIT" "$B_TREE" "$B_SHA" >/dev/null || \
  fail "journaled secondmate policy transition was not recovered"
[ ! -e "$TMP/standalone/config/agent-os-source-policy.pending" ] || \
  fail "recovered secondmate policy journal was retained"
cmp "$gitdir/agent-os-runtime-source" "$TMP/standalone/config/agent-os-source-policy" || \
  fail "recovered secondmate policies differ"
run_sync "$TMP/primary-a" "$A_COMMIT" "$A_TREE" "$A_SHA" >/dev/null || \
  fail "secondmate did not return to A after journal recovery"
pass "secondmate selection recovers journaled policy transitions"

git clone -q "$LEASE" "$TMP/redirected"
git -C "$TMP/redirected" checkout -q --detach "$A_COMMIT"
printf 'owner\n' > "$TMP/redirected/.fm-secondmate-home"
mkdir -p "$TMP/redirected/data" "$TMP/redirected/state" "$TMP/redirected/config" "$TMP/redirected/projects"
{
  printf 'window=firstmate:fm-redirected\n'
  printf 'kind=secondmate\n'
  printf 'home=%s/redirected\n' "$TMP"
} > "$FM_HOME_DIR/state/redirected.meta"
if run_sync "$TMP/primary-b" "$B_COMMIT" "$B_TREE" "$B_SHA" >/dev/null 2>&1; then
  fail "mismatched secondmate ownership marker was accepted"
fi
[ "$(git -C "$TMP/redirected" rev-parse HEAD)" = "$A_COMMIT" ] || \
  fail "mismatched secondmate home was mutated"
rm "$FM_HOME_DIR/state/redirected.meta"
pass "secondmate selection requires exact registered marker ownership"

git clone -q "$LEASE" "$TMP/git-victim"
git -C "$TMP/git-victim" checkout -q --detach "$A_COMMIT"
git clone -q "$LEASE" "$TMP/git-redirected"
git -C "$TMP/git-redirected" checkout -q --detach "$A_COMMIT"
printf 'git-redirected\n' > "$TMP/git-redirected/.fm-secondmate-home"
mkdir -p "$TMP/git-redirected/data" "$TMP/git-redirected/state" \
  "$TMP/git-redirected/config" "$TMP/git-redirected/projects"
mv "$TMP/git-redirected/.git" "$TMP/git-redirected-own.git"
printf 'gitdir: %s/git-victim/.git\n' "$TMP" > "$TMP/git-redirected/.git"
{
  printf 'window=firstmate:fm-git-redirected\n'
  printf 'kind=secondmate\n'
  printf 'home=%s/git-redirected\n' "$TMP"
} > "$FM_HOME_DIR/state/git-redirected.meta"
if run_sync "$TMP/primary-b" "$B_COMMIT" "$B_TREE" "$B_SHA" >/dev/null 2>&1; then
  fail "secondmate home redirected to another Git directory was accepted"
fi
[ "$(git -C "$TMP/git-victim" rev-parse HEAD)" = "$A_COMMIT" ] || \
  fail "foreign Git metadata was mutated through a redirected secondmate home"
rm "$FM_HOME_DIR/state/git-redirected.meta"
pass "secondmate selection binds Git metadata to its exact home"

git clone -q "$LEASE" "$TMP/linked-alias"
git -C "$TMP/linked-alias" checkout -q --detach "$A_COMMIT"
printf 'linked\n' > "$TMP/linked-alias/.fm-secondmate-home"
mkdir -p "$TMP/linked-alias/data" "$TMP/linked-alias/state" "$TMP/linked-alias/config" \
  "$TMP/linked-alias/projects"
printf -- '- linked - standby (home: %s/linked-alias; state: idle)\n' "$TMP" \
  > "$FM_HOME_DIR/data/secondmates.md"
if run_sync "$TMP/primary-b" "$B_COMMIT" "$B_TREE" "$B_SHA" >/dev/null 2>&1; then
  fail "duplicate secondmate identity homes were accepted"
fi
[ "$(git -C "$TMP/linked-alias" rev-parse HEAD)" = "$A_COMMIT" ] || \
  fail "duplicate secondmate identity home was mutated"
: > "$FM_HOME_DIR/data/secondmates.md"
pass "secondmate selection rejects one identity mapped to multiple homes"

git clone -q "$LEASE" "$TMP/linked/projects/nested"
git -C "$TMP/linked/projects/nested" checkout -q --detach "$A_COMMIT"
printf 'nested\n' > "$TMP/linked/projects/nested/.fm-secondmate-home"
mkdir -p "$TMP/linked/projects/nested/data" "$TMP/linked/projects/nested/state" \
  "$TMP/linked/projects/nested/config" "$TMP/linked/projects/nested/projects"
{
  printf 'window=firstmate:fm-nested\n'
  printf 'kind=secondmate\n'
  printf 'home=%s/linked/projects/nested\n' "$TMP"
} > "$FM_HOME_DIR/state/nested.meta"
if run_sync "$TMP/primary-b" "$B_COMMIT" "$B_TREE" "$B_SHA" >/dev/null 2>&1; then
  fail "overlapping secondmate homes were accepted"
fi
[ "$(git -C "$TMP/linked/projects/nested" rev-parse HEAD)" = "$A_COMMIT" ] || \
  fail "overlapping secondmate home was mutated"
rm "$FM_HOME_DIR/state/nested.meta"
pass "secondmate selection rejects canonical home overlap"

printf 'tampered\n' >> "$TMP/standalone/AGENTS.md"
if run_sync "$TMP/primary-b" "$B_COMMIT" "$B_TREE" "$B_SHA" >/dev/null 2>&1; then
  fail "dirty secondmate source was replaced"
fi
[ "$(git -C "$TMP/standalone" rev-parse HEAD)" = "$A_COMMIT" ] || \
  fail "dirty secondmate source moved"
pass "dirty secondmate source fails closed"

echo "# all Agent OS runtime secondmate tests passed"
