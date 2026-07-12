#!/usr/bin/env bash
# Kubernetes manifest and isolated crewmate launcher tests.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LAUNCHER="$ROOT/bin/agent-os-crewmate.sh"
TMP=$(fm_test_tmproot agent-os-kubernetes)
FAKEBIN=$(fm_fakebin "$TMP")
CALLS="$TMP/calls.log"
STDIN_LOG="$TMP/stdin.yaml"

rendered=$(kubectl kustomize "$ROOT/deploy/orbstack") || fail "OrbStack kustomization did not render"
assert_contains "$rendered" 'kind: Namespace' "render must include the namespace"
assert_contains "$rendered" 'name: agent-os-demo' "render must use the isolated namespace"
assert_contains "$rendered" 'kind: ServiceAccount' "render must include the primary ServiceAccount"
assert_contains "$rendered" 'kind: ClusterRoleBinding' "render must include the explicit local-demo grant"
assert_contains "$rendered" 'name: agent-os-firstmate-home' "render must include the persistent primary home"
assert_contains "$rendered" 'kind: StatefulSet' "render must include the primary StatefulSet"
assert_contains "$rendered" 'imagePullPolicy: Never' "OrbStack must use the locally built image"
assert_contains "$rendered" 'mountPath: /home/agent' "the primary home must mount at FM_HOME"
pass "OrbStack manifests render the isolated persistent primary"

cat > "$FAKEBIN/kubectl" <<'SH'
#!/usr/bin/env bash
printf 'kubectl' >> "$AGENT_OS_TEST_LOG"
printf ' %s' "$@" >> "$AGENT_OS_TEST_LOG"
printf '\n' >> "$AGENT_OS_TEST_LOG"
if [ "${*: -2}" = "-f -" ]; then
  cat > "$AGENT_OS_STDIN_LOG"
fi
SH
chmod +x "$FAKEBIN/kubectl"

run_launcher() {
  PATH="$FAKEBIN:$PATH" AGENT_OS_TEST_LOG="$CALLS" AGENT_OS_STDIN_LOG="$STDIN_LOG" \
    AGENT_OS_IN_CLUSTER=1 "$LAUNCHER" "$@"
}

: > "$CALLS"
run_launcher create scout-1
grep -Fqx 'kubectl -n agent-os-demo apply -f -' "$CALLS" || fail "create must apply only to agent-os-demo"
[ "$(grep -Fc 'kind: PersistentVolumeClaim' "$STDIN_LOG")" -eq 1 ] || fail "create must emit one PVC"
[ "$(grep -Fc 'kind: Pod' "$STDIN_LOG")" -eq 1 ] || fail "create must emit one Pod"
assert_grep 'agent-os.akua.dev/crewmate: scout-1' "$STDIN_LOG" "child resources need the stable crewmate label"
assert_grep 'automountServiceAccountToken: false' "$STDIN_LOG" "children must not receive Kubernetes credentials"
assert_grep 'claimName: agent-os-crewmate-scout-1-home' "$STDIN_LOG" "child work must use its own PVC"
pass "crewmate create emits one isolated Pod and PVC"

: > "$CALLS"
run_launcher delete scout-1
grep -Fqx 'kubectl -n agent-os-demo delete pod agent-os-crewmate-scout-1 --ignore-not-found' "$CALLS" || \
  fail "delete must target the crewmate Pod explicitly"
grep -Fqx 'kubectl -n agent-os-demo delete pvc agent-os-crewmate-scout-1-home --ignore-not-found' "$CALLS" || \
  fail "delete must target the crewmate PVC explicitly"
pass "crewmate delete removes the Pod and PVC explicitly"

if run_launcher create 'Bad_ID' >/dev/null 2>&1; then
  fail "invalid Kubernetes crewmate IDs must be rejected"
fi
pass "crewmate IDs are validated before kubectl"

if PATH="$FAKEBIN:$PATH" AGENT_OS_TEST_LOG="$CALLS" AGENT_OS_STDIN_LOG="$STDIN_LOG" \
  "$LAUNCHER" status scout-1 >/dev/null 2>&1; then
  fail "host execution without an explicit context must be rejected"
fi
pass "launcher refuses an ambient host Kubernetes context"

: > "$CALLS"
PATH="$FAKEBIN:$PATH" AGENT_OS_TEST_LOG="$CALLS" AGENT_OS_STDIN_LOG="$STDIN_LOG" \
  AGENT_OS_CONTEXT=orbstack "$LAUNCHER" status scout-1
grep -Fqx 'kubectl --context orbstack -n agent-os-demo get pod agent-os-crewmate-scout-1' "$CALLS" || \
  fail "host status must pin the selected context"
pass "host launcher calls require and pin an explicit context"
