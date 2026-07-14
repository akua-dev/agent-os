#!/usr/bin/env bash
set -eu
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

FM_HOME=${FM_HOME:?FM_HOME is required}
FM_ROOT=${FM_ROOT_OVERRIDE:?FM_ROOT_OVERRIDE is required}
SOURCE_COMMIT=${AGENT_OS_SOURCE_COMMIT:?AGENT_OS_SOURCE_COMMIT is required}
SOURCE_TREE=${AGENT_OS_SOURCE_TREE:?AGENT_OS_SOURCE_TREE is required}
SOURCE_SHA=${AGENT_OS_SOURCE_SHA256:?AGENT_OS_SOURCE_SHA256 is required}
SOURCE_BRANCH=${AGENT_OS_SOURCE_BRANCH:?AGENT_OS_SOURCE_BRANCH is required}
SOURCE_ORIGIN=${AGENT_OS_SOURCE_ORIGIN:?AGENT_OS_SOURCE_ORIGIN is required}
SOURCE_MODE=${AGENT_OS_SOURCE_MODE:?AGENT_OS_SOURCE_MODE is required}
GIT_BIN=/usr/bin/git
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SUB_HOME_MARKER=.fm-secondmate-home
# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"
# shellcheck source=bin/agent-os-runtime-bound.sh
. "$SCRIPT_DIR/agent-os-runtime-bound.sh"

[[ "$SOURCE_COMMIT" =~ ^[0-9a-f]{40}$ ]] || exit 2
[[ "$SOURCE_TREE" =~ ^[0-9a-f]{40}$ ]] || exit 2
[[ "$SOURCE_SHA" =~ ^[0-9a-f]{64}$ ]] || exit 2
case "$SOURCE_MODE" in candidate|release) ;; *) exit 2 ;; esac
[ -x "$GIT_BIN" ] || exit 2

trusted_git() {
  local common_dir=
  if [ "${1:-}" = --agent-os-common-dir ]; then
    common_dir=${2:?bound common Git directory is required}
    shift 2
    [ -d "$common_dir" ] && [ ! -L "$common_dir" ] || return 1
  fi
  if [ -n "$common_dir" ]; then
    env -i HOME=/nonexistent PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
      GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 \
      GIT_COMMON_DIR="$common_dir" \
      "$GIT_BIN" -c credential.helper= -c core.hooksPath=/dev/null \
      -c http.proxy= -c https.proxy= "$@"
  else
    env -i HOME=/nonexistent PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
      GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 \
      "$GIT_BIN" -c credential.helper= -c core.hooksPath=/dev/null \
      -c http.proxy= -c https.proxy= "$@"
  fi
}

resolve_treehouse_pool() {
  local home=$1 parent pool
  parent=$(cd "$home/.." 2>/dev/null && pwd -P) || return 1
  pool=$(cd "$parent/.." 2>/dev/null && pwd -P) || return 1
  [ -f "$pool/treehouse-state.json" ] && [ ! -L "$pool/treehouse-state.json" ] || return 1
  [ -f "$pool/treehouse-state.lock" ] && [ ! -L "$pool/treehouse-state.lock" ] || return 1
  RESOLVED_TREEHOUSE_POOL=$pool
}

acquire_treehouse_lock() {
  local pool=$1 flock_bin lock_file fd_root
  flock_bin=/usr/bin/flock
  if [ ! -x "$flock_bin" ]; then
    flock_bin=${AGENT_OS_TEST_FLOCK_BIN:-}
  fi
  [ -x "$flock_bin" ] || return 1
  lock_file=$pool/treehouse-state.lock
  exec {TREEHOUSE_LOCK_FD}<>"$lock_file" || return 1
  if [ -e "/proc/self/fd/$TREEHOUSE_LOCK_FD" ]; then
    fd_root=/proc/self/fd
    TREEHOUSE_LOCK_HANDLE=$fd_root/$TREEHOUSE_LOCK_FD
  elif [ "$flock_bin" = "${AGENT_OS_TEST_FLOCK_BIN:-}" ]; then
    TREEHOUSE_LOCK_HANDLE=$lock_file
  else
    return 1
  fi
  [ "$lock_file" -ef "$TREEHOUSE_LOCK_HANDLE" ] || return 1
  AGENT_OS_TEST_LOCK_FILE_HINT="$lock_file" "$flock_bin" -x "$TREEHOUSE_LOCK_FD" || return 1
  [ "$lock_file" -ef "$TREEHOUSE_LOCK_HANDLE" ] || return 1
  TREEHOUSE_LOCK_FILE=$lock_file
  TREEHOUSE_POOL=$pool
}

