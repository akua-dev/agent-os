#!/usr/bin/env bash
# User-namespace verification and persistent tool seeding tests.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP=$(fm_test_tmproot agent-os-init)
mkdir -p "$TMP/source/bin" "$TMP/persistent/.local/bin" "$TMP/persistent/usr-local/bin"
printf '0 100000 65536\n' > "$TMP/mapped"
printf '0 0 4294967295\n' > "$TMP/host"
printf 'baseline\n' > "$TMP/source/bin/baseline"
printf 'runtime\n' > "$TMP/persistent/usr-local/bin/runtime-added"

AGENT_OS_UID_MAP_PATH="$TMP/mapped" \
AGENT_OS_IMAGE_USR_LOCAL="$TMP/source" \
AGENT_OS_PERSISTENT_ROOT="$TMP/persistent" \
  "$ROOT/bin/agent-os-init.sh"

assert_grep baseline "$TMP/persistent/usr-local/bin/baseline" "initializer must seed image tools"
assert_grep runtime "$TMP/persistent/usr-local/bin/runtime-added" "initializer must preserve runtime tools"

for directory in .config .cache .local/bin .local/share .bun .cargo usr-local; do
  [ -d "$TMP/persistent/$directory" ] || fail "initializer must create persistent $directory"
done

if AGENT_OS_UID_MAP_PATH="$TMP/host" \
  AGENT_OS_IMAGE_USR_LOCAL="$TMP/source" \
  AGENT_OS_PERSISTENT_ROOT="$TMP/persistent" \
  "$ROOT/bin/agent-os-init.sh" >/dev/null 2>&1; then
  fail "initializer must reject the host user namespace"
fi

pass "initializer verifies remapping and preserves persistent tools"
