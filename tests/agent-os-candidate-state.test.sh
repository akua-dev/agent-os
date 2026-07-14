#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
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

write_chain "$OWNER_A\t$CLAIM_A\tabsent\t0\t0"
expect_decision build

write_chain \
  "$OWNER_A\t$CLAIM_A\tattempted\t0\t1" \
  "$OWNER_B\t$CLAIM_B\tabsent\t0\t0"
expect_decision $'reuse-build\t'"$OWNER_A"

write_chain \
  "$OWNER_A\t$CLAIM_A\tattempted\t1\t0" \
  "$OWNER_B\t$CLAIM_B\tabsent\t0\t0" \
  "$OWNER_C\t$CLAIM_C\tabsent\t0\t0"
expect_decision $'reuse-record\t'"$OWNER_A"

write_chain \
  "$OWNER_A\t$CLAIM_A\tattempted\t1\t1" \
  "$OWNER_B\t$CLAIM_B\tabsent\t0\t0"
expect_decision $'reuse-record-pair\t'"$OWNER_A"$'\t'"$OWNER_A"

write_chain \
  "$OWNER_A\t$CLAIM_A\tattempted\t0\t1" \
  "$OWNER_B\t$CLAIM_B\tabsent\t1\t0"
expect_decision $'reuse-record-pair\t'"$OWNER_B"$'\t'"$OWNER_A"

builds=0
write_chain "$OWNER_A\t$CLAIM_A\tabsent\t0\t0"
decision=$("$STATE" "$TMP/chain.tsv") || fail "initial claim did not authorize its build"
[ "$decision" = build ] && builds=$((builds + 1))
write_chain \
  "$OWNER_A\t$CLAIM_A\tattempted\t0\t1" \
  "$OWNER_B\t$CLAIM_B\tabsent\t0\t0"
decision=$("$STATE" "$TMP/chain.tsv") || fail "handoff did not reuse ancestor evidence"
[ "$decision" = build ] && builds=$((builds + 1))
write_chain \
  "$OWNER_A\t$CLAIM_A\tattempted\t0\t1" \
  "$OWNER_B\t$CLAIM_B\tabsent\t1\t0" \
  "$OWNER_C\t$CLAIM_C\tabsent\t0\t0"
decision=$("$STATE" "$TMP/chain.tsv") || fail "second handoff did not prefer paired ancestor evidence"
[ "$decision" = build ] && builds=$((builds + 1))
[ "$decision" = $'reuse-record-pair\t'"$OWNER_B"$'\t'"$OWNER_A" ] || \
  fail "second handoff did not reuse paired ancestor evidence"
[ "$builds" -eq 1 ] || fail "claim-chain classifier authorized $builds builds"

write_chain \
  "$OWNER_A\t$CLAIM_A\tattempted\t0\t0" \
  "$OWNER_B\t$CLAIM_B\tabsent\t0\t0"
expect_refusal

write_chain \
  "$OWNER_A\t$CLAIM_A\tattempted\t0\t1" \
  "$OWNER_B\t$CLAIM_B\tattempted\t0\t1"
expect_refusal

write_chain \
  "$OWNER_A\t$CLAIM_A\tabsent\t0\t1" \
  "$OWNER_B\t$CLAIM_B\tabsent\t0\t0"
expect_refusal

write_chain \
  "$OWNER_A\t$CLAIM_A\tabsent\t1\t0" \
  "$OWNER_B\t$CLAIM_B\tattempted\t0\t1"
expect_refusal

write_chain \
  "$OWNER_A\t$CLAIM_A\tattempted\t0\t1" \
  "$OWNER_B\t$CLAIM_B\tabsent\t1\t0" \
  "$OWNER_C\t$CLAIM_C\tabsent\t1\t0"
expect_refusal

for state in corrupt mismatched unreadable metadata-read-error partial ambiguous; do
  write_chain "$OWNER_A\t$CLAIM_A\t$state\t0\t0"
  expect_refusal
  write_chain "$OWNER_A\t$CLAIM_A\tattempted\t$state\t0"
  expect_refusal
done

for counts in '2\t0' '0\t2' '2\t2'; do
  write_chain "$OWNER_A\t$CLAIM_A\tattempted\t$counts"
  expect_refusal
done

write_chain \
  "$OWNER_A\t$CLAIM_A\tabsent\t0\t0" \
  "$OWNER_A\t$CLAIM_B\tabsent\t0\t0"
expect_refusal
write_chain \
  "$OWNER_A\t$CLAIM_A\tabsent\t0\t0" \
  "$OWNER_B\t$CLAIM_A\tabsent\t0\t0"
expect_refusal

pass "candidate claim-chain classifier permits one build and ancestor reuse only"
