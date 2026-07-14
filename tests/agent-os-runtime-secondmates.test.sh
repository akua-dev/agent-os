#!/usr/bin/env bash
set -u

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SYNC="$ROOT/bin/agent-os-runtime-secondmates.sh"
TEST_ROOT=$(fm_test_tmproot agent-os-runtime-secondmates)
TREEHOUSE_POOL="$TEST_ROOT/pool"
TMP="$TREEHOUSE_POOL/0"
FM_HOME_DIR="$TMP/home"
WORK="$TMP/work"
LEASE=
TEST_FLOCK="$TEST_ROOT/flock"
PRESERVE_TREEHOUSE_STATE=false

fm_git_identity fmtest fmtest@example.com

mkdir -p "$FM_HOME_DIR/state" "$FM_HOME_DIR/data" "$TREEHOUSE_POOL"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_FLOCK"
chmod +x "$TEST_FLOCK"
touch "$TREEHOUSE_POOL/treehouse-state.lock"
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
B_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
A_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

LEASE="$FM_HOME_DIR/runtime-sources/$A_COMMIT-$A_SHA"
mkdir -p "$FM_HOME_DIR/runtime-sources"
git clone -q "$WORK" "$LEASE"
git -C "$LEASE" remote set-url origin https://github.com/akua-dev/agent-os.git
git -C "$LEASE" checkout -q --detach "$A_COMMIT"
printf 'mode=release\ncommit=%s\nsource_sha256=%s\n' "$A_COMMIT" "$A_SHA" \
  > "$LEASE/.git/agent-os-runtime-source"
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

write_treehouse_state() {
  local meta id home
  : > "$TEST_ROOT/treehouse-worktrees.jsonl"
  for meta in "$FM_HOME_DIR"/state/*.meta; do
    [ -f "$meta" ] || continue
    [ "$(sed -n 's/^kind=//p' "$meta")" = secondmate ] || continue
    id=${meta##*/}
    id=${id%.meta}
    home=$(sed -n 's/^home=//p' "$meta")
    jq -cn --arg id "$id" --arg home "$home" \
      '{name:$id,path:$home,created_at:"2026-01-01T00:00:00Z",destroying:false,
        owner_pid:0,owner_started_at:0,leased:true,lease_holder:$id,
        leased_at:"2026-01-01T00:00:00Z"}' >> "$TEST_ROOT/treehouse-worktrees.jsonl"
  done
  jq -s '{worktrees:.}' "$TEST_ROOT/treehouse-worktrees.jsonl" \
    > "$TREEHOUSE_POOL/treehouse-state.json"
}

run_sync() {
  local root=$1 commit=$2 tree=$3 sha=$4
  [ "$PRESERVE_TREEHOUSE_STATE" = true ] || write_treehouse_state
  FM_HOME="$FM_HOME_DIR" FM_ROOT_OVERRIDE="$root" \
    AGENT_OS_SOURCE_COMMIT="$commit" AGENT_OS_SOURCE_TREE="$tree" \
    AGENT_OS_SOURCE_SHA256="$sha" AGENT_OS_SOURCE_BRANCH=main \
    AGENT_OS_SOURCE_ORIGIN=https://github.com/akua-dev/agent-os.git \
    AGENT_OS_SOURCE_MODE=release AGENT_OS_TEST_FLOCK_BIN="$TEST_FLOCK" \
    AGENT_OS_TEST_BOUND_PATHS=true "$SYNC"
}

make_primary primary-b "$B_COMMIT"
make_primary primary-a "$A_COMMIT"
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

gitdir=$(git -C "$TMP/standalone" rev-parse --absolute-git-dir)
printf 'mode=release\ncommit=%s\nsource_sha256=%s\n' "$B_COMMIT" "$B_SHA" \
  > "$TMP/standalone/config/agent-os-source-policy.pending"
git -C "$WORK" show "$B_COMMIT:version" > "$TMP/standalone/version"
run_sync "$TMP/primary-b" "$B_COMMIT" "$B_TREE" "$B_SHA" >/dev/null || \
  fail "interrupted secondmate checkout was not recovered from its journal"
[ "$(git -C "$TMP/standalone" rev-parse HEAD)" = "$B_COMMIT" ] || \
  fail "interrupted secondmate checkout did not select B"
[ -z "$(git -C "$TMP/standalone" status --porcelain --untracked-files=all)" ] || \
  fail "interrupted secondmate checkout recovery remained dirty"
