#!/usr/bin/env bash
set -eu

FM_HOME=${FM_HOME:?FM_HOME is required}
FM_ROOT=${FM_ROOT_OVERRIDE:?FM_ROOT_OVERRIDE is required}
SOURCE_COMMIT=${AGENT_OS_SOURCE_COMMIT:?AGENT_OS_SOURCE_COMMIT is required}
SOURCE_TREE=${AGENT_OS_SOURCE_TREE:?AGENT_OS_SOURCE_TREE is required}
SOURCE_SHA=${AGENT_OS_SOURCE_SHA256:?AGENT_OS_SOURCE_SHA256 is required}
SOURCE_BRANCH=${AGENT_OS_SOURCE_BRANCH:?AGENT_OS_SOURCE_BRANCH is required}
SOURCE_ORIGIN=${AGENT_OS_SOURCE_ORIGIN:?AGENT_OS_SOURCE_ORIGIN is required}
SOURCE_MODE=${AGENT_OS_SOURCE_MODE:?AGENT_OS_SOURCE_MODE is required}
GIT_BIN=/usr/bin/git

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

homes=()
seen=$'\n'
add_home() {
  local home=$1
  [ -n "$home" ] || return 0
  case "$home" in /*) ;; *) echo "error: secondmate home is not absolute" >&2; exit 2 ;; esac
  case "$seen" in *$'\n'"$home"$'\n'*) return 0 ;; esac
  seen+="$home"$'\n'
  homes+=("$home")
}

for meta in "$FM_HOME"/state/*.meta; do
  [ -f "$meta" ] || continue
  [ "$(sed -n 's/^kind=//p' "$meta")" = secondmate ] || continue
  add_home "$(sed -n 's/^home=//p' "$meta")"
done
if [ -f "$FM_HOME/data/secondmates.md" ]; then
  while IFS= read -r line; do
    case "$line" in '- '*) ;; *) continue ;; esac
    add_home "$(printf '%s\n' "$line" | sed -n 's/.*(home:[[:space:]]*\([^;]*\);.*/\1/p' | sed 's/[[:space:]]*$//')"
  done < "$FM_HOME/data/secondmates.md"
fi

[ "$(trusted_git -C "$FM_ROOT" rev-parse HEAD)" = "$SOURCE_COMMIT" ] || exit 2
[ "$(trusted_git -C "$FM_ROOT" rev-parse 'HEAD^{tree}')" = "$SOURCE_TREE" ] || exit 2
[ -z "$(trusted_git -C "$FM_ROOT" status --porcelain --untracked-files=all)" ] || exit 2

git_dirs=()
for home in "${homes[@]}"; do
  [ "$(cd "$home" 2>/dev/null && pwd -P)" != "$(cd "$FM_ROOT" && pwd -P)" ] || continue
  [ -f "$home/.fm-secondmate-home" ] && [ ! -L "$home/.fm-secondmate-home" ] || {
    echo "error: secondmate home lacks exact provenance marker: $home" >&2
    exit 2
  }
  resolve_git_metadata "$home" || { echo "error: secondmate Git metadata is invalid: $home" >&2; exit 2; }
  validate_config "$RESOLVED_COMMON_DIR/config" || {
    echo "error: secondmate Git configuration is invalid: $home" >&2
    exit 2
  }
  [ -z "$(trusted_git -C "$home" status --porcelain --untracked-files=all)" ] || {
    echo "error: secondmate source is not clean: $home" >&2
    exit 2
  }
  git_dirs+=("$RESOLVED_GIT_DIR")
done

marker="mode=$SOURCE_MODE
commit=$SOURCE_COMMIT
source_sha256=$SOURCE_SHA"
index=0
for home in "${homes[@]}"; do
  [ "$(cd "$home" 2>/dev/null && pwd -P)" != "$(cd "$FM_ROOT" && pwd -P)" ] || continue
  git_dir=${git_dirs[$index]}
  index=$((index + 1))
  trusted_git -c protocol.file.allow=always -C "$home" fetch --no-tags "$FM_ROOT" "$SOURCE_COMMIT"
  [ "$(trusted_git -C "$home" rev-parse FETCH_HEAD)" = "$SOURCE_COMMIT" ] || exit 2
  [ "$(trusted_git -C "$home" rev-parse 'FETCH_HEAD^{tree}')" = "$SOURCE_TREE" ] || exit 2
  trusted_git -C "$home" checkout --detach "$SOURCE_COMMIT"
  trusted_git -C "$home" remote set-url origin "$SOURCE_ORIGIN"
  marker_tmp="$git_dir/agent-os-runtime-source.$$"
  printf '%s\n' "$marker" > "$marker_tmp"
  mv "$marker_tmp" "$git_dir/agent-os-runtime-source"
  [ "$(trusted_git -C "$home" rev-parse HEAD)" = "$SOURCE_COMMIT" ] || exit 2
  [ "$(trusted_git -C "$home" rev-parse 'HEAD^{tree}')" = "$SOURCE_TREE" ] || exit 2
  [ -z "$(trusted_git -C "$home" status --porcelain --untracked-files=all)" ] || exit 2
  printf 'selected: %s\n' "$home"
done
