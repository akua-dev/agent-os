#!/usr/bin/env bash
set -u

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

STATE="$ROOT/bin/agent-os-candidate-state.sh"
TMP=$(fm_test_tmproot agent-os-candidate-state)
mkdir -p "$TMP"
OWNER_A=101
OWNER_B=202
OWNER_C=303
CLAIM_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
CLAIM_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
CLAIM_C=cccccccccccccccccccccccccccccccccccccccc

write_chain() {
  printf '%b\n' "$@" > "$TMP/chain.tsv"
}

expect_decision() {
  local expected=$1 actual
  actual=$("$STATE" "$TMP/chain.tsv") || fail "claim chain did not produce $expected"
  [ "$actual" = "$expected" ] || fail "claim chain produced $actual instead of $expected"
}

expect_refusal() {
  if "$STATE" "$TMP/chain.tsv" >/dev/null 2>&1; then
    fail "claim chain authorized another build"
  fi
}

write_chain "$OWNER_A\t$CLAIM_A\tabsent\tabsent"
expect_decision build

write_chain \
  "$OWNER_A\t$CLAIM_A\tattempted\texact-build" \
  "$OWNER_B\t$CLAIM_B\tabsent\tabsent"
expect_decision $'reuse-build\t'"$OWNER_A"

write_chain \
  "$OWNER_A\t$CLAIM_A\tattempted\texact-record" \
  "$OWNER_B\t$CLAIM_B\tabsent\tabsent" \
  "$OWNER_C\t$CLAIM_C\tabsent\tabsent"
expect_decision $'reuse-record\t'"$OWNER_A"

builds=0
write_chain "$OWNER_A\t$CLAIM_A\tabsent\tabsent"
decision=$("$STATE" "$TMP/chain.tsv") || fail "initial claim did not authorize its build"
[ "$decision" = build ] && builds=$((builds + 1))
write_chain \
  "$OWNER_A\t$CLAIM_A\tattempted\texact-build" \
  "$OWNER_B\t$CLAIM_B\tabsent\tabsent"
decision=$("$STATE" "$TMP/chain.tsv") || fail "handoff did not reuse ancestor evidence"
[ "$decision" = build ] && builds=$((builds + 1))
write_chain \
  "$OWNER_A\t$CLAIM_A\tattempted\texact-build" \
  "$OWNER_B\t$CLAIM_B\tabsent\tabsent" \
  "$OWNER_C\t$CLAIM_C\tabsent\tabsent"
decision=$("$STATE" "$TMP/chain.tsv") || fail "second handoff did not reuse ancestor evidence"
[ "$decision" = build ] && builds=$((builds + 1))
[ "$builds" -eq 1 ] || fail "claim-chain classifier authorized $builds builds"

write_chain \
  "$OWNER_A\t$CLAIM_A\tattempted\tabsent" \
  "$OWNER_B\t$CLAIM_B\tabsent\tabsent"
expect_refusal

write_chain \
  "$OWNER_A\t$CLAIM_A\tattempted\texact-build" \
  "$OWNER_B\t$CLAIM_B\tattempted\texact-build"
expect_refusal

write_chain \
  "$OWNER_A\t$CLAIM_A\tabsent\texact-build" \
  "$OWNER_B\t$CLAIM_B\tabsent\tabsent"
expect_refusal

for state in corrupt mismatched unreadable metadata-read-error partial ambiguous; do
  write_chain "$OWNER_A\t$CLAIM_A\t$state\tabsent"
  expect_refusal
  write_chain "$OWNER_A\t$CLAIM_A\tattempted\t$state"
  expect_refusal
done

write_chain \
  "$OWNER_A\t$CLAIM_A\tabsent\tabsent" \
  "$OWNER_A\t$CLAIM_B\tabsent\tabsent"
expect_refusal
write_chain \
  "$OWNER_A\t$CLAIM_A\tabsent\tabsent" \
  "$OWNER_B\t$CLAIM_A\tabsent\tabsent"
expect_refusal

pass "candidate claim-chain classifier permits one build and ancestor reuse only"
