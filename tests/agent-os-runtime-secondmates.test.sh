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
TEST_LOCK_ROOT="$TEST_ROOT/locks"
PRESERVE_TREEHOUSE_STATE=false

fm_git_identity fmtest fmtest@example.com

mkdir -p "$FM_HOME_DIR/state" "$FM_HOME_DIR/data" "$TREEHOUSE_POOL" "$TEST_LOCK_ROOT"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -eu' \
  'fd=${2:?lock file descriptor is required}' \
  'target=${AGENT_OS_TEST_LOCK_FILE_HINT:?lock file identity is required}' \
  'key=$(printf "%s" "$target" | /usr/bin/cksum | /usr/bin/awk "{print \$1}")' \
  'lock="$AGENT_OS_TEST_LOCK_ROOT/$key"' \
  'if ! /bin/mkdir "$lock" 2>/dev/null; then' \
  '  owner=$(/bin/cat "$lock/owner" 2>/dev/null || true)' \
  '  if [ -n "$owner" ] && /bin/kill -0 "$owner" 2>/dev/null; then exit 1; fi' \
  '  /bin/rm -rf "$lock"' \
  '  /bin/mkdir "$lock"' \
  'fi' \
  'printf "%s\n" "$PPID" > "$lock/owner"' > "$TEST_FLOCK"
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
    AGENT_OS_TEST_LOCK_ROOT="$TEST_LOCK_ROOT" AGENT_OS_TEST_BOUND_PATHS=true "$SYNC"
}

fleet_mutation_signature() {
  local id gitdir policy
  for id in linked standalone; do
    gitdir=$(git -C "$TMP/$id" rev-parse --absolute-git-dir)
    printf '%s:%s:%s\n' "$id" "$(git -C "$TMP/$id" rev-parse HEAD)" \
      "$(git -C "$TMP/$id" remote get-url origin)"
    for policy in "$gitdir/agent-os-runtime-source" \
      "$TMP/$id/config/agent-os-source-policy" \
      "$TMP/$id/config/agent-os-source-policy.pending" \
      "$TMP/$id/config/agent-os-source-policy.required"; do
      if [ -f "$policy" ]; then
        printf '%s:%s\n' "$policy" "$(shasum -a 256 "$policy" | awk '{print $1}')"
      else
        printf '%s:absent\n' "$policy"
      fi
    done
  done
  if [ -d "$TMP/foreign-guard/.git" ]; then
    printf 'foreign-guard:%s:%s\n' "$(git -C "$TMP/foreign-guard" rev-parse HEAD)" \
      "$(git -C "$TMP/foreign-guard" remote get-url origin)"
    if [ -f "$TMP/foreign-guard/.git/agent-os-runtime-source" ]; then
      shasum -a 256 "$TMP/foreign-guard/.git/agent-os-runtime-source"
    else
      printf 'foreign-guard-policy:absent\n'
    fi
  fi
}