acquire_primary_ownership_lock() {
  local flock_bin lock_file fd_root
  flock_bin=/usr/bin/flock
  if [ ! -x "$flock_bin" ]; then
    flock_bin=${AGENT_OS_TEST_FLOCK_BIN:-}
  fi
  [ -x "$flock_bin" ] || return 1
  lock_file=$FM_HOME/state/agent-os-runtime-secondmates.lock
  [ -d "$FM_HOME/state" ] && [ ! -L "$FM_HOME/state" ] || return 1
  if [ -e "$lock_file" ]; then
    [ -f "$lock_file" ] && [ ! -L "$lock_file" ] || return 1
  else
    : > "$lock_file" || return 1
  fi
  exec {PRIMARY_OWNERSHIP_LOCK_FD}<>"$lock_file" || return 1
  if [ -e "/proc/self/fd/$PRIMARY_OWNERSHIP_LOCK_FD" ]; then
    fd_root=/proc/self/fd
    PRIMARY_OWNERSHIP_LOCK_HANDLE=$fd_root/$PRIMARY_OWNERSHIP_LOCK_FD
  elif [ "$flock_bin" = "${AGENT_OS_TEST_FLOCK_BIN:-}" ]; then
    PRIMARY_OWNERSHIP_LOCK_HANDLE=$lock_file
  else
    return 1
  fi
  [ "$lock_file" -ef "$PRIMARY_OWNERSHIP_LOCK_HANDLE" ] || return 1
  AGENT_OS_TEST_LOCK_FILE_HINT="$lock_file" "$flock_bin" -x "$PRIMARY_OWNERSHIP_LOCK_FD" || return 1
  [ "$lock_file" -ef "$PRIMARY_OWNERSHIP_LOCK_HANDLE" ] || return 1
  PRIMARY_OWNERSHIP_LOCK_FILE=$lock_file
}

