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
if [ "${AGENT_OS_TEST_FAIL_WAIT:-0}" = 1 ] && [ "${1:-}" = -n ] && [ "${3:-}" = wait ]; then
  exit 1
fi
SH
chmod +x "$FAKEBIN/kubectl"

run_launcher() {
  PATH="$FAKEBIN:$PATH" AGENT_OS_TEST_LOG="$CALLS" AGENT_OS_STDIN_LOG="$STDIN_LOG" \
    AGENT_OS_IN_CLUSTER=1 AGENT_OS_NAMESPACE=agent-os-demo AGENT_OS_IMAGE=agent-os:local-test \
    AGENT_OS_IMAGE_PULL_POLICY=Never AGENT_OS_AI_SECRET=scout-1-ai-auth "$LAUNCHER" "$@"
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
assert_grep 'mountPath: /home/agent/.pi/agent/auth.json' "$STDIN_LOG" \
  "children must mount only the explicitly granted AI authorization file"
assert_grep 'secretName: scout-1-ai-auth' "$STDIN_LOG" \
  "children must reference the explicitly selected namespace-local Secret"
assert_grep 'readOnly: true' "$STDIN_LOG" "child AI authorization must be read-only"
grep -Fqx 'kubectl -n agent-os-demo wait --for=condition=Ready pod/agent-os-crewmate-scout-1 --timeout=180s' "$CALLS" || \
  fail "create must fail when the authorized Secret cannot produce a ready Pod"
pass "crewmate create emits one isolated Pod and PVC"

: > "$CALLS"
if PATH="$FAKEBIN:$PATH" AGENT_OS_TEST_LOG="$CALLS" AGENT_OS_STDIN_LOG="$STDIN_LOG" \
  AGENT_OS_IN_CLUSTER=1 AGENT_OS_NAMESPACE=agent-os-demo AGENT_OS_IMAGE=agent-os:local-test \
  "$LAUNCHER" create scout-1 >/dev/null 2>&1; then
  fail "crewmate create must require an explicit AI Secret reference"
fi
[ ! -s "$CALLS" ] || fail "missing AI Secret reference must fail before kubectl"
pass "crewmate create requires an explicit AI Secret grant"

: > "$CALLS"
if AGENT_OS_TEST_FAIL_WAIT=1 run_launcher create scout-1 >/dev/null 2>&1; then
  fail "crewmate create must fail when its authorized Secret cannot produce a ready Pod"
fi
grep -Fqx 'kubectl -n agent-os-demo delete pod agent-os-crewmate-scout-1 --ignore-not-found' "$CALLS" || \
  fail "failed create must remove the non-running Pod"
if grep -F 'delete pvc agent-os-crewmate-scout-1-home' "$CALLS" >/dev/null; then
  fail "failed create must retain the crewmate PVC for an authorized retry"
fi
pass "crewmate create fails closed while retaining its persistent home"

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
inputs=''
out=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --inputs) inputs=$2; shift 2 ;;
    --out) out=$2; shift 2 ;;
    *) shift ;;
  esac
done
mkdir -p "$out"
rbac=$(awk '/^rbac:/{print $2}' "$inputs")
case "$rbac" in
  namespace) printf 'apiVersion: rbac.authorization.k8s.io/v1\nkind: Role\n' > "$out/rendered.yaml" ;;
  cluster-admin) printf 'apiVersion: rbac.authorization.k8s.io/v1\nkind: ClusterRoleBinding\n' > "$out/rendered.yaml" ;;
  *) printf 'apiVersion: v1\nkind: ConfigMap\n' > "$out/rendered.yaml" ;;
esac
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
if grep -F 'delete clusterrolebinding' "$CALLS" >/dev/null; then
  fail "fresh namespace-scoped install must not require cluster RBAC deletion authority"
fi
pass "generic install renders and applies the canonical package on an explicit context"

missing_akua_out=''
missing_akua_rc=0
missing_akua_out=$(PATH="$FAKEBIN:$PATH" AGENT_OS_TEST_LOG="$CALLS" AGENT_OS_INPUTS="$GENERIC_INPUTS" \
  AGENT_OS_AKUA=missing-agent-os-akua AGENT_OS_CONTEXT=kind-agent-os AGENT_OS_NAMESPACE=portable-agent-os \
  "$GENERIC" install 2>&1) || missing_akua_rc=$?
[ "$missing_akua_rc" -eq 2 ] || fail "Kubernetes package operations must reject a missing renderer with exit 2"
assert_contains "$missing_akua_out" "error: Akua renderer 'missing-agent-os-akua' is required for Kubernetes package operations" \
  "Kubernetes package operations must explain their optional renderer dependency"
pass "Kubernetes package operations require the optional Akua renderer explicitly"

: > "$CALLS"
run_generic upgrade
grep -Fqx 'kubectl --context kind-agent-os delete clusterrolebinding agent-os-firstmate-portable-agent-os --ignore-not-found' "$CALLS" || \
  fail "namespace RBAC upgrade must revoke any stale cluster-admin binding"
if grep -F 'delete rolebinding agent-os-firstmate-runtime' "$CALLS" >/dev/null; then
  fail "namespace RBAC upgrade must retain its rendered RoleBinding"
fi
pass "namespace RBAC upgrade revokes stale cluster-admin authority"

CLUSTER_ADMIN_INPUTS="$TMP/cluster-admin-inputs.yaml"
sed 's/rbac: namespace/rbac: cluster-admin/' "$GENERIC_INPUTS" > "$CLUSTER_ADMIN_INPUTS"
: > "$CALLS"
PATH="$FAKEBIN:$PATH" AGENT_OS_TEST_LOG="$CALLS" AGENT_OS_INPUTS="$CLUSTER_ADMIN_INPUTS" \
  AGENT_OS_CONTEXT=kind-agent-os AGENT_OS_NAMESPACE=portable-agent-os "$GENERIC" upgrade
grep -Fqx 'kubectl --context kind-agent-os -n portable-agent-os delete rolebinding agent-os-firstmate-runtime --ignore-not-found' "$CALLS" || \
  fail "cluster-admin upgrade must delete the stale namespace RoleBinding"
grep -Fqx 'kubectl --context kind-agent-os -n portable-agent-os delete role agent-os-firstmate-runtime --ignore-not-found' "$CALLS" || \
  fail "cluster-admin upgrade must delete the stale namespace Role"
if grep -F 'delete clusterrolebinding agent-os-firstmate-portable-agent-os' "$CALLS" >/dev/null; then
  fail "cluster-admin upgrade must retain its rendered ClusterRoleBinding"
fi
pass "cluster-admin RBAC upgrade removes stale namespace authority"

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
grep -Fqx 'kubectl --context kind-agent-os delete clusterrolebinding agent-os-firstmate-portable-agent-os --ignore-not-found' "$CALLS" || \
  fail "uninstall must revoke a stale cluster-admin binding even when current inputs omit it"
grep -Fqx 'kubectl --context kind-agent-os -n portable-agent-os delete rolebinding agent-os-firstmate-runtime --ignore-not-found' "$CALLS" || \
  fail "uninstall must remove namespace runtime binding regardless of current inputs"
grep -Fqx 'kubectl --context kind-agent-os -n portable-agent-os delete role agent-os-firstmate-runtime --ignore-not-found' "$CALLS" || \
  fail "uninstall must remove namespace runtime Role regardless of current inputs"
pass "generic uninstall requires confirmation and revokes every package RBAC mode"