expect_rejection_without_mutation() {
  local label=$1 before after
  before=$(fleet_mutation_signature)
  if run_sync "$TMP/primary-b" "$B_COMMIT" "$B_TREE" "$B_SHA" >/dev/null 2>&1; then
    fail "$label was accepted"
  fi
  after=$(fleet_mutation_signature)
  [ "$after" = "$before" ] || fail "$label allowed source, remote, marker, or policy mutation"
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

git clone -q "$LEASE" "$TMP/foreign-guard"
git -C "$TMP/foreign-guard" checkout -q --detach "$A_COMMIT"

write_treehouse_state
PRESERVE_TREEHOUSE_STATE=true
jq 'del(.worktrees[] | select(.lease_holder == "standalone"))' \
  "$TREEHOUSE_POOL/treehouse-state.json" > "$TEST_ROOT/state-next.json"
mv "$TEST_ROOT/state-next.json" "$TREEHOUSE_POOL/treehouse-state.json"
run_sync "$TMP/primary-b" "$B_COMMIT" "$B_TREE" "$B_SHA" >/dev/null || \
  fail "primary-owned standalone assignment required Treehouse self-attestation"
run_sync "$TMP/primary-a" "$A_COMMIT" "$A_TREE" "$A_SHA" >/dev/null || \
  fail "primary-owned standalone assignment could not select its rollback source"
pass "primary-owned standalone assignment needs no child or Treehouse attestation"

mv "$FM_HOME_DIR/state/standalone.meta" "$TEST_ROOT/standalone.meta"
printf -- '- standalone - standby (home: %s/standalone; state: idle)\n' "$TMP" \
  > "$FM_HOME_DIR/data/secondmates.md"
expect_rejection_without_mutation "registry-only standalone self-attestation"
mv "$TEST_ROOT/standalone.meta" "$FM_HOME_DIR/state/standalone.meta"
: > "$FM_HOME_DIR/data/secondmates.md"
pass "standalone assignment requires primary-owned proof"

write_treehouse_state
jq 'del(.worktrees[] | select(.lease_holder == "linked"))' \
  "$TREEHOUSE_POOL/treehouse-state.json" > "$TEST_ROOT/state-next.json"
mv "$TEST_ROOT/state-next.json" "$TREEHOUSE_POOL/treehouse-state.json"
expect_rejection_without_mutation "missing Treehouse lease evidence"

write_treehouse_state
jq '(.worktrees[] | select(.lease_holder == "linked") | .leased) = false' \
  "$TREEHOUSE_POOL/treehouse-state.json" > "$TEST_ROOT/state-next.json"
mv "$TEST_ROOT/state-next.json" "$TREEHOUSE_POOL/treehouse-state.json"
expect_rejection_without_mutation "stale Treehouse lease evidence"

write_treehouse_state
jq '(.worktrees[] | select(.lease_holder == "linked") | .lease_holder) = "other"' \
  "$TREEHOUSE_POOL/treehouse-state.json" > "$TEST_ROOT/state-next.json"
mv "$TEST_ROOT/state-next.json" "$TREEHOUSE_POOL/treehouse-state.json"
expect_rejection_without_mutation "other-holder Treehouse lease evidence"

write_treehouse_state
jq '.worktrees += [.worktrees[] | select(.lease_holder == "linked")]' \
  "$TREEHOUSE_POOL/treehouse-state.json" > "$TEST_ROOT/state-next.json"
mv "$TEST_ROOT/state-next.json" "$TREEHOUSE_POOL/treehouse-state.json"
expect_rejection_without_mutation "duplicate Treehouse lease evidence"

write_treehouse_state
jq '.worktrees += [(.worktrees[] | select(.lease_holder == "linked") | .path += "-planted")]' \
  "$TREEHOUSE_POOL/treehouse-state.json" > "$TEST_ROOT/state-next.json"
mv "$TEST_ROOT/state-next.json" "$TREEHOUSE_POOL/treehouse-state.json"
expect_rejection_without_mutation "ambiguous planted Treehouse holder evidence"

printf '{unreadable\n' > "$TREEHOUSE_POOL/treehouse-state.json"
expect_rejection_without_mutation "unreadable Treehouse lease evidence"
PRESERVE_TREEHOUSE_STATE=false
write_treehouse_state
pass "secondmate selection requires one exact active Treehouse lease holder"

git clone -q "$LEASE" "$TMP/toctou-foreign"
git -C "$TMP/toctou-foreign" checkout -q --detach "$A_COMMIT"
linked_gitdir=$(git -C "$TMP/linked" rev-parse --absolute-git-dir)
linked_commondir=$(cat "$linked_gitdir/commondir")
linked_pointer=$(cat "$TMP/linked/.git")
foreign_before=$(find "$TMP/toctou-foreign/.git" -type f -print0 | sort -z | \
  xargs -0 shasum -a 256 | shasum -a 256 | awk '{print $1}')
fleet_before=$(fleet_mutation_signature)
write_treehouse_state
PRESERVE_TREEHOUSE_STATE=true
AGENT_OS_TEST_BARRIER_PHASE=fetch
AGENT_OS_TEST_BARRIER_READY="$TEST_ROOT/toctou-ready"
AGENT_OS_TEST_BARRIER_RELEASE="$TEST_ROOT/toctou-release"
export AGENT_OS_TEST_BARRIER_PHASE AGENT_OS_TEST_BARRIER_READY AGENT_OS_TEST_BARRIER_RELEASE
rm -f "$AGENT_OS_TEST_BARRIER_READY" "$AGENT_OS_TEST_BARRIER_RELEASE"
run_sync "$TMP/primary-b" "$B_COMMIT" "$B_TREE" "$B_SHA" \
  > "$TEST_ROOT/toctou-runtime.out" 2>&1 &
runtime_pid=$!
for _ in $(seq 1 500); do
  [ -f "$AGENT_OS_TEST_BARRIER_READY" ] && break
  sleep 0.01
done
[ -f "$AGENT_OS_TEST_BARRIER_READY" ] || {
  kill "$runtime_pid" 2>/dev/null || true
  fail "runtime TOCTOU barrier was not reached"
}
if AGENT_OS_TEST_BARRIER_PHASE= run_sync "$TMP/primary-b" "$B_COMMIT" "$B_TREE" "$B_SHA" \
  >/dev/null 2>&1; then
  touch "$AGENT_OS_TEST_BARRIER_RELEASE"
  wait "$runtime_pid" 2>/dev/null || true
  fail "secondmate ownership lock admitted a concurrent runtime mutation"
fi
printf 'gitdir: %s/toctou-foreign/.git\n' "$TMP" > "$TMP/linked/.git"
printf '%s\n' "$TMP/toctou-foreign/.git" > "$linked_gitdir/commondir"
touch "$AGENT_OS_TEST_BARRIER_RELEASE"
if wait "$runtime_pid"; then
  fail "runtime accepted a Git pointer and common-directory swap"
fi
printf '%s\n' "$linked_pointer" > "$TMP/linked/.git"
printf '%s\n' "$linked_commondir" > "$linked_gitdir/commondir"
unset AGENT_OS_TEST_BARRIER_PHASE AGENT_OS_TEST_BARRIER_READY AGENT_OS_TEST_BARRIER_RELEASE
foreign_after=$(find "$TMP/toctou-foreign/.git" -type f -print0 | sort -z | \
  xargs -0 shasum -a 256 | shasum -a 256 | awk '{print $1}')
[ "$foreign_after" = "$foreign_before" ] || \
  fail "runtime TOCTOU redirected Git mutation into a foreign repository"
[ "$(fleet_mutation_signature)" = "$fleet_before" ] || \
  fail "runtime TOCTOU changed secondmate source, remote, marker, or policy state"
PRESERVE_TREEHOUSE_STATE=false
write_treehouse_state
pass "runtime lock and bound common directory defeat live Git pointer swaps"

printf 'tampered\n' >> "$TMP/standalone/AGENTS.md"
if run_sync "$TMP/primary-b" "$B_COMMIT" "$B_TREE" "$B_SHA" >/dev/null 2>&1; then
  fail "dirty secondmate source was replaced"
fi
[ "$(git -C "$TMP/standalone" rev-parse HEAD)" = "$A_COMMIT" ] || \
  fail "dirty secondmate source moved"
pass "dirty secondmate source fails closed"

echo "# all Agent OS runtime secondmate tests passed"
