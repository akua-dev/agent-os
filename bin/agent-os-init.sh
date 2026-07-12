#!/usr/bin/env bash
# Seed PVC-backed runtime tool paths before the agent container starts.
set -eu

IMAGE_USR_LOCAL=${AGENT_OS_IMAGE_USR_LOCAL:-/opt/image-usr-local}
PERSISTENT_ROOT=${AGENT_OS_PERSISTENT_ROOT:-/persistent-agent}

mkdir -p \
  "$PERSISTENT_ROOT/.config" \
  "$PERSISTENT_ROOT/.cache" \
  "$PERSISTENT_ROOT/.local/bin" \
  "$PERSISTENT_ROOT/.local/share" \
  "$PERSISTENT_ROOT/.bun" \
  "$PERSISTENT_ROOT/.cargo" \
  "$PERSISTENT_ROOT/usr-local"

rsync -a "$IMAGE_USR_LOCAL/" "$PERSISTENT_ROOT/usr-local/"
