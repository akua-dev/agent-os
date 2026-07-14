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

[[ "$SOURCE_COMMIT" =~ ^[0-9a-f]{40}$ ]] || exit 2
[[ "$SOURCE_TREE" =~ ^[0-9a-f]{40}$ ]] || exit 2
[[ "$SOURCE_SHA" =~ ^[0-9a-f]{64}$ ]] || exit 2
case "$SOURCE_MODE" in candidate|release) ;; *) exit 2 ;; esac
[ -x "$GIT_BIN" ] || exit 2

trusted_git() {
  env -i HOME=/nonexistent PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 \
    "$GIT_BIN" -c credential.helper= -c core.hooksPath=/dev/null \
    -c http.proxy= -c https.proxy= "$@"
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
  local root=$1 expected backlink backlink_path relative
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

ids=()
homes=()
add_home() {
  local id=$1 home=$2
  [ -n "$id" ] && [ -n "$home" ] || return 0
  case "$id" in *[!A-Za-z0-9._-]*|.|..) echo "error: secondmate id is invalid" >&2; exit 2 ;; esac
  case "$home" in /*) ;; *) echo "error: secondmate home is not absolute" >&2; exit 2 ;; esac
  ids+=("$id")
  homes+=("$home")
}

for meta in "$FM_HOME"/state/*.meta; do
  [ -f "$meta" ] || continue
  [ "$(sed -n 's/^kind=//p' "$meta")" = secondmate ] || continue
  id=${meta##*/}
  id=${id%.meta}
  add_home "$id" "$(sed -n 's/^home=//p' "$meta")"
done
if [ -f "$FM_HOME/data/secondmates.md" ]; then
  while IFS= read -r line; do
    case "$line" in '- '*) ;; *) continue ;; esac
    id=$(printf '%s\n' "$line" | sed -n 's/^- \([^ ][^ ]*\) - .*/\1/p')
    add_home "$id" "$(printf '%s\n' "$line" | sed -n 's/.*(home:[[:space:]]*\([^;]*\);.*/\1/p' | sed 's/[[:space:]]*$//')"
  done < "$FM_HOME/data/secondmates.md"
fi

[ "$(trusted_git -C "$FM_ROOT" rev-parse HEAD)" = "$SOURCE_COMMIT" ] || exit 2
[ "$(trusted_git -C "$FM_ROOT" rev-parse 'HEAD^{tree}')" = "$SOURCE_TREE" ] || exit 2
[ -z "$(trusted_git -C "$FM_ROOT" status --porcelain --untracked-files=all)" ] || exit 2

validated_ids=()
validated_homes=()
git_dirs=()
seen_homes=$'\n'
for index in "${!homes[@]}"; do
  id=${ids[$index]}
  home=${homes[$index]}
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
  resolve_git_metadata "$home" || { echo "error: secondmate Git metadata is invalid: $home" >&2; exit 2; }
  validate_git_binding "$home" || {
    echo "error: secondmate Git metadata is not bound to its home: $home" >&2
    exit 2
  }
  validate_config "$RESOLVED_COMMON_DIR/config" || {
    echo "error: secondmate Git configuration is invalid: $home" >&2
    exit 2
  }
  [ -z "$(trusted_git -C "$home" status --porcelain --untracked-files=all)" ] || {
    echo "error: secondmate source is not clean: $home" >&2
    exit 2
  }
  git_policy="$RESOLVED_GIT_DIR/agent-os-runtime-source"
  home_policy="$home/config/agent-os-source-policy"
  required_policy="$home/config/agent-os-source-policy.required"
  pending_policy="$home/config/agent-os-source-policy.pending"
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
  elif [ -e "$required_policy" ]; then
    if ! { [ -e "$git_policy" ] && [ -e "$home_policy" ] && \
      cmp "$git_policy" "$home_policy"; }; then
      echo "error: secondmate immutable policy is incomplete: $home" >&2
      exit 2
    fi
  else
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
  validated_ids+=("$id")
  validated_homes+=("$home")
  git_dirs+=("$RESOLVED_GIT_DIR")
done

marker="mode=$SOURCE_MODE
commit=$SOURCE_COMMIT
source_sha256=$SOURCE_SHA"
for index in "${!validated_homes[@]}"; do
  home=${validated_homes[$index]}
  git_dir=${git_dirs[$index]}
  trusted_git -c protocol.file.allow=always -C "$home" fetch --no-tags "$FM_ROOT" "$SOURCE_COMMIT"
  [ "$(trusted_git -C "$home" rev-parse FETCH_HEAD)" = "$SOURCE_COMMIT" ] || exit 2
  [ "$(trusted_git -C "$home" rev-parse 'FETCH_HEAD^{tree}')" = "$SOURCE_TREE" ] || exit 2
  mkdir -p "$home/config"
  pending_policy="$home/config/agent-os-source-policy.pending"
  pending_tmp="$home/config/.agent-os-source-policy.pending.$$"
  printf '%s\n' "$marker" > "$pending_tmp"
  mv "$pending_tmp" "$pending_policy"
  required_policy="$home/config/agent-os-source-policy.required"
  required_tmp="$home/config/.agent-os-source-policy.required.$$"
  printf 'immutable\n' > "$required_tmp"
  mv "$required_tmp" "$required_policy"
  trusted_git -C "$home" checkout --detach "$SOURCE_COMMIT"
  trusted_git -C "$home" remote set-url origin "$SOURCE_ORIGIN"
  home_marker_tmp="$home/config/.agent-os-source-policy.$$"
  printf '%s\n' "$marker" > "$home_marker_tmp"
  mv "$home_marker_tmp" "$home/config/agent-os-source-policy"
  marker_tmp="$git_dir/agent-os-runtime-source.$$"
  printf '%s\n' "$marker" > "$marker_tmp"
  mv "$marker_tmp" "$git_dir/agent-os-runtime-source"
  cmp "$home/config/agent-os-source-policy" "$git_dir/agent-os-runtime-source" || exit 2
  [ "$(trusted_git -C "$home" rev-parse HEAD)" = "$SOURCE_COMMIT" ] || exit 2
  [ "$(trusted_git -C "$home" rev-parse 'HEAD^{tree}')" = "$SOURCE_TREE" ] || exit 2
  [ -z "$(trusted_git -C "$home" status --porcelain --untracked-files=all)" ] || exit 2
  rm "$pending_policy"
  printf 'selected: %s\n' "$home"
done
