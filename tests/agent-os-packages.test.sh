#!/usr/bin/env bash
# Static contracts for the optional Akua packages used by Agent OS.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FIRSTMATE="$ROOT/tools/agent-os/packages/firstmate"

[ -f "$FIRSTMATE/package.k" ] || fail "firstmate package must exist"
[ -f "$FIRSTMATE/inputs.example.yaml" ] || fail "firstmate example inputs must exist"

assert_grep 'ghcr.io/akua-dev/agent-os:latest' "$FIRSTMATE/package.k" \
  "firstmate package must default to the public Agent OS image"
assert_grep 'kind = "StatefulSet"' "$FIRSTMATE/package.k" \
  "firstmate package must create a restartable controller"
assert_grep 'kind = "PersistentVolumeClaim"' "$FIRSTMATE/package.k" \
  "firstmate package must persist its home"
assert_grep 'kind = "ServiceAccount"' "$FIRSTMATE/package.k" \
  "firstmate package must create its cluster identity"
assert_grep 'name = "cluster-admin"' "$FIRSTMATE/package.k" \
  "dedicated intelligence clusters must support the explicit Firstmate admin grant"
assert_grep 'akuaAuthSecret: str = ""' "$FIRSTMATE/package.k" \
  "Akua workspace access must be an explicit Secret reference"
assert_grep 'mountPath = "/var/run/secrets/agent-os/akua"' "$FIRSTMATE/package.k" \
  "Akua authorization material must use a runtime Secret mount"
assert_grep 'readOnly = True' "$FIRSTMATE/package.k" \
  "Akua authorization material must be mounted read-only"
assert_grep 'herdr", "status", "--json"' "$FIRSTMATE/package.k" \
  "Firstmate readiness must prove the Herdr server is responsive"
assert_grep 'mountPath = "/usr/local"' "$FIRSTMATE/package.k" \
  "Firstmate-installed tools must persist"
assert_no_grep 'token:' "$FIRSTMATE/inputs.example.yaml" \
  "example inputs must never contain an Akua token value"

pass "Akua packages keep Firstmate persistent and authority explicit"