validate_treehouse_lease() {
  local id=$1 state_home=$2 home=$3 state state_json entry_count index entry_home canonical_count
  state=$TREEHOUSE_POOL/treehouse-state.json
  [ "$TREEHOUSE_LOCK_FILE" -ef "$TREEHOUSE_LOCK_HANDLE" ] || return 1
  [ -r "$state" ] && [ -f "$state" ] && [ ! -L "$state" ] || return 1
  state_json=$(cat "$state") || return 1
  jq -e --arg home "$state_home" --arg holder "$id" '
    (.worktrees | type == "array") and
    (all(.worktrees[]; (.path | type == "string" and test("^[^\\t\\r\\n]+$")))) and
    ([.worktrees[] | select(.path == $home)] | length == 1) and
    ([.worktrees[] | select(.leased == true and .lease_holder == $holder)] | length == 1) and
    ([.worktrees[] | select(
      .path == $home and .leased == true and .lease_holder == $holder and
      ((.destroying // false) == false) and ((.owner_pid // 0) == 0) and
      ((.owner_started_at // 0) == 0) and (.name | type == "string" and length > 0) and
      (.leased_at | type == "string" and length > 0)
    )] | length == 1)' <<< "$state_json" >/dev/null || return 1
  entry_count=$(jq -er '.worktrees | length' <<< "$state_json") || return 1
  canonical_count=0
  index=0
  while [ "$index" -lt "$entry_count" ]; do
    entry_home=$(jq -er --argjson index "$index" '.worktrees[$index].path' <<< "$state_json") || return 1
    entry_home=$(cd "$entry_home" 2>/dev/null && pwd -P) || return 1
    [ "$entry_home" != "$home" ] || canonical_count=$((canonical_count + 1))
    index=$((index + 1))
  done
  [ "$canonical_count" -eq 1 ]
}

resolve_git_metadata() {
  local root=$1 pointer common
  if [ -d "$root/.git" ] && [ ! -L "$root/.git" ]; then
    RESOLVED_GIT_DIR=$(cd "$root/.git" && pwd -P)
  elif [ -f "$root/.git" ] && [ ! -L "$root/.git" ]; then
    [ "$(wc -l < "$root/.git" | tr -d ' ')" -eq 1 ] || return 1
    pointer=$(sed -n 's/^gitdir: //p' "$root/.git")
    [ -n "$pointer" ] || return 1
    case "$pointer" in
      /*) RESOLVED_GIT_DIR=$(cd "$pointer" 2>/dev/null && pwd -P) || return 1 ;;
      *) RESOLVED_GIT_DIR=$(cd "$root/$(dirname "$pointer")" 2>/dev/null && printf '%s/%s\n' "$(pwd -P)" "$(basename "$pointer")") || return 1 ;;
    esac
  else
    return 1
  fi
  RESOLVED_COMMON_DIR=$RESOLVED_GIT_DIR
  if [ -f "$RESOLVED_GIT_DIR/commondir" ] && [ ! -L "$RESOLVED_GIT_DIR/commondir" ]; then
    [ "$(wc -l < "$RESOLVED_GIT_DIR/commondir" | tr -d ' ')" -eq 1 ] || return 1
    common=$(cat "$RESOLVED_GIT_DIR/commondir")
    case "$common" in
      /*) RESOLVED_COMMON_DIR=$(cd "$common" 2>/dev/null && pwd -P) || return 1 ;;
      *) RESOLVED_COMMON_DIR=$(cd "$RESOLVED_GIT_DIR/$common" 2>/dev/null && pwd -P) || return 1 ;;
    esac
  fi
}

resolve_file_path() {
  local path=$1 parent
  parent=$(cd "$(dirname "$path")" 2>/dev/null && pwd -P) || return 1
  printf '%s/%s\n' "$parent" "$(basename "$path")"
}

validate_git_binding() {
  local root=$1 expected backlink backlink_path relative runtime_root source_root source_key policy_commit policy_sha
  expected=$(resolve_file_path "$root/.git") || return 1
  if [ -d "$root/.git" ] && [ ! -L "$root/.git" ]; then
    [ "$RESOLVED_GIT_DIR" = "$expected" ] || return 1
    [ "$RESOLVED_COMMON_DIR" = "$RESOLVED_GIT_DIR" ] || return 1
    return 0
  fi
  [ -f "$root/.git" ] && [ ! -L "$root/.git" ] || return 1
  [ -f "$RESOLVED_GIT_DIR/gitdir" ] && [ ! -L "$RESOLVED_GIT_DIR/gitdir" ] || return 1
  [ "$(wc -l < "$RESOLVED_GIT_DIR/gitdir" | tr -d ' ')" -eq 1 ] || return 1
  backlink=$(cat "$RESOLVED_GIT_DIR/gitdir")
  case "$backlink" in
    /*) backlink_path=$(resolve_file_path "$backlink") || return 1 ;;
    *) backlink_path=$(resolve_file_path "$RESOLVED_GIT_DIR/$backlink") || return 1 ;;
  esac
  [ "$backlink_path" = "$expected" ] || return 1
  case "$RESOLVED_GIT_DIR" in
    "$RESOLVED_COMMON_DIR"/worktrees/*) ;;
    *) return 1 ;;
  esac
  relative=${RESOLVED_GIT_DIR#"$RESOLVED_COMMON_DIR"/worktrees/}
  case "$relative" in ''|*/*) return 1 ;; esac
  [ -d "$RESOLVED_COMMON_DIR" ] && [ ! -L "$RESOLVED_COMMON_DIR" ] || return 1
  runtime_root=$(cd "$FM_HOME/runtime-sources" 2>/dev/null && pwd -P) || return 1
  source_root=$(cd "$RESOLVED_COMMON_DIR/.." 2>/dev/null && pwd -P) || return 1
  case "$source_root" in "$runtime_root"/*) ;; *) return 1 ;; esac
  source_key=${source_root#"$runtime_root"/}
  case "$source_key" in ''|*/*) return 1 ;; esac
  [ "$RESOLVED_COMMON_DIR" = "$source_root/.git" ] || return 1
  validate_policy "$RESOLVED_COMMON_DIR/agent-os-runtime-source" || return 1
  policy_commit=$(sed -n 's/^commit=//p' "$RESOLVED_COMMON_DIR/agent-os-runtime-source")
  policy_sha=$(sed -n 's/^source_sha256=//p' "$RESOLVED_COMMON_DIR/agent-os-runtime-source")
  [ "$source_key" = "$policy_commit-$policy_sha" ]
}

validate_bound_git_binding() {
  local root=$1 bound_home=$2 bound_git=$3 bound_common=$4 bound_source=$5 linked=$6 source_key=$7
  local pointer pointer_path backlink backlink_path common common_path matches source_key policy_commit policy_sha
  [ "$PRIMARY_OWNERSHIP_LOCK_FILE" -ef "$PRIMARY_OWNERSHIP_LOCK_HANDLE" ] || return 1
  if [ "$linked" = false ]; then
    [ -d "$bound_home/.git" ] && [ ! -L "$bound_home/.git" ] || return 1
    [ "$bound_home/.git" -ef "$bound_git" ] || return 1
    [ "$bound_git" -ef "$bound_common" ] || return 1
    [ "$bound_home" -ef "$bound_source" ] || return 1
    return 0
  fi
  [ -f "$bound_home/.git" ] && [ ! -L "$bound_home/.git" ] || return 1
  [ "$(wc -l < "$bound_home/.git" | tr -d ' ')" -eq 1 ] || return 1
  pointer=$(sed -n 's/^gitdir: //p' "$bound_home/.git")
  [ -n "$pointer" ] || return 1
  case "$pointer" in
    /*) pointer_path=$pointer ;;
    *) pointer_path="$bound_home/$pointer" ;;
  esac
  [ "$pointer_path" -ef "$bound_git" ] || return 1
  [ -f "$bound_git/gitdir" ] && [ ! -L "$bound_git/gitdir" ] || return 1
  [ "$(wc -l < "$bound_git/gitdir" | tr -d ' ')" -eq 1 ] || return 1
  backlink=$(cat "$bound_git/gitdir")
  case "$backlink" in
    /*) backlink_path=$backlink ;;
    *) backlink_path="$bound_git/$backlink" ;;
  esac
  [ "$backlink_path" -ef "$bound_home/.git" ] || return 1
  [ -f "$bound_git/commondir" ] && [ ! -L "$bound_git/commondir" ] || return 1
  [ "$(wc -l < "$bound_git/commondir" | tr -d ' ')" -eq 1 ] || return 1
  common=$(cat "$bound_git/commondir")
  case "$common" in
    /*) common_path=$common ;;
    *) common_path="$bound_git/$common" ;;
  esac
  [ "$common_path" -ef "$bound_common" ] || return 1
  matches=0
  for pointer_path in "$bound_common"/worktrees/*; do
    [ -d "$pointer_path" ] || continue
    [ "$pointer_path" -ef "$bound_git" ] && matches=$((matches + 1))
  done
  [ "$matches" -eq 1 ] || return 1
  [ "$bound_source/.git" -ef "$bound_common" ] || return 1
  validate_policy "$bound_common/agent-os-runtime-source" || return 1
  policy_commit=$(sed -n 's/^commit=//p' "$bound_common/agent-os-runtime-source")
  policy_sha=$(sed -n 's/^source_sha256=//p' "$bound_common/agent-os-runtime-source")
  [ "$source_key" = "$policy_commit-$policy_sha" ]
}

validate_primary_standalone_proof() {
  local id=$1 home=$2 meta recorded_home
  meta=$FM_HOME/state/$id.meta
  [ "$PRIMARY_OWNERSHIP_LOCK_FILE" -ef "$PRIMARY_OWNERSHIP_LOCK_HANDLE" ] || return 1
  [ -f "$meta" ] && [ ! -L "$meta" ] && [ -r "$meta" ] || return 1
  [ "$(grep -c '^kind=secondmate$' "$meta")" -eq 1 ] || return 1
  [ "$(grep -c '^home=' "$meta")" -eq 1 ] || return 1
  recorded_home=$(sed -n 's/^home=//p' "$meta")
  [ -d "$recorded_home" ] && [ ! -L "$recorded_home" ] || return 1
  recorded_home=$(cd "$recorded_home" && pwd -P) || return 1
  [ "$recorded_home" = "$home" ]
}

validate_config() {
  local config=$1 section='' line key value token seen=''
  [ -f "$config" ] && [ ! -L "$config" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*|';'*) continue ;;
      '[core]') section=core; continue ;;
      '[remote "origin"]') section=remote.origin; continue ;;
      "[branch \"$SOURCE_BRANCH\"]") section="branch.$SOURCE_BRANCH"; continue ;;
      '['*) return 1 ;;
    esac
    case "$line" in *=*) ;; *) return 1 ;; esac
    key=${line%%=*}
    value=${line#*=}
    key=$(printf '%s' "$key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    value=$(printf '%s' "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    token="$section.$key"
    case "|$seen|" in *"|$token|"*) return 1 ;; esac
    case "$token" in
      core.repositoryformatversion) [ "$value" = 0 ] ;;
      core.filemode) [ "$value" = true ] || [ "$value" = false ] ;;
      core.bare) [ "$value" = false ] ;;
      core.logallrefupdates) [ "$value" = true ] ;;
      core.ignorecase) [ "$value" = true ] || [ "$value" = false ] ;;
      core.precomposeunicode) [ "$value" = true ] || [ "$value" = false ] ;;
      remote.origin.url) [ -n "$value" ] ;;
      remote.origin.fetch) [ -n "$value" ] ;;
      "branch.$SOURCE_BRANCH.remote") [ "$value" = origin ] ;;
      "branch.$SOURCE_BRANCH.merge") [ "$value" = "refs/heads/$SOURCE_BRANCH" ] ;;
      *) return 1 ;;
    esac || return 1
    seen="${seen:+$seen|}$token"
  done < "$config"
  for token in core.repositoryformatversion core.filemode core.bare core.logallrefupdates \
    remote.origin.url remote.origin.fetch; do
    case "|$seen|" in *"|$token|"*) ;; *) return 1 ;; esac
  done
}

validate_policy() {
  local policy=$1 policy_mode policy_commit policy_sha
  [ -f "$policy" ] && [ ! -L "$policy" ] || return 1
  policy_mode=$(sed -n 's/^mode=//p' "$policy")
  policy_commit=$(sed -n 's/^commit=//p' "$policy")
  policy_sha=$(sed -n 's/^source_sha256=//p' "$policy")
  case "$policy_mode" in candidate|release) ;; *) return 1 ;; esac
  [[ "$policy_commit" =~ ^[0-9a-f]{40}$ ]] || return 1
  [[ "$policy_sha" =~ ^[0-9a-f]{64}$ ]] || return 1
  [ "$(wc -l < "$policy" | tr -d ' ')" -eq 3 ]
}

trusted_tree_entry() {
  local git_dir=$1 common_dir=$2 home=$3 commit=$4 path=$5 entry
  entry=$(agent_os_bound_git "$git_dir" "$common_dir" "$home" ls-tree "$commit" -- "$path") || return 1
  printf '%s' "$entry" | awk 'NR == 1 { print $1 " " $3 }'
}

worktree_entry() {
  local git_dir=$1 common_dir=$2 home=$3 path=$4 mode hash
  if [ -L "$home/$path" ]; then
    mode=120000
    hash=$(printf '%s' "$(readlink "$home/$path")" | agent_os_bound_git "$git_dir" "$common_dir" "$home" hash-object --stdin)
  elif [ -f "$home/$path" ]; then
    if [ -x "$home/$path" ]; then mode=100755; else mode=100644; fi
    hash=$(agent_os_bound_git "$git_dir" "$common_dir" "$home" hash-object -- "$home/$path")
  elif [ ! -e "$home/$path" ]; then
    printf '\n'
    return 0
  else
    return 1
  fi
  printf '%s %s\n' "$mode" "$hash"
}

entry_matches_transition() {
  local git_dir=$1 common_dir=$2 home=$3 path=$4 actual=$5 commit expected
  shift 5
  for commit in "$@"; do
    expected=$(trusted_tree_entry "$git_dir" "$common_dir" "$home" "$commit" "$path") || return 1
    [ "$actual" = "$expected" ] && return 0
  done
  return 1
}

verify_pending_checkout() {
  local git_dir=$1 common_dir=$2 home=$3 pending=$4 current_commit pending_commit record path worktree index index_entries status_file valid
  current_commit=$(agent_os_bound_git "$git_dir" "$common_dir" "$home" rev-parse HEAD) || return 1
  pending_commit=$(sed -n 's/^commit=//p' "$pending")
  agent_os_bound_git "$git_dir" "$common_dir" "$home" rev-parse "$pending_commit^{commit}" >/dev/null || return 1
  status_file=$(mktemp "${TMPDIR:-/tmp}/agent-os-secondmate-status.XXXXXX") || return 1
  if ! agent_os_bound_git "$git_dir" "$common_dir" "$home" -c status.renames=false status \
    --porcelain=v1 -z --untracked-files=all > "$status_file"; then
    rm -f "$status_file"
    return 1
  fi
  RECOVERY_PATHS=()
  valid=true
  while IFS= read -r -d '' record; do
    path=${record:3}
    if [ -z "$path" ]; then valid=false; break; fi
    worktree=$(worktree_entry "$git_dir" "$common_dir" "$home" "$path") || { valid=false; break; }
    entry_matches_transition "$git_dir" "$common_dir" "$home" "$path" "$worktree" \
      "$current_commit" "$pending_commit" "$SOURCE_COMMIT" || { valid=false; break; }
    index_entries=$(agent_os_bound_git "$git_dir" "$common_dir" "$home" ls-files -s -- "$path") || { valid=false; break; }
    index=$(printf '%s' "$index_entries" | awk '
      NR == 1 { entry=$1 " " $2 }
      END { if (NR <= 1) print entry; else exit 1 }
    ') || { valid=false; break; }
    entry_matches_transition "$git_dir" "$common_dir" "$home" "$path" "$index" \
      "$current_commit" "$pending_commit" "$SOURCE_COMMIT" || { valid=false; break; }
    RECOVERY_PATHS+=("$path")
  done < "$status_file"
  rm -f "$status_file"
  [ "$valid" = true ]
}

recover_pending_checkout() {
  local git_dir=$1 common_dir=$2 home=$3 pending=$4 old_head path
  verify_pending_checkout "$git_dir" "$common_dir" "$home" "$pending" || return 1
  old_head=$(agent_os_bound_git "$git_dir" "$common_dir" "$home" rev-parse HEAD) || return 1
  agent_os_bound_git "$git_dir" "$common_dir" "$home" restore --source="$SOURCE_COMMIT" --staged --worktree -- .
  for path in "${RECOVERY_PATHS[@]}"; do
    if [ -z "$(trusted_tree_entry "$git_dir" "$common_dir" "$home" "$SOURCE_COMMIT" "$path")" ] && \
      { [ -f "$home/$path" ] || [ -L "$home/$path" ]; }; then
      rm -f -- "$home/$path"
    fi
  done
  agent_os_bound_git "$git_dir" "$common_dir" "$home" update-ref --no-deref HEAD "$SOURCE_COMMIT" "$old_head"
  [ -z "$(agent_os_bound_git "$git_dir" "$common_dir" "$home" status --porcelain --untracked-files=all)" ]
}

ids=()
homes=()
proofs=()
add_home() {
  local id=$1 home=$2 proof=$3
  [ -n "$id" ] && [ -n "$home" ] || return 0
  case "$id" in *[!A-Za-z0-9._-]*|.|..) echo "error: secondmate id is invalid" >&2; exit 2 ;; esac
  case "$home" in /*) ;; *) echo "error: secondmate home is not absolute" >&2; exit 2 ;; esac
  ids+=("$id")
  homes+=("$home")
  proofs+=("$proof")
}

for meta in "$FM_HOME"/state/*.meta; do
  [ -f "$meta" ] || continue
  [ "$(sed -n 's/^kind=//p' "$meta")" = secondmate ] || continue
  id=${meta##*/}
  id=${id%.meta}
  add_home "$id" "$(sed -n 's/^home=//p' "$meta")" primary-meta
done
if [ -f "$FM_HOME/data/secondmates.md" ]; then
  while IFS= read -r line; do
    case "$line" in '- '*) ;; *) continue ;; esac
    id=$(printf '%s\n' "$line" | sed -n 's/^- \([^ ][^ ]*\) - .*/\1/p')
    add_home "$id" "$(printf '%s\n' "$line" | sed -n 's/.*(home:[[:space:]]*\([^;]*\);.*/\1/p' | sed 's/[[:space:]]*$//')" registry
  done < "$FM_HOME/data/secondmates.md"
