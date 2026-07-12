#!/usr/bin/env bash
# User-namespace verification and persistent tool seeding tests.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP=$(fm_test_tmproot agent-os-init)
mkdir -p "$TMP/source/bin" "$TMP/persistent/.local/bin" "$TMP/persistent/usr-local/bin"
printf 'baseline\n' > "$TMP/source/bin/baseline"
printf 'runtime\n' > "$TMP/persistent/usr-local/bin/runtime-added"

AGENT_OS_IMAGE_USR_LOCAL="$TMP/source" \
AGENT_OS_PERSISTENT_ROOT="$TMP/persistent" \
  "$ROOT/bin/agent-os-init.sh"

assert_grep baseline "$TMP/persistent/usr-local/bin/baseline" "initializer must seed image tools"
assert_grep runtime "$TMP/persistent/usr-local/bin/runtime-added" "initializer must preserve runtime tools"

for directory in .config .cache .local/bin .local/share .bun .cargo usr-local; do
  [ -d "$TMP/persistent/$directory" ] || fail "initializer must create persistent $directory"
done

pass "initializer preserves image and runtime-installed tools"
