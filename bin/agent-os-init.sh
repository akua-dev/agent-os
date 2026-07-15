#!/usr/bin/env bash
# Seed PVC-backed runtime tool paths before the agent container starts.
set -eu

PERSISTENT_ROOT=${AGENT_OS_PERSISTENT_ROOT:-/persistent-agent}
IMAGE_MANIFEST=${AGENT_OS_IMAGE_MANIFEST:-/opt/agent-os-image-usr-local.manifest}
IMAGE_MANIFEST_SIGNATURE=${AGENT_OS_IMAGE_MANIFEST_SIGNATURE:-/opt/agent-os-image-usr-local.manifest.sha256}
MANIFEST_DIR="$PERSISTENT_ROOT/.config/agent-os"
LEGACY_ROOT="$PERSISTENT_ROOT/usr-local"

mkdir -p \
  "$PERSISTENT_ROOT/.config" \
  "$PERSISTENT_ROOT/.cache" \
  "$PERSISTENT_ROOT/.local/bin" \
  "$PERSISTENT_ROOT/.local/share" \
  "$PERSISTENT_ROOT/.pi/agent" \
  "$PERSISTENT_ROOT/.bun" \
  "$PERSISTENT_ROOT/.cargo" \
  "$MANIFEST_DIR"

(cd "$(dirname "$IMAGE_MANIFEST")" && sha256sum -c "$(basename "$IMAGE_MANIFEST_SIGNATURE")" >/dev/null) || {
  echo "error: image-owned /usr/local manifest signature is invalid" >&2
  exit 2
}

if [ -d "$LEGACY_ROOT" ] && find "$LEGACY_ROOT" -mindepth 1 -print -quit | grep -q .; then
  previous_manifest="$MANIFEST_DIR/previous-image-usr-local.manifest"
  previous_signature="$MANIFEST_DIR/previous-image-usr-local.manifest.sha256"
  if [ ! -f "$previous_manifest" ] || [ ! -f "$previous_signature" ] || \
    ! (cd "$MANIFEST_DIR" && sha256sum -c "$(basename "$previous_signature")" >/dev/null); then
    echo "error: legacy persistent /usr/local ownership is ambiguous; migration refused" >&2
    exit 2
  fi
  while IFS= read -r path; do
    relative=".${path#"$LEGACY_ROOT"}"
    expected=$(awk -v path="$relative" '$2 == path { print $1 }' "$previous_manifest")
    [ -n "$expected" ] || { echo "error: legacy persistent /usr/local contains unowned path '$relative'" >&2; exit 2; }
    actual=$(sha256sum "$path" | awk '{print $1}')
    [ "$actual" = "$expected" ] || { echo "error: legacy persistent /usr/local path '$relative' changed; migration refused" >&2; exit 2; }
  done < <(find "$LEGACY_ROOT" \( -type f -o -type l \) -print)
  find "$LEGACY_ROOT" \( -type f -o -type l \) -delete
  find "$LEGACY_ROOT" -depth -type d -empty -delete
  if [ -e "$LEGACY_ROOT" ]; then
    echo "error: legacy persistent /usr/local contains unsupported or unowned state" >&2
    exit 2
  fi
fi

install -m 0600 "$IMAGE_MANIFEST" "$MANIFEST_DIR/previous-image-usr-local.manifest"
(cd "$MANIFEST_DIR" && sha256sum previous-image-usr-local.manifest > previous-image-usr-local.manifest.sha256)
