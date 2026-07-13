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
if [ "${AGENT_OS_TEST_FAIL_ANNOTATE:-0}" = 1 ] && [[ " $* " = *" annotate statefulset agent-os-firstmate "* ]]; then
  exit 1
fi
case " $* " in
  *" get namespace "*" --ignore-not-found -o name "*)
    case "${AGENT_OS_TEST_NAMESPACE_STATE:-absent}" in
      absent) ;;
      *) printf 'namespace/%s\n' "${AGENT_OS_TEST_NAMESPACE:-portable-agent-os}" ;;
    esac
    ;;
  *" get namespace "*" -o jsonpath="*)
    case "${AGENT_OS_TEST_NAMESPACE_STATE:-absent}" in
      owned) printf 'agent-os\tagent-os-firstmate:%s' "${AGENT_OS_TEST_NAMESPACE:-portable-agent-os}" ;;
      foreign) printf 'other\tother-installation' ;;
      *) printf '\t' ;;
    esac
    ;;
  *" get statefulset agent-os-firstmate --ignore-not-found -o jsonpath="*)
    case "${AGENT_OS_TEST_WORKLOAD_STATE:-absent}" in
      absent) ;;
      namespace) printf 'agent-os-firstmate\tnamespace\t' ;;
      cluster-admin) printf 'agent-os-firstmate\tcluster-admin\t' ;;
      none) printf 'agent-os-firstmate\tnone\t' ;;
      pending) printf 'agent-os-firstmate\tnamespace\trequired' ;;
      unknown) printf 'agent-os-firstmate\t\t' ;;
    esac
    ;;
  *" get role agent-os-firstmate-runtime -o jsonpath="*)
    printf 'agent-os-firstmate-runtime'
    ;;
  *" get rolebinding agent-os-firstmate-runtime -o jsonpath="*)
    printf 'Role\tagent-os-firstmate-runtime\tServiceAccount\tagent-os-firstmate\t%s' \
      "${AGENT_OS_TEST_NAMESPACE:-portable-agent-os}"
    ;;
  *" get clusterrolebinding agent-os-firstmate-"*" --ignore-not-found -o jsonpath="*)
    case "${AGENT_OS_TEST_CLUSTER_RBAC_STATE:-absent}" in
      absent) ;;
      owned)
        printf 'agent-os-firstmate-%s\tagent-os\tagent-os-firstmate:%s' \
          "${AGENT_OS_TEST_NAMESPACE:-portable-agent-os}" "${AGENT_OS_TEST_NAMESPACE:-portable-agent-os}"
        ;;
      foreign) printf 'agent-os-firstmate-portable-agent-os\tother\tother-installation' ;;
    esac
    ;;
  *" api-resources --verbs=list --namespaced -o name "*)
    printf '%s\n' pods serviceaccounts configmaps
    ;;
  *" get pods -o name "*)
    [ -z "${AGENT_OS_TEST_FOREIGN_RESOURCE:-}" ] || printf 'pod/%s\n' "$AGENT_OS_TEST_FOREIGN_RESOURCE"
    ;;
  *" get serviceaccounts -o name "*) printf '%s\n' serviceaccount/default ;;
  *" get configmaps -o name "*) printf '%s\n' configmap/kube-root-ca.crt ;;
esac
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
assert_grep 'readinessProbe:' "$STDIN_LOG" "child readiness must wait for Herdr health"
assert_grep 'herdr' "$STDIN_LOG" "child readiness must invoke Herdr"
assert_grep 'status' "$STDIN_LOG" "child readiness must inspect Herdr status"
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
namespace=$(awk '/^namespace:/{print $2}' "$inputs")
create_namespace=$(awk '/^createNamespace:/{print $2}' "$inputs")
[ -n "$create_namespace" ] || create_namespace=true
cat > "$out/statefulset.yaml" <<YAML
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: agent-os-firstmate
  namespace: $namespace
  annotations:
    agent-os.dev/rbac-mode: $rbac
YAML
if [ "$create_namespace" = true ]; then
  cat > "$out/namespace.yaml" <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: $namespace
  labels:
    app.kubernetes.io/managed-by: agent-os
  annotations:
    agent-os.dev/installation-id: agent-os-firstmate:$namespace
