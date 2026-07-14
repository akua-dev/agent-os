#!/usr/bin/env bash
# User-namespace verification and persistent tool seeding tests.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP=$(fm_test_tmproot agent-os-init)
mkdir -p "$TMP/image" "$TMP/persistent/.local/bin"
printf 'image-manifest\n' > "$TMP/image/manifest"
(cd "$TMP/image" && sha256sum manifest > manifest.sha256)

AGENT_OS_IMAGE_MANIFEST="$TMP/image/manifest" \
AGENT_OS_IMAGE_MANIFEST_SIGNATURE="$TMP/image/manifest.sha256" \
AGENT_OS_PERSISTENT_ROOT="$TMP/persistent" "$ROOT/bin/agent-os-init.sh"

for directory in .config .cache .local/bin .local/share .bun .cargo; do
  [ -d "$TMP/persistent/$directory" ] || fail "initializer must create persistent $directory"
done
assert_grep image-manifest "$TMP/persistent/.config/agent-os/previous-image-usr-local.manifest" \
  "initializer must persist authenticated image ownership provenance"

mkdir -p "$TMP/ambiguous/usr-local/bin"
printf 'unknown\n' > "$TMP/ambiguous/usr-local/bin/tool"
if AGENT_OS_IMAGE_MANIFEST="$TMP/image/manifest" \
  AGENT_OS_IMAGE_MANIFEST_SIGNATURE="$TMP/image/manifest.sha256" \
  AGENT_OS_PERSISTENT_ROOT="$TMP/ambiguous" "$ROOT/bin/agent-os-init.sh" >/dev/null 2>&1; then
  fail "initializer must reject ambiguous legacy /usr/local ownership"
fi

pass "initializer separates immutable image tools from persistent user tools"