[ ! -e "$TMP/standalone/config/agent-os-source-policy.pending" ] || \
  fail "interrupted secondmate checkout retained its journal"
run_sync "$TMP/primary-a" "$A_COMMIT" "$A_TREE" "$A_SHA" >/dev/null || \
  fail "secondmate did not return to A after interrupted checkout recovery"
pass "secondmate selection verifies and recovers interrupted journaled checkouts"

git clone -q "$LEASE" "$TMP/foreign-common"
git -C "$TMP/foreign-common" checkout -q --detach "$A_COMMIT"
git -C "$TMP/foreign-common" worktree add -q --detach "$TMP/foreign-linked" "$A_COMMIT"
printf 'foreign-linked\n' > "$TMP/foreign-linked/.fm-secondmate-home"
mkdir -p "$TMP/foreign-linked/data" "$TMP/foreign-linked/state" \
  "$TMP/foreign-linked/config" "$TMP/foreign-linked/projects"
{
  printf 'window=firstmate:fm-foreign-linked\n'
  printf 'kind=secondmate\n'
  printf 'home=%s/foreign-linked\n' "$TMP"
} > "$FM_HOME_DIR/state/foreign-linked.meta"
if run_sync "$TMP/primary-b" "$B_COMMIT" "$B_TREE" "$B_SHA" >/dev/null 2>&1; then
  fail "linked secondmate owned by a foreign common directory was accepted"
fi
[ "$(git -C "$TMP/foreign-linked" rev-parse HEAD)" = "$A_COMMIT" ] || \
  fail "foreign linked-worktree metadata was mutated"
rm "$FM_HOME_DIR/state/foreign-linked.meta"
pass "secondmate selection binds linked common metadata to runtime-source ownership"

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

write_treehouse_state
PRESERVE_TREEHOUSE_STATE=true
jq 'del(.worktrees[] | select(.lease_holder == "linked"))' \
  "$TREEHOUSE_POOL/treehouse-state.json" > "$TEST_ROOT/state-next.json"
mv "$TEST_ROOT/state-next.json" "$TREEHOUSE_POOL/treehouse-state.json"
if run_sync "$TMP/primary-b" "$B_COMMIT" "$B_TREE" "$B_SHA" >/dev/null 2>&1; then
  fail "missing Treehouse lease evidence was accepted"
fi
[ "$(git -C "$TMP/linked" rev-parse HEAD)" = "$A_COMMIT" ] || \
  fail "missing Treehouse lease evidence allowed source mutation"

write_treehouse_state
jq '(.worktrees[] | select(.lease_holder == "linked") | .leased) = false' \
  "$TREEHOUSE_POOL/treehouse-state.json" > "$TEST_ROOT/state-next.json"
mv "$TEST_ROOT/state-next.json" "$TREEHOUSE_POOL/treehouse-state.json"
if run_sync "$TMP/primary-b" "$B_COMMIT" "$B_TREE" "$B_SHA" >/dev/null 2>&1; then
  fail "stale Treehouse lease evidence was accepted"
fi

write_treehouse_state
jq '(.worktrees[] | select(.lease_holder == "linked") | .lease_holder) = "other"' \
  "$TREEHOUSE_POOL/treehouse-state.json" > "$TEST_ROOT/state-next.json"
mv "$TEST_ROOT/state-next.json" "$TREEHOUSE_POOL/treehouse-state.json"
if run_sync "$TMP/primary-b" "$B_COMMIT" "$B_TREE" "$B_SHA" >/dev/null 2>&1; then
  fail "other-holder Treehouse lease evidence was accepted"
fi

write_treehouse_state
jq '.worktrees += [.worktrees[] | select(.lease_holder == "linked")]' \
  "$TREEHOUSE_POOL/treehouse-state.json" > "$TEST_ROOT/state-next.json"
mv "$TEST_ROOT/state-next.json" "$TREEHOUSE_POOL/treehouse-state.json"
if run_sync "$TMP/primary-b" "$B_COMMIT" "$B_TREE" "$B_SHA" >/dev/null 2>&1; then
  fail "duplicate Treehouse lease evidence was accepted"
fi

write_treehouse_state
jq '.worktrees += [(.worktrees[] | select(.lease_holder == "linked") | .path += "-planted")]' \
  "$TREEHOUSE_POOL/treehouse-state.json" > "$TEST_ROOT/state-next.json"