YAML
fi
case "$rbac" in
  namespace)
    printf 'apiVersion: rbac.authorization.k8s.io/v1\nkind: Role\nmetadata:\n  namespace: %s\n' "$namespace" \
      > "$out/role.yaml"
    printf 'apiVersion: rbac.authorization.k8s.io/v1\nkind: RoleBinding\nmetadata:\n  namespace: %s\n' "$namespace" \
      > "$out/rolebinding.yaml"
    ;;
  cluster-admin)
    cat > "$out/clusterrolebinding.yaml" <<YAML
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: agent-os-firstmate-$namespace
  labels:
    app.kubernetes.io/managed-by: agent-os
  annotations:
    agent-os.dev/installation-id: agent-os-firstmate:$namespace
YAML
    ;;
esac
SH
chmod +x "$FAKEBIN/akua"

run_generic() {
  PATH="$FAKEBIN:$PATH" AGENT_OS_TEST_LOG="$CALLS" AGENT_OS_INPUTS="$GENERIC_INPUTS" \
    AGENT_OS_TEST_NAMESPACE=portable-agent-os \
    AGENT_OS_TEST_NAMESPACE_STATE="${AGENT_OS_TEST_NAMESPACE_STATE:-absent}" \
    AGENT_OS_TEST_WORKLOAD_STATE="${AGENT_OS_TEST_WORKLOAD_STATE:-absent}" \
    AGENT_OS_TEST_CLUSTER_RBAC_STATE="${AGENT_OS_TEST_CLUSTER_RBAC_STATE:-absent}" \
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

: > "$CALLS"
owned_namespace_out=''
owned_namespace_rc=0
owned_namespace_out=$(AGENT_OS_TEST_NAMESPACE_STATE=foreign run_generic install 2>&1) || owned_namespace_rc=$?
[ "$owned_namespace_rc" -eq 2 ] || \
  fail "install into an existing unowned namespace must exit 2, got $owned_namespace_rc: $owned_namespace_out"
if grep -F 'kubectl --context kind-agent-os apply' "$CALLS" >/dev/null; then
  fail "install must reject an unowned existing namespace before apply"
fi
pass "createNamespace install refuses implicit namespace adoption"

UNOWNED_INPUTS="$TMP/unowned-namespace-inputs.yaml"
awk '{ print; if ($1 == "namespace:") print "createNamespace: false" }' "$GENERIC_INPUTS" > "$UNOWNED_INPUTS"
: > "$CALLS"
PATH="$FAKEBIN:$PATH" AGENT_OS_TEST_LOG="$CALLS" AGENT_OS_INPUTS="$UNOWNED_INPUTS" \
  AGENT_OS_TEST_NAMESPACE=portable-agent-os AGENT_OS_TEST_NAMESPACE_STATE=unowned \
  AGENT_OS_TEST_WORKLOAD_STATE=absent AGENT_OS_CONTEXT=kind-agent-os \
  AGENT_OS_NAMESPACE=portable-agent-os "$GENERIC" install
grep -Fq 'kubectl --context kind-agent-os apply -f ' "$CALLS" || \
  fail "createNamespace=false must install into a pre-existing unowned namespace"
pass "createNamespace=false requires and preserves an unowned namespace"

: > "$CALLS"
owned_unmanaged_out=''
owned_unmanaged_rc=0
owned_unmanaged_out=$(PATH="$FAKEBIN:$PATH" AGENT_OS_TEST_LOG="$CALLS" AGENT_OS_INPUTS="$UNOWNED_INPUTS" \
  AGENT_OS_TEST_NAMESPACE=portable-agent-os AGENT_OS_TEST_NAMESPACE_STATE=owned \
  AGENT_OS_TEST_WORKLOAD_STATE=absent AGENT_OS_CONTEXT=kind-agent-os \
  AGENT_OS_NAMESPACE=portable-agent-os "$GENERIC" install 2>&1) || owned_unmanaged_rc=$?
[ "$owned_unmanaged_rc" -eq 2 ] || \
  fail "createNamespace=false must reject an Agent-OS-owned namespace: $owned_unmanaged_out"
pass "createNamespace=false refuses an owned namespace"

: > "$CALLS"
mismatch_out=''
mismatch_rc=0
mismatch_out=$(PATH="$FAKEBIN:$PATH" AGENT_OS_TEST_LOG="$CALLS" AGENT_OS_INPUTS="$GENERIC_INPUTS" \
  AGENT_OS_TEST_NAMESPACE=portable-agent-os AGENT_OS_CONTEXT=kind-agent-os \
  AGENT_OS_NAMESPACE=wrong-namespace "$GENERIC" install 2>&1) || mismatch_rc=$?
[ "$mismatch_rc" -eq 2 ] || fail "namespace mismatch must exit 2, got $mismatch_rc: $mismatch_out"
if grep -F '^kubectl ' "$CALLS" >/dev/null; then
  fail "namespace mismatch must fail before any kubectl mutation"
fi
pass "rendered namespace is authoritative over an inconsistent environment"

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
cleanup_out=''
cleanup_rc=0
cleanup_out=$(AGENT_OS_TEST_NAMESPACE_STATE=owned AGENT_OS_TEST_WORKLOAD_STATE=cluster-admin \
  run_generic upgrade 2>&1) || cleanup_rc=$?
[ "$cleanup_rc" -eq 3 ] || \
  fail "cluster-admin downgrade must stop for privileged cleanup with exit 3, got $cleanup_rc: $cleanup_out"
apply_line=$(grep -Fn 'kubectl --context kind-agent-os apply -f ' "$CALLS" | head -n 1 | cut -d: -f1)
marker_line=$(grep -Fn 'annotate statefulset agent-os-firstmate agent-os.dev/cluster-rbac-cleanup=required' "$CALLS" | head -n 1 | cut -d: -f1)
rollout_line=$(grep -Fn 'kubectl --context kind-agent-os -n portable-agent-os rollout status' "$CALLS" | head -n 1 | cut -d: -f1)
verify_line=$(grep -Fn 'kubectl --context kind-agent-os -n portable-agent-os get role agent-os-firstmate-runtime' "$CALLS" | head -n 1 | cut -d: -f1)
[ -n "$marker_line" ] && [ -n "$apply_line" ] && [ -n "$rollout_line" ] && [ -n "$verify_line" ] && \
  [ "$marker_line" -lt "$apply_line" ] && [ "$apply_line" -lt "$rollout_line" ] && \
  [ "$rollout_line" -lt "$verify_line" ] || \
  fail "downgrade must apply and roll out desired namespaced RBAC before privileged cleanup is requested"
if grep -E 'kubectl .* (get|delete) clusterrolebinding' "$CALLS" >/dev/null; then
  fail "routine namespace upgrade must never request cluster-wide RBAC authority"
fi
assert_contains "$cleanup_out" 'cleanup-cluster-rbac --yes' \
  "downgrade must print the exact separately confirmed privileged cleanup command"
assert_contains "$cleanup_out" 'clusterrolebinding/agent-os-firstmate-portable-agent-os absent' \
  "downgrade must print the required cleanup evidence"
pass "cluster-admin downgrade applies desired RBAC before requiring privileged cleanup"

: > "$CALLS"
marker_failure_rc=0
AGENT_OS_TEST_NAMESPACE_STATE=owned AGENT_OS_TEST_WORKLOAD_STATE=cluster-admin \
  AGENT_OS_TEST_FAIL_ANNOTATE=1 run_generic upgrade >/dev/null 2>&1 || marker_failure_rc=$?
[ "$marker_failure_rc" -ne 0 ] || fail "downgrade must fail if its durable cleanup marker cannot be recorded"
if grep -F 'kubectl --context kind-agent-os apply -f ' "$CALLS" >/dev/null; then
  fail "downgrade must record its durable cleanup marker before changing the workload RBAC mode"
fi
pass "cluster-admin downgrade records cleanup state before mutation"

: > "$CALLS"
if AGENT_OS_TEST_CLUSTER_RBAC_STATE=owned run_generic cleanup-cluster-rbac >/dev/null 2>&1; then
  fail "privileged cluster RBAC cleanup must require --yes"
fi
[ ! -s "$CALLS" ] || fail "unconfirmed cluster RBAC cleanup invoked an external command"

: > "$CALLS"
AGENT_OS_TEST_NAMESPACE_STATE=owned AGENT_OS_TEST_WORKLOAD_STATE=pending \
  AGENT_OS_TEST_CLUSTER_RBAC_STATE=owned run_generic cleanup-cluster-rbac --yes
grep -Fq 'kubectl --context kind-agent-os get clusterrolebinding agent-os-firstmate-portable-agent-os --ignore-not-found' "$CALLS" || \
  fail "privileged cleanup must inspect only the exact stale ClusterRoleBinding"
grep -Fqx 'kubectl --context kind-agent-os delete clusterrolebinding agent-os-firstmate-portable-agent-os' "$CALLS" || \
  fail "privileged cleanup must delete only the exact owned ClusterRoleBinding"
grep -Fqx 'kubectl --context kind-agent-os wait --for=delete clusterrolebinding/agent-os-firstmate-portable-agent-os --timeout=60s' "$CALLS" || \
  fail "privileged cleanup must produce deletion evidence for the exact binding"
pass "privileged cleanup verifies ownership and deletes one exact binding"

: > "$CALLS"
absent_binding_out=$(AGENT_OS_TEST_NAMESPACE_STATE=absent AGENT_OS_TEST_WORKLOAD_STATE=absent \
  AGENT_OS_TEST_CLUSTER_RBAC_STATE=absent run_generic cleanup-cluster-rbac --yes)
assert_contains "$absent_binding_out" 'clusterrolebinding/agent-os-firstmate-portable-agent-os absent' \
  "privileged cleanup must accept exact absence as completion evidence"
if grep -F 'delete clusterrolebinding' "$CALLS" >/dev/null; then
  fail "privileged cleanup must not delete an already absent ClusterRoleBinding"
fi
pass "privileged cleanup records absence after namespace deletion"

: > "$CALLS"
foreign_binding_out=''
foreign_binding_rc=0
foreign_binding_out=$(AGENT_OS_TEST_CLUSTER_RBAC_STATE=foreign run_generic cleanup-cluster-rbac --yes 2>&1) || \
  foreign_binding_rc=$?
[ "$foreign_binding_rc" -eq 2 ] || fail "foreign ClusterRoleBinding cleanup must exit 2: $foreign_binding_out"
if grep -F 'delete clusterrolebinding' "$CALLS" >/dev/null; then
  fail "privileged cleanup must never delete a binding with mismatched ownership"
fi
pass "privileged cleanup refuses a foreign exact-name binding"

CLUSTER_ADMIN_INPUTS="$TMP/cluster-admin-inputs.yaml"
sed 's/rbac: namespace/rbac: cluster-admin/' "$GENERIC_INPUTS" > "$CLUSTER_ADMIN_INPUTS"
: > "$CALLS"
PATH="$FAKEBIN:$PATH" AGENT_OS_TEST_LOG="$CALLS" AGENT_OS_INPUTS="$CLUSTER_ADMIN_INPUTS" \
  AGENT_OS_TEST_NAMESPACE=portable-agent-os AGENT_OS_TEST_NAMESPACE_STATE=owned \
  AGENT_OS_TEST_WORKLOAD_STATE=namespace AGENT_OS_CONTEXT=kind-agent-os \
  AGENT_OS_NAMESPACE=portable-agent-os "$GENERIC" upgrade
grep -Fqx 'kubectl --context kind-agent-os -n portable-agent-os delete rolebinding agent-os-firstmate-runtime --ignore-not-found' "$CALLS" || \
  fail "cluster-admin upgrade must delete the stale namespace RoleBinding"
grep -Fqx 'kubectl --context kind-agent-os -n portable-agent-os delete role agent-os-firstmate-runtime --ignore-not-found' "$CALLS" || \
  fail "cluster-admin upgrade must delete the stale namespace Role"
apply_line=$(grep -Fn 'kubectl --context kind-agent-os apply -f ' "$CALLS" | head -n 1 | cut -d: -f1)
delete_line=$(grep -Fn 'delete rolebinding agent-os-firstmate-runtime' "$CALLS" | head -n 1 | cut -d: -f1)
[ -n "$apply_line" ] && [ -n "$delete_line" ] && [ "$apply_line" -lt "$delete_line" ] || \
  fail "cluster-admin upgrade must apply replacement authority before removing namespace RBAC"
if grep -F 'delete clusterrolebinding agent-os-firstmate-portable-agent-os' "$CALLS" >/dev/null; then
  fail "routine cluster-admin upgrade must retain its rendered ClusterRoleBinding"
fi
pass "cluster-admin upgrade reconciles namespaced authority after apply"

: > "$CALLS"
run_generic rollback
grep -Fqx 'kubectl --context kind-agent-os -n portable-agent-os rollout undo statefulset/agent-os-firstmate' "$CALLS" || \
  fail "generic rollback must target only the Firstmate StatefulSet"
pass "generic rollback remains StatefulSet-scoped"

: > "$CALLS"
if run_generic uninstall >/dev/null 2>&1; then
  fail "generic uninstall must require --yes"
fi
: > "$CALLS"
AGENT_OS_TEST_NAMESPACE_STATE=owned AGENT_OS_TEST_WORKLOAD_STATE=namespace run_generic uninstall --yes
if grep -E 'kubectl .* (get|delete) clusterrolebinding' "$CALLS" >/dev/null; then
  fail "routine namespace uninstall must never request cluster-wide RBAC authority"
fi
if grep -F 'delete namespace portable-agent-os' "$CALLS" >/dev/null; then
  fail "bounded uninstall must retain its namespace by default"
fi
grep -Fqx 'kubectl --context kind-agent-os -n portable-agent-os delete rolebinding agent-os-firstmate-runtime --ignore-not-found' "$CALLS" || \
  fail "uninstall must remove namespace runtime binding regardless of current inputs"
grep -Fqx 'kubectl --context kind-agent-os -n portable-agent-os delete role agent-os-firstmate-runtime --ignore-not-found' "$CALLS" || \
  fail "uninstall must remove namespace runtime Role regardless of current inputs"
pass "routine uninstall removes namespaced resources without cluster-wide authority"

: > "$CALLS"
uninstall_residue_out=''
uninstall_residue_rc=0
uninstall_residue_out=$(AGENT_OS_TEST_NAMESPACE_STATE=owned AGENT_OS_TEST_WORKLOAD_STATE=cluster-admin \
  run_generic uninstall --yes 2>&1) || uninstall_residue_rc=$?
[ "$uninstall_residue_rc" -eq 3 ] || \
  fail "cluster-admin uninstall must report residue with exit 3: $uninstall_residue_out"
if grep -E 'kubectl .* (get|delete) clusterrolebinding' "$CALLS" >/dev/null; then
  fail "routine uninstall must report cluster residue without inspecting or deleting it"
fi
assert_contains "$uninstall_residue_out" 'cleanup-cluster-rbac --yes' \
  "cluster-admin uninstall must print the exact privileged cleanup command"
pass "routine uninstall reports cluster-scoped residue for separate cleanup"

: > "$CALLS"
AGENT_OS_TEST_NAMESPACE_STATE=owned AGENT_OS_TEST_WORKLOAD_STATE=namespace \
  run_generic uninstall --yes --delete-namespace
grep -Fqx 'kubectl --context kind-agent-os delete namespace portable-agent-os' "$CALLS" || \
  fail "optional namespace deletion must target only the exactly owned namespace"
grep -Fq 'kubectl --context kind-agent-os api-resources --verbs=list --namespaced -o name' "$CALLS" || \
  fail "optional namespace deletion must inventory every listable namespaced resource type"
pass "optional namespace deletion proves ownership and no foreign resources"

: > "$CALLS"
foreign_resource_out=''
foreign_resource_rc=0
foreign_resource_out=$(AGENT_OS_TEST_NAMESPACE_STATE=owned AGENT_OS_TEST_WORKLOAD_STATE=namespace \
  AGENT_OS_TEST_FOREIGN_RESOURCE=foreign-workload run_generic uninstall --yes --delete-namespace 2>&1) || \
  foreign_resource_rc=$?
[ "$foreign_resource_rc" -eq 2 ] || \
  fail "foreign namespace resources must block namespace deletion: $foreign_resource_out"
if grep -F 'delete namespace portable-agent-os' "$CALLS" >/dev/null; then
  fail "namespace deletion must fail closed when foreign resources remain"
fi
pass "optional namespace deletion refuses foreign resources"
