#!/usr/bin/env bash
# Verify Pod user-namespace isolation and seed PVC-backed runtime tool paths.
set -eu

UID_MAP=${AGENT_OS_UID_MAP_PATH:-/proc/self/uid_map}
IMAGE_USR_LOCAL=${AGENT_OS_IMAGE_USR_LOCAL:-/opt/image-usr-local}
PERSISTENT_ROOT=${AGENT_OS_PERSISTENT_ROOT:-/persistent-agent}

inside=
outside=
length=
read -r inside outside length _ < "$UID_MAP" || {
  echo "error: cannot read user namespace map from $UID_MAP" >&2
  exit 1
}

case "$inside:$outside:$length" in
  *[!0-9:]*|'')
    echo "error: invalid user namespace map in $UID_MAP" >&2
    exit 1
    ;;
esac

if [ "$inside" -ne 0 ] || [ "$outside" -le 0 ] || [ "$length" -lt 65536 ]; then
  echo "error: Agent OS requires remapped container root; got '$inside $outside $length'" >&2
  exit 1
fi

mkdir -p \
  "$PERSISTENT_ROOT/.config" \
  "$PERSISTENT_ROOT/.cache" \
  "$PERSISTENT_ROOT/.local/bin" \
  "$PERSISTENT_ROOT/.local/share" \
  "$PERSISTENT_ROOT/.bun" \
  "$PERSISTENT_ROOT/.cargo" \
  "$PERSISTENT_ROOT/usr-local"

rsync -a "$IMAGE_USR_LOCAL/" "$PERSISTENT_ROOT/usr-local/"
