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

PROFILE="$ROOT/deploy/orbstack/inputs.yaml"
PROFILE_OUT="$TMP/orbstack-rendered"

[ -f "$PROFILE" ] || fail "OrbStack profile inputs must exist"
[ ! -e "$ROOT/deploy/orbstack/kustomization.yaml" ] || fail "OrbStack must not keep a second static installer"
assert_grep 'namespace: agent-os-demo' "$PROFILE" "OrbStack profile must preserve its isolated namespace"
assert_grep 'imagePullPolicy: Never' "$PROFILE" "OrbStack profile must use its local image store"
assert_grep 'allowMutableImage: true' "$PROFILE" "OrbStack profile must explicitly allow its local image tag"
assert_grep 'rbac: cluster-admin' "$PROFILE" "OrbStack profile must make its local-demo grant explicit"

akua render --no-agent-mode --package "$ROOT/tools/agent-os/packages/firstmate/package.k" \
  --inputs "$PROFILE" --out "$PROFILE_OUT" >/dev/null || fail "OrbStack profile did not render the canonical package"
rendered=$(cat "$PROFILE_OUT"/*.yaml)
assert_contains "$rendered" 'kind: ServiceAccount' "render must include the primary ServiceAccount"
assert_contains "$rendered" 'kind: ClusterRoleBinding' "render must include the explicit local-demo grant"
assert_contains "$rendered" 'name: agent-os-firstmate-home' "render must include the persistent primary home"
assert_contains "$rendered" 'kind: StatefulSet' "render must include the primary StatefulSet"
assert_contains "$rendered" 'imagePullPolicy: Never' "OrbStack must use the locally built image"
assert_contains "$rendered" 'mountPath: /home/agent' "the primary home must mount at FM_HOME"
assert_not_contains "$rendered" 'hostUsers: false' "OrbStack demo must not request unsupported Pod user namespaces"
assert_contains "$rendered" 'runAsUser: 0' "primary must run as container root"
assert_contains "$rendered" 'name: agent-os-init' "primary must seed persistent tools"
assert_contains "$rendered" 'mountPath: /usr/local' "primary must persist /usr/local"
pass "OrbStack profile renders the canonical persistent primary"

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
    AGENT_OS_IN_CLUSTER=1 AGENT_OS_NAMESPACE=agent-os-demo AGENT_OS_IMAGE=agent-os:local-test \
    AGENT_OS_IMAGE_PULL_POLICY=Never "$LAUNCHER" "$@"
}

: > "$CALLS"
run_launcher create scout-1
grep -Fqx 'kubectl -n agent-os-demo apply -f -' "$CALLS" || fail "create must apply only to agent-os-demo"
[ "$(grep -Fc 'kind: PersistentVolumeClaim' "$STDIN_LOG")" -eq 1 ] || fail "create must emit one PVC"
[ "$(grep -Fc 'kind: Pod' "$STDIN_LOG")" -eq 1 ] || fail "create must emit one Pod"
assert_grep 'agent-os.dev/crewmate: scout-1' "$STDIN_LOG" "child resources need the stable crewmate label"
assert_grep 'automountServiceAccountToken: false' "$STDIN_LOG" "children must not receive Kubernetes credentials"
assert_grep 'claimName: agent-os-crewmate-scout-1-home' "$STDIN_LOG" "child work must use its own PVC"
assert_no_grep 'hostUsers: false' "$STDIN_LOG" "OrbStack children must not request unsupported Pod user namespaces"
assert_grep 'runAsUser: 0' "$STDIN_LOG" "children must run as container root"
assert_grep 'name: agent-os-init' "$STDIN_LOG" "children must seed persistent tools"
assert_grep 'mountPath: /usr/local' "$STDIN_LOG" "children must persist /usr/local"
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
  AGENT_OS_NAMESPACE=agent-os-demo AGENT_OS_IMAGE=agent-os:local-test "$LAUNCHER" status scout-1 >/dev/null 2>&1; then
  fail "host execution without an explicit context must be rejected"
fi
pass "launcher refuses an ambient host Kubernetes context"

: > "$CALLS"
PATH="$FAKEBIN:$PATH" AGENT_OS_TEST_LOG="$CALLS" AGENT_OS_STDIN_LOG="$STDIN_LOG" \
  AGENT_OS_CONTEXT=orbstack AGENT_OS_NAMESPACE=agent-os-demo AGENT_OS_IMAGE=agent-os:local-test "$LAUNCHER" status scout-1
grep -Fqx 'kubectl --context orbstack -n agent-os-demo get pod agent-os-crewmate-scout-1' "$CALLS" || \
  fail "host status must pin the selected context"
pass "host launcher calls require and pin an explicit context"

GENERIC="$ROOT/bin/agent-os-kubernetes.sh"
GENERIC_INPUTS="$TMP/portable-inputs.yaml"

cat > "$GENERIC_INPUTS" <<'YAML'
namespace: portable-agent-os
image: ghcr.io/akua-dev/agent-os@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
imagePullPolicy: IfNotPresent
rbac: namespace
storage: 20Gi
YAML

cat > "$FAKEBIN/akua" <<'SH'
#!/usr/bin/env bash
printf 'akua' >> "$AGENT_OS_TEST_LOG"
printf ' %s' "$@" >> "$AGENT_OS_TEST_LOG"
printf '\n' >> "$AGENT_OS_TEST_LOG"
out=''
while [ "$#" -gt 0 ]; do
  if [ "$1" = '--out' ]; then
    out=$2
    break
  fi
  shift
done
mkdir -p "$out"
printf 'apiVersion: v1\nkind: ConfigMap\n' > "$out/rendered.yaml"
SH
chmod +x "$FAKEBIN/akua"

run_generic() {
  PATH="$FAKEBIN:$PATH" AGENT_OS_TEST_LOG="$CALLS" AGENT_OS_INPUTS="$GENERIC_INPUTS" \
    AGENT_OS_CONTEXT=kind-agent-os AGENT_OS_NAMESPACE=portable-agent-os "$GENERIC" "$@"
}

: > "$CALLS"
run_generic install
grep -Fq -- "akua render --no-agent-mode --package $ROOT/tools/agent-os/packages/firstmate/package.k --inputs $GENERIC_INPUTS --out " "$CALLS" || \
  fail "generic install must render the canonical package before applying it"
grep -Fq 'kubectl --context kind-agent-os apply -f ' "$CALLS" || \
  fail "generic install must apply only its freshly rendered package output"
grep -Fqx 'kubectl --context kind-agent-os -n portable-agent-os rollout status statefulset/agent-os-firstmate --timeout=180s' "$CALLS" || \
  fail "generic install must wait for the rendered Firstmate StatefulSet"
pass "generic install renders and applies the canonical package on an explicit context"

: > "$CALLS"
run_generic rollback
grep -Fqx 'kubectl --context kind-agent-os -n portable-agent-os rollout undo statefulset/agent-os-firstmate' "$CALLS" || \
  fail "generic rollback must target only the Firstmate StatefulSet"
pass "generic rollback remains StatefulSet-scoped"

: > "$CALLS"
if run_generic uninstall >/dev/null 2>&1; then
  fail "generic uninstall must require --yes"
fi
run_generic uninstall --yes
grep -Fq 'kubectl --context kind-agent-os delete --ignore-not-found -f ' "$CALLS" || \
  fail "confirmed uninstall must delete only resources from the fresh package render"
pass "generic uninstall requires confirmation and remains package-scoped"
