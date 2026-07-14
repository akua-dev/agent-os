#!/usr/bin/env bash
set -eu

FM_HOME=${FM_HOME:?FM_HOME is required}
IMAGE_SOURCE=${AGENT_OS_IMAGE_SOURCE:?AGENT_OS_IMAGE_SOURCE is required}
SOURCE_COMMIT=${AGENT_OS_SOURCE_COMMIT:?AGENT_OS_SOURCE_COMMIT is required}
SOURCE_TREE=${AGENT_OS_SOURCE_TREE:?AGENT_OS_SOURCE_TREE is required}
SOURCE_SHA=${AGENT_OS_SOURCE_SHA256:?AGENT_OS_SOURCE_SHA256 is required}
SOURCE_BRANCH=${AGENT_OS_SOURCE_BRANCH:?AGENT_OS_SOURCE_BRANCH is required}
SOURCE_ORIGIN=${AGENT_OS_SOURCE_ORIGIN:?AGENT_OS_SOURCE_ORIGIN is required}
SOURCE_MODE=${AGENT_OS_SOURCE_MODE:?AGENT_OS_SOURCE_MODE is required}
GIT_BIN=/usr/bin/git

[[ "$SOURCE_COMMIT" =~ ^[0-9a-f]{40}$ ]] || { echo "error: immutable source commit is invalid" >&2; exit 2; }
[[ "$SOURCE_TREE" =~ ^[0-9a-f]{40}$ ]] || { echo "error: immutable source tree is invalid" >&2; exit 2; }
[[ "$SOURCE_SHA" =~ ^[0-9a-f]{64}$ ]] || { echo "error: immutable source digest is invalid" >&2; exit 2; }
case "$SOURCE_MODE" in candidate|release) ;; *) echo "error: runtime source mode is not immutable" >&2; exit 2 ;; esac
[ -x "$GIT_BIN" ] || { echo "error: trusted Git executable is unavailable" >&2; exit 2; }

trusted_git() {
  env -i HOME=/nonexistent PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 \
    "$GIT_BIN" -c credential.helper= -c core.hooksPath=/dev/null \
    -c http.proxy= -c https.proxy= "$@"
}

runtime_root="$FM_HOME/runtime-sources"
key="$SOURCE_COMMIT-$SOURCE_SHA"
target="$runtime_root/$key"
lock="$runtime_root/.$key.materializing"
marker="mode=$SOURCE_MODE
commit=$SOURCE_COMMIT
source_sha256=$SOURCE_SHA"

validate_source() {
  local root=$1 actual_marker
  [ -d "$root/.git" ] || { echo "error: immutable runtime source Git metadata is unavailable" >&2; return 1; }
  [ "$(trusted_git -C "$root" rev-parse HEAD)" = "$SOURCE_COMMIT" ] || return 1
  [ "$(trusted_git -C "$root" rev-parse 'HEAD^{tree}')" = "$SOURCE_TREE" ] || return 1
  [ "$(trusted_git -C "$root" symbolic-ref --quiet --short HEAD)" = "$SOURCE_BRANCH" ] || return 1
  [ "$(trusted_git -C "$root" remote get-url origin)" = "$SOURCE_ORIGIN" ] || return 1
  [ -z "$(trusted_git -C "$root" status --porcelain --untracked-files=all)" ] || return 1
  [ -f "$root/.git/agent-os-runtime-source" ] || return 1
  actual_marker=$(cat "$root/.git/agent-os-runtime-source")
  [ "$actual_marker" = "$marker" ] || return 1
  ! find "$root/.git/hooks" -mindepth 1 -print -quit 2>/dev/null | grep -q . || return 1
}

mkdir -p "$runtime_root"
if [ -e "$target" ]; then
  validate_source "$target" || { echo "error: immutable runtime source failed exact verification" >&2; exit 2; }
  rmdir "$lock" 2>/dev/null || true
  printf '%s\n' "$target"
  exit 0
fi

if ! mkdir "$lock" 2>/dev/null; then
  if [ -e "$target" ] && validate_source "$target"; then
    printf '%s\n' "$target"
    exit 0
  fi
  echo "error: partial immutable runtime source materialization requires recovery" >&2
  exit 2
fi

partial="$lock/source"
if ! trusted_git -c protocol.file.allow=always clone --no-local --branch "$SOURCE_BRANCH" "$IMAGE_SOURCE" "$partial"; then
  echo "error: immutable runtime source materialization failed" >&2
  exit 2
fi
trusted_git -C "$partial" remote set-url origin "$SOURCE_ORIGIN"
rm -rf "$partial/.git/hooks"
printf '%s\n' "$marker" > "$partial/.git/agent-os-runtime-source"
validate_source "$partial" || { echo "error: materialized immutable runtime source failed exact verification" >&2; exit 2; }
mv "$partial" "$target"
rmdir "$lock"
validate_source "$target" || { echo "error: committed immutable runtime source failed exact verification" >&2; exit 2; }
printf '%s\n' "$target"