mv "$TEST_ROOT/state-next.json" "$TREEHOUSE_POOL/treehouse-state.json"
if run_sync "$TMP/primary-b" "$B_COMMIT" "$B_TREE" "$B_SHA" >/dev/null 2>&1; then
  fail "ambiguous planted Treehouse holder evidence was accepted"
fi

printf '{unreadable\n' > "$TREEHOUSE_POOL/treehouse-state.json"
if run_sync "$TMP/primary-b" "$B_COMMIT" "$B_TREE" "$B_SHA" >/dev/null 2>&1; then
  fail "unreadable Treehouse lease evidence was accepted"
fi
PRESERVE_TREEHOUSE_STATE=false
write_treehouse_state
pass "secondmate selection requires one exact active Treehouse lease holder"

git -C "$LEASE" worktree add -q --detach "$TMP/toctou-victim" "$A_COMMIT"
git clone -q "$LEASE" "$TMP/toctou-foreign"
git -C "$TMP/toctou-foreign" checkout -q --detach "$A_COMMIT"
mkdir -p "$TMP/toctou-victim/config" "$TMP/toctou-foreign/config"
foreign_head=$(git -C "$TMP/toctou-foreign" rev-parse HEAD)
AGENT_OS_TEST_BOUND_PATHS=true
export AGENT_OS_TEST_BOUND_PATHS
. "$ROOT/bin/agent-os-runtime-bound.sh"
trusted_git() {
  env -i HOME=/nonexistent PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 \
    /usr/bin/git -c credential.helper= -c core.hooksPath=/dev/null "$@"
}
agent_os_open_bound_dir "$TMP/toctou-victim" || fail "TOCTOU victim home could not be bound"
toctou_home=$AGENT_OS_BOUND_PATH
agent_os_open_bound_dir "$TMP/toctou-victim/config" || fail "TOCTOU victim configuration could not be bound"
toctou_config=$AGENT_OS_BOUND_PATH
toctou_git_path=$(git -C "$TMP/toctou-victim" rev-parse --absolute-git-dir)
agent_os_open_bound_dir "$toctou_git_path" || fail "TOCTOU victim Git directory could not be bound"
toctou_git=$AGENT_OS_BOUND_PATH
rm "$TMP/toctou-victim/.git"
printf 'gitdir: %s/toctou-foreign/.git\n' "$TMP" > "$TMP/toctou-victim/.git"
mv "$TMP/toctou-victim/config" "$TMP/toctou-victim-config-owned"
ln -s "$TMP/toctou-foreign/config" "$TMP/toctou-victim/config"
if agent_os_bound_dir_matches "$TMP/toctou-victim/config" "$toctou_config"; then
  fail "swapped secondmate configuration retained its validated identity"
fi
if [ "$(git -C "$TMP/toctou-victim" rev-parse --absolute-git-dir)" -ef "$toctou_git" ]; then
  fail "swapped secondmate Git pointer retained its validated identity"
fi
agent_os_bound_git "$toctou_git" "$toctou_home" checkout -q --detach "$B_COMMIT" || \
  fail "captured secondmate Git directory could not select its exact source"
agent_os_bound_git "$toctou_git" "$toctou_home" remote set-url origin \
  https://github.com/akua-dev/agent-os.git
printf 'mode=release\ncommit=%s\nsource_sha256=%s\n' "$B_COMMIT" "$B_SHA" \
  > "$toctou_git/agent-os-runtime-source"
[ "$(git -C "$TMP/toctou-foreign" rev-parse HEAD)" = "$foreign_head" ] || \
  fail "pointer swap redirected a captured Git mutation into a foreign repository"
[ ! -e "$TMP/toctou-foreign/.git/agent-os-runtime-source" ] || \
  fail "pointer swap redirected marker mutation into a foreign repository"
[ ! -e "$TMP/toctou-foreign/config/agent-os-source-policy" ] || \
  fail "configuration swap redirected policy mutation into a foreign home"
pass "captured secondmate directories defeat Git pointer swaps"

printf 'tampered\n' >> "$TMP/standalone/AGENTS.md"
if run_sync "$TMP/primary-b" "$B_COMMIT" "$B_TREE" "$B_SHA" >/dev/null 2>&1; then
  fail "dirty secondmate source was replaced"
fi
[ "$(git -C "$TMP/standalone" rev-parse HEAD)" = "$A_COMMIT" ] || \
  fail "dirty secondmate source moved"
pass "dirty secondmate source fails closed"

echo "# all Agent OS runtime secondmate tests passed"
