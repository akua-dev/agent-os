#!/usr/bin/env bash
set -u

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

STATE="$ROOT/bin/agent-os-candidate-state.sh"

expect_decision() {
  local expected=$1 attempt=$2 evidence=$3 claim=$4 actual
  actual=$("$STATE" "$attempt" "$evidence" "$claim") || \
    fail "state $attempt/$evidence/$claim did not produce $expected"
  [ "$actual" = "$expected" ] || \
    fail "state $attempt/$evidence/$claim produced $actual instead of $expected"
}

expect_refusal() {
  local attempt=$1 evidence=$2 claim=$3
  if "$STATE" "$attempt" "$evidence" "$claim" >/dev/null 2>&1; then
    fail "state $attempt/$evidence/$claim authorized another build"
  fi
}

expect_decision build absent absent exact
expect_decision reuse-build attempted exact-build exact
expect_decision reuse-record attempted exact-record exact

builds=0
decision=$("$STATE" absent absent exact) || fail "initial candidate did not authorize its one build"
[ "$decision" = build ] && builds=$((builds + 1))
decision=$("$STATE" attempted exact-build exact) || fail "durable candidate build was not reusable"
[ "$decision" = build ] && builds=$((builds + 1))
[ "$builds" -eq 1 ] || fail "candidate state machine authorized $builds builds"

for attempt in attempted corrupt mismatched unreadable metadata-read-error partial ambiguous; do
  expect_refusal "$attempt" absent exact
done
for evidence in corrupt mismatched unreadable metadata-read-error partial ambiguous; do
  expect_refusal attempted "$evidence" exact
done
for claim in missing mismatched unreadable ambiguous; do
  expect_refusal absent absent "$claim"
done
expect_refusal attempted partial exact
expect_refusal attempted absent exact
expect_refusal absent exact-build exact
expect_refusal absent exact-record exact

pass "candidate state machine permits one build and exact reuse only"