fi

[ "$(trusted_git -C "$FM_ROOT" rev-parse HEAD)" = "$SOURCE_COMMIT" ] || exit 2
[ "$(trusted_git -C "$FM_ROOT" rev-parse 'HEAD^{tree}')" = "$SOURCE_TREE" ] || exit 2
[ -z "$(trusted_git -C "$FM_ROOT" status --porcelain --untracked-files=all)" ] || exit 2
acquire_primary_ownership_lock || {
  echo "error: primary secondmate ownership lock is unavailable" >&2
  exit 2
}

validated_ids=()
validated_homes=()
treehouse_homes=()
ownership_modes=()
git_dirs=()
common_dirs=()
source_dirs=()
bound_homes=()
bound_configs=()
bound_git_dirs=()
bound_common_dirs=()
bound_source_dirs=()
pending_policies=()
seen_homes=$'\n'
for index in "${!homes[@]}"; do
  id=${ids[$index]}
  home=${homes[$index]}
  proof=${proofs[$index]}
  treehouse_home=$home
  validate_secondmate_home "$id" "$home" || {
    echo "error: invalid secondmate home for $id: $VALIDATION_ERROR" >&2
    exit 2
  }
  home=$VALIDATED_HOME
  duplicate=false
  for prior in "${!validated_homes[@]}"; do
    prior_home=${validated_homes[$prior]}
    prior_id=${validated_ids[$prior]}
    if [ "$home" = "$prior_home" ]; then
      [ "$id" = "$prior_id" ] || {
        echo "error: secondmate home is registered to multiple identities: $home" >&2
        exit 2
      }
      duplicate=true
      break
    fi
    if [ "$id" = "$prior_id" ]; then
      echo "error: secondmate identity is registered to multiple homes: $id" >&2
      exit 2
    fi
    if path_is_ancestor_of "$home" "$prior_home" || path_is_ancestor_of "$prior_home" "$home"; then
      echo "error: secondmate homes overlap: $home and $prior_home" >&2
      exit 2
    fi
  done
  [ "$duplicate" = false ] || continue
  case "$seen_homes" in *$'\n'"$home"$'\n'*) continue ;; esac
  seen_homes+="$home"$'\n'
  if [ -d "$home/.git" ] && [ ! -L "$home/.git" ]; then
    ownership_mode=primary-standalone
    if [ "$proof" != primary-meta ] || ! validate_primary_standalone_proof "$id" "$home"; then
      echo "error: standalone secondmate lacks exact primary-owned assignment proof: $id" >&2
      exit 2
    fi
  else
    ownership_mode=treehouse
    resolve_treehouse_pool "$home" || {
      echo "error: secondmate Treehouse state is unavailable: $home" >&2
      exit 2
    }
    if [ -z "${TREEHOUSE_POOL:-}" ]; then
      acquire_treehouse_lock "$RESOLVED_TREEHOUSE_POOL" || {
        echo "error: secondmate Treehouse ownership lock is unavailable: $home" >&2
        exit 2
      }
    elif [ "$TREEHOUSE_POOL" != "$RESOLVED_TREEHOUSE_POOL" ]; then
      echo "error: secondmate homes do not share one authoritative Treehouse pool" >&2
      exit 2
    fi
    validate_treehouse_lease "$id" "$treehouse_home" "$home" || {
      echo "error: secondmate Treehouse lease holder is not exact: $id" >&2
      exit 2
    }
  fi
  resolve_git_metadata "$home" || { echo "error: secondmate Git metadata is invalid: $home" >&2; exit 2; }
  original_git_dir=$RESOLVED_GIT_DIR
  original_common_dir=$RESOLVED_COMMON_DIR
  if [ "$ownership_mode" = treehouse ]; then
    original_source_dir=$(cd "$original_common_dir/.." && pwd -P) || exit 2
    runtime_root=$(cd "$FM_HOME/runtime-sources" && pwd -P) || exit 2
    case "$original_source_dir" in "$runtime_root"/*) ;; *) exit 2 ;; esac
    source_key=${original_source_dir#"$runtime_root"/}
    case "$source_key" in ''|*/*) exit 2 ;; esac
  else
    original_source_dir=$home
    source_key=${original_source_dir##*/}
  fi
  agent_os_open_bound_dir "$home" || {
    echo "error: secondmate home cannot be bound for mutation: $home" >&2
    exit 2
  }
  bound_home=$AGENT_OS_BOUND_PATH
  agent_os_open_bound_dir "$home/config" || {
    echo "error: secondmate configuration directory cannot be bound for mutation: $home" >&2
    exit 2
  }
  bound_config=$AGENT_OS_BOUND_PATH
  agent_os_open_bound_dir "$original_git_dir" || {
    echo "error: secondmate Git directory cannot be bound for mutation: $home" >&2
    exit 2
  }
  bound_git_dir=$AGENT_OS_BOUND_PATH
  agent_os_open_bound_dir "$original_common_dir" || {
    echo "error: secondmate common Git directory cannot be bound for mutation: $home" >&2
    exit 2
  }
  bound_common_dir=$AGENT_OS_BOUND_PATH
  agent_os_open_bound_dir "$original_source_dir" || {
    echo "error: secondmate source directory cannot be bound for mutation: $home" >&2
    exit 2
  }
  bound_source_dir=$AGENT_OS_BOUND_PATH
  if ! { agent_os_bound_dir_matches "$home" "$bound_home" && \
    agent_os_bound_dir_matches "$home/config" "$bound_config" && \
    agent_os_bound_dir_matches "$original_git_dir" "$bound_git_dir" && \
    agent_os_bound_dir_matches "$original_common_dir" "$bound_common_dir" && \
    agent_os_bound_dir_matches "$original_source_dir" "$bound_source_dir"; }; then
    echo "error: secondmate ownership changed while binding: $home" >&2
    exit 2
  fi
  validate_bound_git_binding "$home" "$bound_home" "$bound_git_dir" \
    "$bound_common_dir" "$bound_source_dir" "$([ "$ownership_mode" = treehouse ] && printf true || printf false)" \
    "$source_key" || {
    echo "error: bound secondmate Git ownership is invalid: $home" >&2
    exit 2
  }
  validate_config "$bound_common_dir/config" || {
    echo "error: secondmate Git configuration is invalid: $home" >&2
    exit 2
  }
  if [ "$ownership_mode" = treehouse ]; then
    common_commit=$(sed -n 's/^commit=//p' "$bound_common_dir/agent-os-runtime-source")
    [ "$(agent_os_bound_git "$bound_common_dir" "$bound_common_dir" "$bound_source_dir" rev-parse HEAD)" = "$common_commit" ] && \
      [ -z "$(agent_os_bound_git "$bound_common_dir" "$bound_common_dir" "$bound_source_dir" status --porcelain --untracked-files=all)" ] || {
      echo "error: secondmate linked Git ownership is invalid: $home" >&2
      exit 2
    }
  fi
  git_policy="$bound_git_dir/agent-os-runtime-source"
  home_policy="$bound_config/agent-os-source-policy"
  required_policy="$bound_config/agent-os-source-policy.required"
  pending_policy="$bound_config/agent-os-source-policy.pending"
  for policy in "$git_policy" "$home_policy"; do
    if [ -e "$policy" ]; then
      validate_policy "$policy" || {
        echo "error: secondmate immutable policy is invalid: $home" >&2
        exit 2
      }
    fi
  done
  if [ -e "$required_policy" ]; then
    [ -f "$required_policy" ] && [ ! -L "$required_policy" ] && \
      [ "$(cat "$required_policy")" = immutable ] || {
      echo "error: secondmate immutable policy requirement is invalid: $home" >&2
      exit 2
    }
  fi
  if [ -e "$pending_policy" ]; then
    validate_policy "$pending_policy" || {
      echo "error: secondmate immutable policy journal is invalid: $home" >&2
      exit 2
    }
    selected_pending=$pending_policy
  elif [ -e "$required_policy" ]; then
    selected_pending=
    if ! { [ -e "$git_policy" ] && [ -e "$home_policy" ] && \
      cmp "$git_policy" "$home_policy"; }; then
      echo "error: secondmate immutable policy is incomplete: $home" >&2
      exit 2
    fi
  else
    selected_pending=
    if [ -e "$home_policy" ] && [ ! -e "$git_policy" ]; then
      echo "error: secondmate immutable policy is incomplete: $home" >&2
      exit 2
    fi
    if [ -e "$git_policy" ] && [ -e "$home_policy" ]; then
      cmp "$git_policy" "$home_policy" || {
        echo "error: secondmate immutable policies do not match: $home" >&2
        exit 2
      }
    fi
  fi
  if [ -z "$selected_pending" ] && \
    [ -n "$(agent_os_bound_git "$bound_git_dir" "$bound_common_dir" "$bound_home" status --porcelain --untracked-files=all)" ]; then
    echo "error: secondmate source is not clean: $home" >&2
    exit 2
  fi
  validated_ids+=("$id")
  validated_homes+=("$home")
  treehouse_homes+=("$treehouse_home")
  ownership_modes+=("$ownership_mode")
  git_dirs+=("$original_git_dir")
  common_dirs+=("$original_common_dir")
  source_dirs+=("$original_source_dir")
  bound_homes+=("$bound_home")
  bound_configs+=("$bound_config")
  bound_git_dirs+=("$bound_git_dir")
  bound_common_dirs+=("$bound_common_dir")
  bound_source_dirs+=("$bound_source_dir")
  pending_policies+=("$selected_pending")
done

assert_secondmate_binding() {
  local id=$1 ownership_mode=$2 treehouse_home=$3 home=$4 git_dir=$5 common_dir=$6 source_dir=$7
  local bound_home=$8 bound_config=$9 bound_git=${10} bound_common=${11} bound_source=${12}
  if [ "$ownership_mode" = treehouse ]; then
    validate_treehouse_lease "$id" "$treehouse_home" "$home" || return 1
  else
    validate_primary_standalone_proof "$id" "$home" || return 1
  fi
  agent_os_bound_dir_matches "$home" "$bound_home" || return 1
  agent_os_bound_dir_matches "$home/config" "$bound_config" || return 1
  agent_os_bound_dir_matches "$git_dir" "$bound_git" || return 1
  agent_os_bound_dir_matches "$common_dir" "$bound_common" || return 1
  agent_os_bound_dir_matches "$source_dir" "$bound_source" || return 1
  resolve_git_metadata "$home" || return 1
  [ "$RESOLVED_GIT_DIR" -ef "$bound_git" ] || return 1
  [ "$RESOLVED_COMMON_DIR" -ef "$bound_common" ] || return 1
  validate_bound_git_binding "$home" "$bound_home" "$bound_git" "$bound_common" \
    "$bound_source" "$([ "$ownership_mode" = treehouse ] && printf true || printf false)" \
    "${source_dir##*/}"
}

runtime_test_barrier() {
  local phase=$1
  [ "${AGENT_OS_BOUND_TEST_FALLBACK_ACTIVE:-}" = true ] || return 0
  [ "${AGENT_OS_TEST_BARRIER_PHASE:-}" = "$phase" ] || return 0
  [ -n "${AGENT_OS_TEST_BARRIER_READY:-}" ] && [ -n "${AGENT_OS_TEST_BARRIER_RELEASE:-}" ] || return 1
  printf '%s\n' "$$" > "$AGENT_OS_TEST_BARRIER_READY"
  while [ ! -e "$AGENT_OS_TEST_BARRIER_RELEASE" ]; do
    /bin/sleep 0.01
  done
}

marker="mode=$SOURCE_MODE
commit=$SOURCE_COMMIT
source_sha256=$SOURCE_SHA"
for index in "${!validated_homes[@]}"; do
  id=${validated_ids[$index]}
  ownership_mode=${ownership_modes[$index]}
  treehouse_home=${treehouse_homes[$index]}
  home=${validated_homes[$index]}
  git_dir=${git_dirs[$index]}
  common_dir=${common_dirs[$index]}
  source_dir=${source_dirs[$index]}
  bound_home=${bound_homes[$index]}
  bound_config=${bound_configs[$index]}
  bound_git_dir=${bound_git_dirs[$index]}
  bound_common_dir=${bound_common_dirs[$index]}
  bound_source_dir=${bound_source_dirs[$index]}
  recovery_policy=${pending_policies[$index]}
  assert_secondmate_binding "$id" "$ownership_mode" "$treehouse_home" "$home" "$git_dir" \
    "$common_dir" "$source_dir" "$bound_home" "$bound_config" "$bound_git_dir" \
    "$bound_common_dir" "$bound_source_dir" || {
    echo "error: secondmate ownership changed before mutation: $home" >&2
    exit 2
  }
  runtime_test_barrier fetch
  agent_os_bound_git "$bound_git_dir" "$bound_common_dir" "$bound_home" -c protocol.file.allow=always \
    fetch --no-tags "$FM_ROOT" "$SOURCE_COMMIT"
  [ "$(agent_os_bound_git "$bound_git_dir" "$bound_common_dir" "$bound_home" rev-parse FETCH_HEAD)" = "$SOURCE_COMMIT" ] || exit 2
  [ "$(agent_os_bound_git "$bound_git_dir" "$bound_common_dir" "$bound_home" rev-parse 'FETCH_HEAD^{tree}')" = "$SOURCE_TREE" ] || exit 2
  if [ -n "$recovery_policy" ] && \
    [ -n "$(agent_os_bound_git "$bound_git_dir" "$bound_common_dir" "$bound_home" status --porcelain --untracked-files=all)" ]; then
    recovery_policy="$bound_config/agent-os-source-policy.pending"
    recover_pending_checkout "$bound_git_dir" "$bound_common_dir" "$bound_home" "$recovery_policy" || {
      echo "error: secondmate immutable policy journal cannot recover source: $home" >&2
      exit 2
    }
  fi
  assert_secondmate_binding "$id" "$ownership_mode" "$treehouse_home" "$home" "$git_dir" \
    "$common_dir" "$source_dir" "$bound_home" "$bound_config" "$bound_git_dir" \
    "$bound_common_dir" "$bound_source_dir" || exit 2
  runtime_test_barrier policy
  pending_policy="$bound_config/agent-os-source-policy.pending"
  pending_tmp="$bound_config/.agent-os-source-policy.pending.$$"
  printf '%s\n' "$marker" > "$pending_tmp"
  mv "$pending_tmp" "$pending_policy"
  required_policy="$bound_config/agent-os-source-policy.required"
  required_tmp="$bound_config/.agent-os-source-policy.required.$$"
  printf 'immutable\n' > "$required_tmp"
  mv "$required_tmp" "$required_policy"
  assert_secondmate_binding "$id" "$ownership_mode" "$treehouse_home" "$home" "$git_dir" \
    "$common_dir" "$source_dir" "$bound_home" "$bound_config" "$bound_git_dir" \
    "$bound_common_dir" "$bound_source_dir" || exit 2
  runtime_test_barrier checkout
  agent_os_bound_git "$bound_git_dir" "$bound_common_dir" "$bound_home" checkout --detach "$SOURCE_COMMIT"
  runtime_test_barrier remote
  agent_os_bound_git "$bound_git_dir" "$bound_common_dir" "$bound_home" remote set-url origin "$SOURCE_ORIGIN"
  assert_secondmate_binding "$id" "$ownership_mode" "$treehouse_home" "$home" "$git_dir" \
    "$common_dir" "$source_dir" "$bound_home" "$bound_config" "$bound_git_dir" \
    "$bound_common_dir" "$bound_source_dir" || exit 2
  runtime_test_barrier marker
  home_marker_tmp="$bound_config/.agent-os-source-policy.$$"
  printf '%s\n' "$marker" > "$home_marker_tmp"
  mv "$home_marker_tmp" "$bound_config/agent-os-source-policy"
  marker_tmp="$bound_git_dir/agent-os-runtime-source.$$"
  printf '%s\n' "$marker" > "$marker_tmp"
  mv "$marker_tmp" "$bound_git_dir/agent-os-runtime-source"
  cmp "$bound_config/agent-os-source-policy" "$bound_git_dir/agent-os-runtime-source" || exit 2
  [ "$(agent_os_bound_git "$bound_git_dir" "$bound_common_dir" "$bound_home" rev-parse HEAD)" = "$SOURCE_COMMIT" ] || exit 2
  [ "$(agent_os_bound_git "$bound_git_dir" "$bound_common_dir" "$bound_home" rev-parse 'HEAD^{tree}')" = "$SOURCE_TREE" ] || exit 2
  [ -z "$(agent_os_bound_git "$bound_git_dir" "$bound_common_dir" "$bound_home" status --porcelain --untracked-files=all)" ] || exit 2
  assert_secondmate_binding "$id" "$ownership_mode" "$treehouse_home" "$home" "$git_dir" \
    "$common_dir" "$source_dir" "$bound_home" "$bound_config" "$bound_git_dir" \
    "$bound_common_dir" "$bound_source_dir" || exit 2
  rm "$pending_policy"
  printf 'selected: %s\n' "$home"
done
