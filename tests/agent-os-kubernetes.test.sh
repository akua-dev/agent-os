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
PURGE_EVIDENCE="$TMP/purge-evidence.log"

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
stdin_data=''
if [ "${*: -2}" = "-f -" ]; then
  stdin_data=$(cat)
  printf '%s\n' "$stdin_data" >> "$AGENT_OS_STDIN_LOG"
  stdin_kind=$(printf '%s\n' "$stdin_data" | awk '$1 == "kind:" { print $2; exit }')
  printf 'stdin-kind %s\n' "$stdin_kind" >> "$AGENT_OS_TEST_LOG"
fi
if [ "${AGENT_OS_TEST_FAIL_APPLY:-0}" = 1 ] && [[ " $* " = *" create -f - "* ]] && \
  [ "$stdin_kind" = Pod ]; then
  exit 1
fi
if [ "${AGENT_OS_TEST_LOCK_STATE:-free}" != free ] && [[ " $* " = *" create -f - "* ]] && \
  [ "$stdin_kind" = Lease ]; then
  exit 1
fi
if [ "${AGENT_OS_TEST_FAIL_PVC_PATCH:-0}" = 1 ] && [[ " $* " = *" patch pvc "* ]]; then
  exit 1
fi
if [ "${AGENT_OS_TEST_FAIL_POD_LIST:-0}" = 1 ] && [[ " $* " = *" get pods -o json "* ]]; then
  exit 1
fi
if [ "${AGENT_OS_TEST_FAIL_GENERIC_APPLY:-0}" = 1 ] && [[ " $* " = *" apply -f "* ]] && \
  [[ " $* " != *" apply -f - "* ]]; then
  exit 1
fi
if [ "${AGENT_OS_TEST_FAIL_WAIT:-0}" = 1 ] && [ "${1:-}" = -n ] && [ "${3:-}" = wait ]; then
  exit 1
fi
if [ "${AGENT_OS_TEST_LOCK_STATE:-free}" = held ] && [[ " $* " = *" wait --for=delete lease/"* ]]; then
  exit 1
fi
if [ "${AGENT_OS_TEST_FAIL_ANNOTATE:-0}" = 1 ] && [[ " $* " = *" annotate statefulset agent-os-firstmate "* ]]; then
  exit 1
fi
if [ -n "${AGENT_OS_TEST_FAIL_DELETE_FILE:-}" ] && [[ " $* " = *" delete "* ]] && \
  [[ " $* " = *"$AGENT_OS_TEST_FAIL_DELETE_FILE"* ]]; then
  exit 1
fi
case " $* " in
  *" get pod agent-os-crewmate-"*" --ignore-not-found -o jsonpath="*)
    id=${AGENT_OS_TEST_CREWMATE_ID:-scout-1}
    pod_state=${AGENT_OS_TEST_POD_STATE:-absent}
    if grep -F 'stdin-kind Pod' "$AGENT_OS_TEST_LOG" >/dev/null; then
      pod_state=${AGENT_OS_TEST_POD_AFTER_APPLY:-owned}
    fi
    last_create=$(grep -Fn 'stdin-kind Pod' "$AGENT_OS_TEST_LOG" | tail -n 1 | cut -d: -f1)
    last_delete=$(grep -Fn '/pods/agent-os-crewmate-' "$AGENT_OS_TEST_LOG" | grep 'delete --raw' | tail -n 1 | cut -d: -f1)
    if [ -n "$last_delete" ] && { [ -z "$last_create" ] || [ "$last_delete" -gt "$last_create" ]; }; then
      pod_state=absent
    fi
    case "$pod_state" in
      absent) ;;
      owned)
        printf 'agent-os-crewmate-%s\tagent-os\t%s\tagent-os-firstmate:agent-os-demo' "$id" "$id"
        [[ " $* " != *'.metadata.uid'* ]] || printf '\toperation-test\tuid-owned\trv-pod-owned'
        ;;
      replacement)
        printf 'agent-os-crewmate-%s\tagent-os\t%s\tagent-os-firstmate:agent-os-demo' "$id" "$id"
        [[ " $* " != *'.metadata.uid'* ]] || printf '\tother-operation\tuid-replacement\trv-pod-replacement'
        ;;
      foreign)
        printf 'agent-os-crewmate-%s\tother\tother\tother-installation' "$id"
        [[ " $* " != *'.metadata.uid'* ]] || printf '\tother-operation\tuid-foreign\trv-pod-foreign'
        ;;
    esac
    ;;
  *" get pvc agent-os-crewmate-"*" --ignore-not-found -o jsonpath="*)
    id=${AGENT_OS_TEST_CREWMATE_ID:-scout-1}
    pvc_state=${AGENT_OS_TEST_PVC_STATE:-absent}
    if grep -F 'stdin-kind PersistentVolumeClaim' "$AGENT_OS_TEST_LOG" >/dev/null; then
      [ "$pvc_state" != absent ] || pvc_state=owned
    fi
    case "$pvc_state" in
      absent) ;;
      owned) printf 'agent-os-crewmate-%s-home\tagent-os\t%s\tagent-os-firstmate:agent-os-demo\tpending\t\toperation-test\t\tuid-pvc-owned\trv-pvc-owned' "$id" "$id" ;;
      clean) printf 'agent-os-crewmate-%s-home\tagent-os\t%s\tagent-os-firstmate:agent-os-demo\tclean\t2026-07-13T12:00:00Z\toperation-test\toperation-test\tuid-pvc-owned\trv-pvc-owned' "$id" "$id" ;;
      stale-clean) printf 'agent-os-crewmate-%s-home\tagent-os\t%s\tagent-os-firstmate:agent-os-demo\tclean\t2026-07-13T12:00:00Z\toperation-test\told-operation\tuid-pvc-owned\trv-pvc-owned' "$id" "$id" ;;
      invalid-checkpoint) printf 'agent-os-crewmate-%s-home\tagent-os\t%s\tagent-os-firstmate:agent-os-demo\tclean\t2026\toperation-test\toperation-test\tuid-pvc-owned\trv-pvc-owned' "$id" "$id" ;;
      foreign) printf 'agent-os-crewmate-%s-home\tother\tother\tother-installation\tclean\t2026-07-13T12:00:00Z\toperation-test\toperation-test\tuid-pvc-foreign\trv-pvc-foreign' "$id" ;;
    esac
    ;;
  *" get lease agent-os-crewmate-"*" --ignore-not-found -o jsonpath="*)
    id=${AGENT_OS_TEST_CREWMATE_ID:-scout-1}
    case "${AGENT_OS_TEST_LOCK_STATE:-free}" in
      held) printf 'agent-os-crewmate-%s-lifecycle\tagent-os\t%s\tagent-os-firstmate:agent-os-demo\tother-operation\tuid-lock-other' "$id" "$id" ;;
      foreign) printf 'agent-os-crewmate-%s-lifecycle\tother\tother\tother-installation\tother-operation\tuid-lock-foreign' "$id" ;;
      *)
        if grep -F 'stdin-kind Lease' "$AGENT_OS_TEST_LOG" >/dev/null; then
          printf 'agent-os-crewmate-%s-lifecycle\tagent-os\t%s\tagent-os-firstmate:agent-os-demo\toperation-test\tuid-lock' "$id" "$id"
        fi
        ;;
    esac
    ;;
  *" get namespace "*" --ignore-not-found -o name "*)
    namespace_state=${AGENT_OS_TEST_NAMESPACE_STATE:-absent}
    if grep -F ' apply -f ' "$AGENT_OS_TEST_LOG" >/dev/null; then
      namespace_state=${AGENT_OS_TEST_NAMESPACE_AFTER_APPLY:-$namespace_state}
    fi
    case "$namespace_state" in
      absent) ;;
      *) printf 'namespace/%s\n' "${AGENT_OS_TEST_NAMESPACE:-portable-agent-os}" ;;
    esac
    ;;
  *" get namespace "*" -o jsonpath="*|*" get Namespace "*" -o jsonpath="*)
    namespace_state=${AGENT_OS_TEST_NAMESPACE_STATE:-absent}
    if grep -F ' apply -f ' "$AGENT_OS_TEST_LOG" >/dev/null; then
      namespace_state=${AGENT_OS_TEST_NAMESPACE_AFTER_APPLY:-$namespace_state}
    fi
    case "$namespace_state" in
      owned)
        if [[ " $* " = *'.metadata.uid'* ]]; then
          printf '%s\tagent-os\tagent-os-firstmate:%s\tuid-namespace\toperation-test\tTrue\t[]' \
            "${AGENT_OS_TEST_NAMESPACE:-portable-agent-os}" "${AGENT_OS_TEST_NAMESPACE:-portable-agent-os}"
        else
          printf 'agent-os\tagent-os-firstmate:%s' "${AGENT_OS_TEST_NAMESPACE:-portable-agent-os}"
        fi
        ;;
      foreign) printf 'other\tother-installation' ;;
      *) printf '\t' ;;
    esac
    ;;
  *" get statefulset agent-os-firstmate --ignore-not-found -o jsonpath="*)
    workload_state=${AGENT_OS_TEST_WORKLOAD_STATE:-absent}
    if grep -F ' apply -f ' "$AGENT_OS_TEST_LOG" >/dev/null; then
      workload_state=${AGENT_OS_TEST_WORKLOAD_AFTER_APPLY:-$workload_state}
    fi
    case "$workload_state" in
      absent) ;;
      namespace) printf 'agent-os-firstmate\tnamespace\t\tagent-os\tagent-os-firstmate:portable-agent-os' ;;
      cluster-admin) printf 'agent-os-firstmate\tcluster-admin\t\tagent-os\tagent-os-firstmate:portable-agent-os' ;;
      none) printf 'agent-os-firstmate\tnone\t\tagent-os\tagent-os-firstmate:portable-agent-os' ;;
      pending) printf 'agent-os-firstmate\tnamespace\trequired\tagent-os\tagent-os-firstmate:portable-agent-os' ;;
      unknown) printf 'agent-os-firstmate\t\t\tagent-os\tagent-os-firstmate:portable-agent-os' ;;
      foreign) printf 'agent-os-firstmate\tnamespace\t\tother\tother-installation' ;;
    esac
    ;;
  *" get StatefulSet agent-os-firstmate --ignore-not-found -o jsonpath="*|\
  *" get ServiceAccount agent-os-firstmate --ignore-not-found -o jsonpath="*|\
  *" get PersistentVolumeClaim agent-os-firstmate-home --ignore-not-found -o jsonpath="*|\
  *" get Service agent-os-firstmate --ignore-not-found -o jsonpath="*|\
  *" get Role agent-os-firstmate-runtime --ignore-not-found -o jsonpath="*|\
  *" get RoleBinding agent-os-firstmate-runtime --ignore-not-found -o jsonpath="*)
    kind=''
    name=''
    case " $* " in
      *" StatefulSet "*) kind=StatefulSet; name=agent-os-firstmate ;;
      *" ServiceAccount "*) kind=ServiceAccount; name=agent-os-firstmate ;;
      *" PersistentVolumeClaim "*) kind=PersistentVolumeClaim; name=agent-os-firstmate-home ;;
      *" Service "*) kind=Service; name=agent-os-firstmate ;;
      *" RoleBinding "*) kind=RoleBinding; name=agent-os-firstmate-runtime ;;
      *" Role "*) kind=Role; name=agent-os-firstmate-runtime ;;
    esac
    resource_state=${AGENT_OS_TEST_RESOURCE_STATE:-absent}
    if grep -F ' apply -f ' "$AGENT_OS_TEST_LOG" >/dev/null; then
      resource_state=${AGENT_OS_TEST_RESOURCE_AFTER_APPLY:-$resource_state}
    fi
    case "$resource_state" in
      absent) ;;
      owned)
        printf '%s\tagent-os\tagent-os-firstmate:portable-agent-os' "$name"
        if [[ " $* " = *'.spec.replicas'* ]]; then
          printf '\tuid-statefulset\toperation-test\t\t[kubernetes.io/pvc-protection]\t1\t1\t0\t0\t0\trev-old\trev-new\t2\t1'
        elif [[ " $* " = *'.metadata.uid'* ]]; then
          printf '\tuid-%s\toperation-test\tTrue\t[kubernetes.io/pvc-protection]' "$(printf '%s' "$kind" | tr '[:upper:]' '[:lower:]')"
        fi
        ;;
      foreign) printf '%s\tother\tother-installation' "$name" ;;
    esac
    ;;
  *" get role agent-os-firstmate-runtime -o json "*)
    if [ "${AGENT_OS_TEST_RBAC_STATE:-exact}" = bad-rules ]; then
      printf '%s\n' '{"metadata":{"name":"agent-os-firstmate-runtime"},"rules":[]}'
    else
      printf '%s\n' '{"metadata":{"name":"agent-os-firstmate-runtime"},"rules":[{"apiGroups":[""],"resources":["pods","persistentvolumeclaims"],"verbs":["get","list","watch","create","delete","patch"]},{"apiGroups":[""],"resources":["pods/log","pods/exec"],"verbs":["get","list","watch","create","delete"]},{"apiGroups":["apps"],"resources":["statefulsets"],"verbs":["get","list","watch"]},{"apiGroups":["coordination.k8s.io"],"resources":["leases"],"verbs":["get","list","watch","create","delete"]}]}'
    fi
    ;;
  *" get rolebinding agent-os-firstmate-runtime -o json "*)
    if [ "${AGENT_OS_TEST_RBAC_STATE:-exact}" = extra-subject ]; then
      printf '%s\n' '{"roleRef":{"apiGroup":"rbac.authorization.k8s.io","kind":"Role","name":"agent-os-firstmate-runtime"},"subjects":[{"kind":"ServiceAccount","name":"agent-os-firstmate","namespace":"portable-agent-os"},{"kind":"ServiceAccount","name":"foreign","namespace":"portable-agent-os"}]}'
    else
      printf '%s\n' '{"roleRef":{"apiGroup":"rbac.authorization.k8s.io","kind":"Role","name":"agent-os-firstmate-runtime"},"subjects":[{"kind":"ServiceAccount","name":"agent-os-firstmate","namespace":"portable-agent-os"}]}'
    fi
    ;;
  *" get role agent-os-firstmate-runtime -o jsonpath="*)
    printf 'agent-os-firstmate-runtime'
    ;;
  *" get rolebinding agent-os-firstmate-runtime -o jsonpath="*)
    printf 'Role\tagent-os-firstmate-runtime\tServiceAccount\tagent-os-firstmate\t%s' \
      "${AGENT_OS_TEST_NAMESPACE:-portable-agent-os}"
    ;;
  *" get clusterrolebinding agent-os-firstmate-"*" --ignore-not-found -o jsonpath="*|\
  *" get ClusterRoleBinding agent-os-firstmate-"*" --ignore-not-found -o jsonpath="*)
    cluster_state=${AGENT_OS_TEST_CLUSTER_RBAC_STATE:-absent}
    if grep -F ' apply -f ' "$AGENT_OS_TEST_LOG" >/dev/null; then
      cluster_state=${AGENT_OS_TEST_CLUSTER_RBAC_AFTER_APPLY:-$cluster_state}
    fi
    case "$cluster_state" in
      absent) ;;
      owned)
        printf 'agent-os-firstmate-%s\tagent-os\tagent-os-firstmate:%s' \
          "${AGENT_OS_TEST_NAMESPACE:-portable-agent-os}" "${AGENT_OS_TEST_NAMESPACE:-portable-agent-os}"
        [[ " $* " != *'.metadata.uid'* ]] || printf '\tuid-clusterrolebinding\toperation-test\tTrue\t[]'
        ;;
      foreign) printf 'agent-os-firstmate-portable-agent-os\tother\tother-installation' ;;
    esac
    ;;
  *" get Pod agent-os-firstmate-0 --ignore-not-found -o jsonpath="*)
    case "${AGENT_OS_TEST_PRIMARY_POD_STATE:-absent}" in
      absent) ;;
      owned)
        printf 'agent-os-firstmate-0\tagent-os\tagent-os-firstmate:portable-agent-os\tuid-pod\toperation-test\tFalse\t[kubernetes.io/pvc-protection]'
        ;;
      foreign) printf 'agent-os-firstmate-0\tother\tother-installation\tuid-foreign\tother-operation\tFalse\t[]' ;;
    esac
    ;;
  *" api-resources --verbs=list --namespaced -o name "*)
    printf '%s\n' pods serviceaccounts configmaps leases.coordination.k8s.io
    ;;
  *" get pods -o name "*)
    [ -z "${AGENT_OS_TEST_FOREIGN_RESOURCE:-}" ] || printf 'pod/%s\n' "$AGENT_OS_TEST_FOREIGN_RESOURCE"
    ;;
  *" get pods -o json "*)
    if [ "${AGENT_OS_TEST_PVC_ATTACHED:-0}" = 1 ]; then
      printf '%s\n' '{"items":[{"spec":{"volumes":[{"persistentVolumeClaim":{"claimName":"agent-os-crewmate-scout-1-home"}}]}}]}'
    else
      printf '%s\n' '{"items":[]}'
    fi
    ;;
  *" get serviceaccounts -o name "*) printf '%s\n' serviceaccount/default ;;
  *" get configmaps -o name "*) printf '%s\n' configmap/kube-root-ca.crt ;;
  *" get leases.coordination.k8s.io -o name "*)
    [ -z "${AGENT_OS_TEST_FOREIGN_LEASE:-}" ] || printf 'lease/%s\n' "$AGENT_OS_TEST_FOREIGN_LEASE"
    ;;
esac
SH
chmod +x "$FAKEBIN/kubectl"

run_launcher() {
  PATH="$FAKEBIN:$PATH" AGENT_OS_TEST_LOG="$CALLS" AGENT_OS_STDIN_LOG="$STDIN_LOG" \
    AGENT_OS_IN_CLUSTER=1 AGENT_OS_NAMESPACE=agent-os-demo AGENT_OS_IMAGE=agent-os:local-test \
    AGENT_OS_IMAGE_PULL_POLICY=Never AGENT_OS_AI_SECRET=scout-1-ai-auth \
    AGENT_OS_OPERATION_ID=operation-test AGENT_OS_PURGE_EVIDENCE_FILE="$PURGE_EVIDENCE" \
    "$LAUNCHER" "$@"
}

: > "$CALLS"
run_launcher create scout-1
if grep -F ' apply -f -' "$CALLS" >/dev/null; then
  fail "crewmate create must never adopt a resource through apply"
fi
grep -Fqx 'kubectl -n agent-os-demo create -f -' "$CALLS" || \
  fail "crewmate resources must use create-only semantics when absent"
[ "$(grep -Fc 'kind: PersistentVolumeClaim' "$STDIN_LOG")" -eq 1 ] || fail "create must emit one PVC"
[ "$(grep -Fc 'kind: Pod' "$STDIN_LOG")" -eq 1 ] || fail "create must emit one Pod"
assert_grep 'agent-os.dev/crewmate: scout-1' "$STDIN_LOG" "child resources need the stable crewmate label"
assert_grep 'app.kubernetes.io/managed-by: agent-os' "$STDIN_LOG" \
  "child resources need the exact Agent OS ownership label"
assert_grep 'agent-os.dev/installation-id: agent-os-firstmate:agent-os-demo' "$STDIN_LOG" \
  "child resources need the exact installation identity"
assert_grep 'agent-os.dev/operation-id: operation-test' "$STDIN_LOG" \
  "each crewmate creation attempt must carry its unique operation identity"
assert_grep 'automountServiceAccountToken: false' "$STDIN_LOG" "children must not receive Kubernetes credentials"
assert_grep 'claimName: agent-os-crewmate-scout-1-home' "$STDIN_LOG" "child work must use its own PVC"
assert_no_grep 'hostUsers: false' "$STDIN_LOG" "OrbStack children must not request unsupported Pod user namespaces"
assert_grep 'runAsUser: 0' "$STDIN_LOG" "children must run as container root"
assert_grep 'name: agent-os-init' "$STDIN_LOG" "children must seed persistent tools"
assert_grep 'mountPath: /usr/local' "$STDIN_LOG" "children must persist /usr/local"
assert_grep 'mountPath: /var/run/secrets/agent-os/pi' "$STDIN_LOG" \
  "children must mount AI authorization outside writable Pi state"
assert_grep 'name: AGENT_OS_PI_AUTH_FILE' "$STDIN_LOG" \
  "children must expose the projected authorization path to the entrypoint"
assert_grep 'value: /var/run/secrets/agent-os/pi/auth.json' "$STDIN_LOG" \
  "the entrypoint must receive only the projected auth.json path"
assert_no_grep 'mountPath: /home/agent/.pi/agent' "$STDIN_LOG" \
  "the read-only Secret projection must not shadow writable Pi state"
assert_no_grep 'subPath: auth.json' "$STDIN_LOG" \
  "projected AI authorization must support Secret rotation without a subPath mount"
assert_grep 'path: auth.json' "$STDIN_LOG" \
  "the projected authorization directory must expose only the approved auth.json key"
assert_grep 'optional: false' "$STDIN_LOG" \
  "a missing Secret or auth.json key must keep the crewmate Pod unready"
assert_grep 'name: scout-1-ai-auth' "$STDIN_LOG" \
  "children must reference the explicitly selected namespace-local Secret"
assert_grep 'readOnly: true' "$STDIN_LOG" "child AI authorization must be read-only"
assert_grep 'readinessProbe:' "$STDIN_LOG" "child readiness must wait for Herdr health"
assert_grep 'herdr' "$STDIN_LOG" "child readiness must invoke Herdr"
assert_grep 'status' "$STDIN_LOG" "child readiness must inspect Herdr status"
grep -Fqx 'kubectl -n agent-os-demo wait --for=condition=Ready pod/agent-os-crewmate-scout-1 --timeout=180s' "$CALLS" || \
  fail "create must fail when the authorized Secret cannot produce a ready Pod"
pass "crewmate create emits one isolated Pod and PVC"

: > "$CALLS"
if AGENT_OS_TEST_POD_STATE=foreign run_launcher create scout-1 >/dev/null 2>&1; then
  fail "crewmate create must reject a same-name foreign Pod"
fi
if grep -F 'stdin-kind Pod' "$CALLS" >/dev/null; then
  fail "crewmate create must reject foreign ownership before Pod creation"
fi
pass "crewmate create refuses foreign deterministic-name resources"

: > "$CALLS"
if PATH="$FAKEBIN:$PATH" AGENT_OS_TEST_LOG="$CALLS" AGENT_OS_STDIN_LOG="$STDIN_LOG" \
  AGENT_OS_IN_CLUSTER=1 AGENT_OS_NAMESPACE=agent-os-demo AGENT_OS_IMAGE=agent-os:local-test \
  "$LAUNCHER" create scout-1 >/dev/null 2>&1; then
  fail "crewmate create must require an explicit AI Secret reference"
fi
[ ! -s "$CALLS" ] || fail "missing AI Secret reference must fail before kubectl"
pass "crewmate create requires an explicit AI Secret grant"

: > "$CALLS"
if AGENT_OS_TEST_FAIL_WAIT=1 AGENT_OS_TEST_POD_AFTER_APPLY=owned run_launcher create scout-1 >/dev/null 2>&1; then
  fail "crewmate create must fail when its authorized Secret cannot produce a ready Pod"
fi
grep -Fqx 'kubectl -n agent-os-demo delete --raw /api/v1/namespaces/agent-os-demo/pods/agent-os-crewmate-scout-1 -f -' "$CALLS" || \
  fail "failed create must use an atomic UID-preconditioned delete"
assert_grep '"uid":"uid-owned"' "$STDIN_LOG" \
  "failed create must precondition deletion on the observed Pod UID"
if grep -F 'delete pvc agent-os-crewmate-scout-1-home' "$CALLS" >/dev/null; then
  fail "failed create must retain the crewmate PVC for an authorized retry"
fi
pass "crewmate create fails closed while retaining its persistent home"

: > "$CALLS"
partial_out=''
partial_rc=0
partial_out=$(AGENT_OS_TEST_FAIL_APPLY=1 AGENT_OS_TEST_POD_AFTER_APPLY=owned \
  run_launcher create scout-1 2>&1) || partial_rc=$?
[ "$partial_rc" -eq 1 ] || fail "partial apply must fail after cleanup: $partial_out"
assert_contains "$partial_out" 'uid-owned' \
  "partial apply cleanup must report the exact newly created Pod UID"
assert_grep 'metadata.uid' "$CALLS" \
  "partial apply cleanup must collect exact Pod UID evidence"
grep -Fqx 'kubectl -n agent-os-demo delete --raw /api/v1/namespaces/agent-os-demo/pods/agent-os-crewmate-scout-1 -f -' "$CALLS" || \
  fail "partial apply cleanup must use an atomic UID-preconditioned delete"
assert_grep '"uid":"uid-owned"' "$STDIN_LOG" \
  "partial apply cleanup must bind deletion to the observed Pod UID"
assert_no_grep 'delete pvc agent-os-crewmate-scout-1-home' "$CALLS" \
  "partial apply cleanup must retain the persistent home"
pass "crewmate partial create cleans only a newly created owned Pod"

: > "$CALLS"
replacement_out=''
replacement_rc=0
replacement_out=$(AGENT_OS_TEST_FAIL_APPLY=1 AGENT_OS_TEST_POD_AFTER_APPLY=replacement \
  run_launcher create scout-1 2>&1) || replacement_rc=$?
[ "$replacement_rc" -eq 1 ] || fail "replacement partial apply must remain failed: $replacement_out"
assert_contains "$replacement_out" 'replacement or ownership mismatch retained' \
  "partial apply must report a replacement instead of deleting it"
if grep -F '/pods/agent-os-crewmate-scout-1' "$CALLS" | grep -F 'delete --raw' >/dev/null; then
  fail "partial apply must retain a same-name Pod from another operation"
fi

: > "$CALLS"
AGENT_OS_TEST_POD_STATE=owned AGENT_OS_TEST_PVC_STATE=owned run_launcher stop scout-1
grep -Fqx 'kubectl -n agent-os-demo delete --raw /api/v1/namespaces/agent-os-demo/pods/agent-os-crewmate-scout-1 -f -' "$CALLS" || \
  fail "stop must UID-precondition deletion of the exactly owned crewmate Pod"
grep -Fqx 'kubectl -n agent-os-demo wait --for=delete pod/agent-os-crewmate-scout-1 --timeout=180s' "$CALLS" || \
  fail "stop must prove Pod absence before checkpointing can begin"
delete_line=$(grep -Fn '/pods/agent-os-crewmate-scout-1' "$CALLS" | grep 'delete --raw' | head -n 1 | cut -d: -f1)
invalidate_line=$(grep -Fn 'patch pvc agent-os-crewmate-scout-1-home --type=merge' "$CALLS" | head -n 1 | cut -d: -f1)
quiesced_line=$(grep -Fn 'patch pvc agent-os-crewmate-scout-1-home --type=merge' "$CALLS" | tail -n 1 | cut -d: -f1)
[ -n "$delete_line" ] && [ -n "$invalidate_line" ] && [ -n "$quiesced_line" ] && \
  [ "$invalidate_line" -lt "$delete_line" ] && [ "$delete_line" -lt "$quiesced_line" ] || \
  fail "stop must invalidate before deletion and record quiescence only after Pod absence"
if grep -F 'delete pvc agent-os-crewmate-scout-1-home' "$CALLS" >/dev/null; then
  fail "stop must preserve the crewmate persistent home"
fi
pass "crewmate stop preserves its persistent home"

: > "$CALLS"
if AGENT_OS_TEST_POD_STATE=owned AGENT_OS_TEST_PVC_STATE=clean AGENT_OS_TEST_FAIL_PVC_PATCH=1 \
  run_launcher stop scout-1 >/dev/null 2>&1; then
  fail "stop must fail when checkpoint invalidation cannot be recorded"
fi
if grep -F '/pods/agent-os-crewmate-scout-1' "$CALLS" | grep -F 'delete --raw' >/dev/null; then
  fail "stop must leave the Pod running when checkpoint invalidation fails"
fi
pass "crewmate stop invalidates checkpoint evidence before Pod deletion"

: > "$CALLS"
AGENT_OS_TEST_POD_STATE=owned AGENT_OS_TEST_PVC_STATE=owned run_launcher restart scout-1
delete_line=$(grep -Fn '/pods/agent-os-crewmate-scout-1' "$CALLS" | grep 'delete --raw' | head -n 1 | cut -d: -f1)
create_line=$(grep -Fn 'stdin-kind Pod' "$CALLS" | tail -n 1 | cut -d: -f1)
[ -n "$delete_line" ] && [ -n "$create_line" ] && [ "$delete_line" -lt "$create_line" ] || \
  fail "restart must replace the owned Pod on its retained PVC"
if grep -F 'delete pvc agent-os-crewmate-scout-1-home' "$CALLS" >/dev/null; then
  fail "restart must preserve the crewmate persistent home"
fi
pass "crewmate restart replaces only its Pod"

: > "$CALLS"
delete_out=''
delete_rc=0
delete_out=$(run_launcher delete scout-1 2>&1) || delete_rc=$?
[ "$delete_rc" -eq 2 ] || fail "legacy delete must refuse destructive ambiguity: $delete_out"
[ ! -s "$CALLS" ] || fail "legacy delete must not mutate Pod or PVC state"
pass "legacy delete never silently destroys persistent work"

: > "$CALLS"
purge_out=''
purge_rc=0
purge_out=$(run_launcher purge scout-1 2>&1) || purge_rc=$?
[ "$purge_rc" -eq 2 ] || fail "purge without --yes must exit 2: $purge_out"
assert_contains "$purge_out" 'agent-os-crewmate-scout-1-home' \
  "unconfirmed purge must display the exact persistent target"
[ ! -s "$CALLS" ] || fail "unconfirmed purge must not query or mutate cluster state"

: > "$CALLS"
if AGENT_OS_TEST_POD_STATE=owned AGENT_OS_TEST_PVC_STATE=clean run_launcher purge scout-1 --yes >/dev/null 2>&1; then
  fail "purge must refuse a clean checkpoint while the owned Pod can still write"
fi
assert_no_grep 'delete pvc agent-os-crewmate-scout-1-home' "$CALLS" \
  "purge must not delete a home while its Pod still exists"

: > "$CALLS"
if AGENT_OS_TEST_POD_STATE=owned AGENT_OS_TEST_PVC_STATE=owned run_launcher purge scout-1 --yes >/dev/null 2>&1; then
  fail "purge must reject a persistent home without a clean checkpoint"
fi
if grep -F 'delete pvc' "$CALLS" >/dev/null; then
  fail "purge must not delete a home without a clean checkpoint"
fi

: > "$CALLS"
if AGENT_OS_TEST_POD_STATE=owned AGENT_OS_TEST_PVC_STATE=invalid-checkpoint run_launcher purge scout-1 --yes >/dev/null 2>&1; then
  fail "purge must reject a malformed checkpoint timestamp"
fi
assert_no_grep 'delete pvc agent-os-crewmate-scout-1-home' "$CALLS" \
  "purge must not delete a home with malformed checkpoint evidence"

: > "$CALLS"
if AGENT_OS_TEST_POD_STATE=absent AGENT_OS_TEST_PVC_STATE=stale-clean run_launcher purge scout-1 --yes >/dev/null 2>&1; then
  fail "purge must reject checkpoint evidence from before the latest stop"
fi
assert_no_grep 'delete pvc agent-os-crewmate-scout-1-home' "$CALLS" \
  "purge must not delete a home using stale clean checkpoint evidence"

: > "$CALLS"
: > "$PURGE_EVIDENCE"
AGENT_OS_TEST_POD_STATE=absent AGENT_OS_TEST_PVC_STATE=clean run_launcher purge scout-1 --yes
assert_no_grep 'delete pod agent-os-crewmate-scout-1' "$CALLS" \
  "purge must accept checkpoint evidence only after the Pod is absent"
grep -Fqx 'kubectl -n agent-os-demo delete --raw /api/v1/namespaces/agent-os-demo/persistentvolumeclaims/agent-os-crewmate-scout-1-home -f -' "$CALLS" || \
  fail "purge must atomically delete the exactly owned persistent home"
assert_grep '"uid":"uid-pvc-owned","resourceVersion":"rv-pvc-owned"' "$STDIN_LOG" \
  "purge must precondition deletion on the captured PVC UID and resourceVersion"
assert_grep 'purge-complete' "$PURGE_EVIDENCE" "purge must record non-secret completion evidence"
assert_no_grep 'scout-1-ai-auth' "$PURGE_EVIDENCE" "purge evidence must never contain credential references"
pass "crewmate purge requires confirmation and a clean checkpoint"

: > "$CALLS"
if AGENT_OS_TEST_POD_STATE=absent AGENT_OS_TEST_PVC_STATE=clean AGENT_OS_TEST_PVC_ATTACHED=1 \
  run_launcher purge scout-1 --yes >/dev/null 2>&1; then
  fail "purge must refuse a PVC still referenced by any Pod"
fi
if grep -F '/persistentvolumeclaims/agent-os-crewmate-scout-1-home' "$CALLS" | grep -F 'delete --raw' >/dev/null; then
  fail "purge must retain an attached persistent home"
fi
pass "crewmate purge rejects attached persistent homes"

: > "$CALLS"
if AGENT_OS_TEST_POD_STATE=absent AGENT_OS_TEST_PVC_STATE=clean AGENT_OS_TEST_FAIL_POD_LIST=1 \
  run_launcher purge scout-1 --yes >/dev/null 2>&1; then
  fail "purge must fail closed when Pod attachments cannot be inventoried"
fi
if grep -F '/persistentvolumeclaims/agent-os-crewmate-scout-1-home' "$CALLS" | grep -F 'delete --raw' >/dev/null; then
  fail "purge must retain the PVC after an attachment inventory failure"
fi
pass "crewmate purge fails closed on attachment inventory errors"

: > "$CALLS"
lock_out=''
lock_rc=0
lock_out=$(AGENT_OS_TEST_LOCK_STATE=held run_launcher stop scout-1 2>&1) || lock_rc=$?
[ "$lock_rc" -eq 3 ] || fail "bounded lifecycle lock contention must exit incomplete: $lock_out"
assert_contains "$lock_out" "still holds Lease 'agent-os-crewmate-scout-1-lifecycle' after 30s" \
  "lifecycle contention must report the exact holder and bounded timeout"
pass "crewmate lifecycle operations use a bounded coordination lock"

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
  AGENT_OS_CONTEXT=orbstack AGENT_OS_NAMESPACE=agent-os-demo AGENT_OS_IMAGE=agent-os:local-test \
  AGENT_OS_TEST_POD_STATE=owned AGENT_OS_TEST_PVC_STATE=owned "$LAUNCHER" status scout-1
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
operation=$(awk '/^operationId:/{print $2}' "$inputs")
printf 'akua-input-operation %s\n' "$operation" >> "$AGENT_OS_TEST_LOG"
create_namespace=$(awk '/^createNamespace:/{print $2}' "$inputs")
[ -n "$create_namespace" ] || create_namespace=true
cat > "$out/00-pvc.yaml" <<YAML
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: agent-os-firstmate-home
  namespace: $namespace
  labels:
    app.kubernetes.io/managed-by: agent-os
    agent-os.dev/operation-id: $operation
  annotations:
    agent-os.dev/installation-id: agent-os-firstmate:$namespace
YAML
cat > "$out/statefulset.yaml" <<YAML
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: agent-os-firstmate
  namespace: $namespace
  labels:
    app.kubernetes.io/managed-by: agent-os
    agent-os.dev/operation-id: $operation
  annotations:
    agent-os.dev/installation-id: agent-os-firstmate:$namespace
    agent-os.dev/rbac-mode: $rbac
YAML
for resource in ServiceAccount Service; do
  file=$(printf '%s' "$resource" | tr '[:upper:]' '[:lower:]')
  cat > "$out/$file.yaml" <<YAML
apiVersion: v1
kind: $resource
metadata:
  name: agent-os-firstmate
  namespace: $namespace
  labels:
    app.kubernetes.io/managed-by: agent-os
    agent-os.dev/operation-id: $operation
  annotations:
    agent-os.dev/installation-id: agent-os-firstmate:$namespace
YAML
done
if [ "$create_namespace" = true ]; then
  cat > "$out/namespace.yaml" <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: $namespace
  labels:
    app.kubernetes.io/managed-by: agent-os
    agent-os.dev/operation-id: $operation
  annotations:
    agent-os.dev/installation-id: agent-os-firstmate:$namespace
YAML
fi
case "$rbac" in
  namespace)
    for resource in Role RoleBinding; do
      file=$(printf '%s' "$resource" | tr '[:upper:]' '[:lower:]')
      cat > "$out/$file.yaml" <<YAML
apiVersion: rbac.authorization.k8s.io/v1
kind: $resource
metadata:
  name: agent-os-firstmate-runtime
  namespace: $namespace
  labels:
    app.kubernetes.io/managed-by: agent-os
    agent-os.dev/operation-id: $operation
  annotations:
    agent-os.dev/installation-id: agent-os-firstmate:$namespace
YAML
    done
    ;;
  cluster-admin)
    cat > "$out/clusterrolebinding.yaml" <<YAML
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: agent-os-firstmate-$namespace
  labels:
    app.kubernetes.io/managed-by: agent-os
    agent-os.dev/operation-id: $operation
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
    AGENT_OS_OPERATION_ID=operation-test \
    AGENT_OS_CONTEXT=kind-agent-os AGENT_OS_NAMESPACE=portable-agent-os "$GENERIC" "$@"
}

: > "$CALLS"
run_generic install
grep -Fq -- "akua render --no-agent-mode --package $ROOT/tools/agent-os/packages/firstmate/package.k --inputs " "$CALLS" || \
  fail "generic install must render the canonical package before applying it"
grep -Fq 'kubectl --context kind-agent-os apply -f ' "$CALLS" || \
  fail "generic install must apply only its freshly rendered package output"
grep -Fqx 'akua-input-operation operation-test' "$CALLS" || \
  fail "generic install must label every resource with its unique operation identity"
grep -Fqx 'kubectl --context kind-agent-os -n portable-agent-os rollout status statefulset/agent-os-firstmate --timeout=180s' "$CALLS" || \
  fail "generic install must wait for the rendered Firstmate StatefulSet"
if grep -F 'delete clusterrolebinding' "$CALLS" >/dev/null; then
  fail "fresh namespace-scoped install must not require cluster RBAC deletion authority"
fi
pass "generic install renders and applies the canonical package on an explicit context"

PARTIAL_CLUSTER_INPUTS="$TMP/partial-cluster-inputs.yaml"
sed 's/rbac: namespace/rbac: cluster-admin/' "$GENERIC_INPUTS" > "$PARTIAL_CLUSTER_INPUTS"
: > "$CALLS"
partial_primary_out=''
partial_primary_rc=0
partial_primary_out=$(PATH="$FAKEBIN:$PATH" AGENT_OS_TEST_LOG="$CALLS" \
  AGENT_OS_INPUTS="$PARTIAL_CLUSTER_INPUTS" AGENT_OS_TEST_NAMESPACE=portable-agent-os \
  AGENT_OS_TEST_NAMESPACE_STATE=absent AGENT_OS_TEST_WORKLOAD_STATE=absent \
  AGENT_OS_TEST_NAMESPACE_AFTER_APPLY=owned \
  AGENT_OS_TEST_WORKLOAD_AFTER_APPLY=cluster-admin \
  AGENT_OS_TEST_RESOURCE_AFTER_APPLY=owned AGENT_OS_TEST_CLUSTER_RBAC_AFTER_APPLY=owned \
  AGENT_OS_TEST_FAIL_GENERIC_APPLY=1 AGENT_OS_OPERATION_ID=operation-test \
  AGENT_OS_CONTEXT=kind-agent-os AGENT_OS_NAMESPACE=portable-agent-os \
  "$GENERIC" install 2>&1) || partial_primary_rc=$?
[ "$partial_primary_rc" -eq 3 ] || \
  fail "partial primary apply must exit incomplete with 3: $partial_primary_out"
assert_contains "$partial_primary_out" 'partial apply: StatefulSet/agent-os-firstmate' \
  "failed primary apply must inventory expected namespaced resources"
assert_contains "$partial_primary_out" 'uid=uid-statefulset operation=operation-test desired=1 current=1 ready=0' \
  "failed primary apply must report UID, operation identity, and StatefulSet readiness"
assert_contains "$partial_primary_out" 'residual-authority: ClusterRoleBinding/agent-os-firstmate-portable-agent-os' \
  "failed cluster-admin apply must report the exact residual grant"
assert_contains "$partial_primary_out" 'safe recovery:' \
  "failed primary apply must print a bounded exact recovery command"
assert_contains "$partial_primary_out" 'agent-os-kubernetes.sh upgrade' \
  "failed install with an exact-owned StatefulSet must recover through upgrade"
assert_not_contains "$partial_primary_out" 'cleanup-cluster-rbac --yes' \
  "active cluster-admin authority must not advertise an inapplicable cleanup command"
assert_contains "$partial_primary_out" 'desired=1 current=1 ready=0 updated=0 available=0' \
  "failed StatefulSet rollout must report replica readiness"
assert_contains "$partial_primary_out" 'current-revision=rev-old update-revision=rev-new generation=2 observed-generation=1' \
  "failed StatefulSet rollout must report revision and generation progress"
pass "primary partial apply reports residual resources and authority"

: > "$CALLS"
namespace_partial_out=''
namespace_partial_rc=0
namespace_partial_out=$(AGENT_OS_TEST_WORKLOAD_STATE=namespace AGENT_OS_TEST_NAMESPACE_STATE=owned \
  AGENT_OS_TEST_WORKLOAD_AFTER_APPLY=pending \
  AGENT_OS_TEST_RESOURCE_AFTER_APPLY=owned \
  AGENT_OS_TEST_CLUSTER_RBAC_AFTER_APPLY=owned AGENT_OS_TEST_FAIL_GENERIC_APPLY=1 \
  run_generic upgrade 2>&1) || namespace_partial_rc=$?
[ "$namespace_partial_rc" -eq 3 ] || \
  fail "namespace partial upgrade must exit incomplete with 3: $namespace_partial_out"
assert_contains "$namespace_partial_out" \
  'residual-authority: ClusterRoleBinding/agent-os-firstmate-portable-agent-os' \
  "every failed primary mutation must inspect the deterministic cluster grant"
assert_contains "$namespace_partial_out" 'cleanup-cluster-rbac --yes' \
  "a failed namespaced mutation with residual authority must print exact cleanup"
pass "namespace partial apply reports stale cluster authority"

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
foreign_resource_install_rc=0
AGENT_OS_TEST_NAMESPACE_STATE=unowned AGENT_OS_TEST_RESOURCE_STATE=foreign \
  PATH="$FAKEBIN:$PATH" AGENT_OS_TEST_LOG="$CALLS" AGENT_OS_INPUTS="$UNOWNED_INPUTS" \
  AGENT_OS_TEST_NAMESPACE=portable-agent-os AGENT_OS_TEST_WORKLOAD_STATE=absent \
  AGENT_OS_CONTEXT=kind-agent-os AGENT_OS_NAMESPACE=portable-agent-os \
  "$GENERIC" install >/dev/null 2>&1 || foreign_resource_install_rc=$?
[ "$foreign_resource_install_rc" -eq 2 ] || \
  fail "install must reject same-name foreign namespaced resources"
if grep -F ' apply -f ' "$CALLS" >/dev/null; then
  fail "foreign namespaced ownership must fail before package apply"
fi
pass "install refuses foreign deterministic-name resources"

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
tainted_rbac_rc=0
AGENT_OS_TEST_NAMESPACE_STATE=owned AGENT_OS_TEST_WORKLOAD_STATE=cluster-admin \
  AGENT_OS_TEST_RBAC_STATE=extra-subject run_generic upgrade >/dev/null 2>&1 || tainted_rbac_rc=$?
[ "$tainted_rbac_rc" -eq 2 ] || \
  fail "downgrade must reject a RoleBinding with extra subjects, got $tainted_rbac_rc"
pass "replacement RBAC verification requires exact subject cardinality"

: > "$CALLS"
bad_rules_rc=0
AGENT_OS_TEST_NAMESPACE_STATE=owned AGENT_OS_TEST_WORKLOAD_STATE=cluster-admin \
  AGENT_OS_TEST_RBAC_STATE=bad-rules run_generic upgrade >/dev/null 2>&1 || bad_rules_rc=$?
[ "$bad_rules_rc" -eq 2 ] || \
  fail "downgrade must reject a Role without the exact runtime rules, got $bad_rules_rc"
pass "replacement RBAC verification requires exact rules"

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
grep -Fqx 'kubectl --context kind-agent-os delete clusterrolebinding agent-os-firstmate-portable-agent-os --wait=false' "$CALLS" || \
  fail "privileged cleanup must delete only the exact owned ClusterRoleBinding"
grep -Fqx 'kubectl --context kind-agent-os wait --for=delete clusterrolebinding/agent-os-firstmate-portable-agent-os --timeout=60s' "$CALLS" || \
  fail "privileged cleanup must produce deletion evidence for the exact binding"
pass "privileged cleanup verifies ownership and deletes one exact binding"

: > "$CALLS"
active_cleanup_rc=0
AGENT_OS_TEST_NAMESPACE_STATE=owned AGENT_OS_TEST_WORKLOAD_STATE=cluster-admin \
  AGENT_OS_TEST_CLUSTER_RBAC_STATE=owned run_generic cleanup-cluster-rbac --yes >/dev/null 2>&1 || \
  active_cleanup_rc=$?
[ "$active_cleanup_rc" -eq 2 ] || \
  fail "privileged cleanup must refuse an active cluster-admin grant, got $active_cleanup_rc"
if grep -F 'delete clusterrolebinding' "$CALLS" >/dev/null; then
  fail "cleanup must not revoke an active cluster-admin installation"
fi
pass "privileged cleanup refuses active cluster-admin authority"

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
grep -Fqx 'kubectl --context kind-agent-os -n portable-agent-os delete rolebinding agent-os-firstmate-runtime --ignore-not-found --wait=true --timeout=180s' "$CALLS" || \
  fail "cluster-admin upgrade must delete the stale namespace RoleBinding"
grep -Fqx 'kubectl --context kind-agent-os -n portable-agent-os delete role agent-os-firstmate-runtime --ignore-not-found --wait=true --timeout=180s' "$CALLS" || \
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
AGENT_OS_TEST_NAMESPACE_STATE=owned AGENT_OS_TEST_RESOURCE_STATE=owned \
  AGENT_OS_TEST_WORKLOAD_STATE=namespace run_generic rollback
grep -Fqx 'kubectl --context kind-agent-os -n portable-agent-os rollout undo statefulset/agent-os-firstmate' "$CALLS" || \
  fail "generic rollback must target only the Firstmate StatefulSet"
grep -Fq 'akua render --no-agent-mode' "$CALLS" || \
  fail "rollback must derive its namespace and identity from the current package render"
pass "generic rollback verifies its rendered installation identity"

: > "$CALLS"
foreign_rollback_rc=0
AGENT_OS_TEST_NAMESPACE_STATE=owned AGENT_OS_TEST_RESOURCE_STATE=foreign AGENT_OS_TEST_WORKLOAD_STATE=foreign \
  run_generic rollback >/dev/null 2>&1 || foreign_rollback_rc=$?
[ "$foreign_rollback_rc" -eq 2 ] || fail "rollback must refuse a foreign same-name StatefulSet"
if grep -F 'rollout undo' "$CALLS" >/dev/null; then
  fail "rollback must verify ownership before mutation"
fi
pass "rollback refuses foreign workload ownership"

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
grep -Fqx 'kubectl --context kind-agent-os -n portable-agent-os delete rolebinding agent-os-firstmate-runtime --ignore-not-found --wait=true --timeout=180s' "$CALLS" || \
  fail "uninstall must remove namespace runtime binding regardless of current inputs"
grep -Fqx 'kubectl --context kind-agent-os -n portable-agent-os delete role agent-os-firstmate-runtime --ignore-not-found --wait=true --timeout=180s' "$CALLS" || \
  fail "uninstall must remove namespace runtime Role regardless of current inputs"
stateful_delete_line=$(grep -Fn '/statefulset.yaml' "$CALLS" | grep ' delete ' | head -n 1 | cut -d: -f1)
pvc_delete_line=$(grep -Fn '/00-pvc.yaml' "$CALLS" | grep ' delete ' | head -n 1 | cut -d: -f1)
[ -n "$stateful_delete_line" ] && [ -n "$pvc_delete_line" ] && \
  [ "$stateful_delete_line" -lt "$pvc_delete_line" ] || \
  fail "uninstall must delete the StatefulSet before waiting on PVC deletion"
pass "routine uninstall removes namespaced resources without cluster-wide authority"

: > "$CALLS"
NONE_INPUTS="$TMP/none-rbac-inputs.yaml"
sed 's/rbac: namespace/rbac: none/' "$GENERIC_INPUTS" > "$NONE_INPUTS"
bounded_out=''
bounded_rc=0
bounded_out=$(PATH="$FAKEBIN:$PATH" AGENT_OS_TEST_LOG="$CALLS" AGENT_OS_INPUTS="$NONE_INPUTS" \
  AGENT_OS_TEST_NAMESPACE=portable-agent-os AGENT_OS_TEST_NAMESPACE_STATE=owned \
  AGENT_OS_TEST_WORKLOAD_STATE=none AGENT_OS_TEST_RESOURCE_STATE=owned \
  AGENT_OS_TEST_PRIMARY_POD_STATE=owned AGENT_OS_TEST_FAIL_DELETE_FILE=00-pvc.yaml \
  AGENT_OS_OPERATION_ID=operation-test AGENT_OS_CONTEXT=kind-agent-os \
  AGENT_OS_NAMESPACE=portable-agent-os "$GENERIC" uninstall --yes 2>&1) || bounded_rc=$?
[ "$bounded_rc" -eq 3 ] || fail "timed-out uninstall must exit incomplete: $bounded_out"
assert_contains "$bounded_out" 'failed-target: PersistentVolumeClaim/agent-os-firstmate-home' \
  "timed-out uninstall must report the actual failed target"
assert_contains "$bounded_out" 'retained: PersistentVolumeClaim/agent-os-firstmate-home uid=uid-persistentvolumeclaim' \
  "timed-out uninstall must report the retained owned resource"
assert_contains "$bounded_out" 'finalizers=[kubernetes.io/pvc-protection]' \
  "timed-out uninstall must report retained finalizers"
assert_contains "$bounded_out" 'retained: Pod/agent-os-firstmate-0 uid=uid-pod' \
  "timed-out uninstall must report the StatefulSet Pod outside the fresh render"
assert_contains "$bounded_out" 'retained: Role/agent-os-firstmate-runtime uid=uid-role' \
  "timed-out rbac:none uninstall must report stale deterministic Role residue"
assert_contains "$bounded_out" 'retained: RoleBinding/agent-os-firstmate-runtime uid=uid-rolebinding' \
  "timed-out rbac:none uninstall must report stale deterministic RoleBinding residue"
assert_contains "$bounded_out" 'safe retry:' \
  "timed-out uninstall must print exact safe retry evidence"
assert_contains "$bounded_out" 'cluster cleanup if required:' \
  "timed-out uninstall must print exact privileged cleanup evidence"
grep -F '/00-pvc.yaml' "$CALLS" | grep -F -- '--wait=true --timeout=180s' >/dev/null || \
  fail "uninstall deletion must have an explicit timeout"
pass "uninstall timeouts report retained owned resources and safe retry evidence"

: > "$CALLS"
foreign_uninstall_rc=0
AGENT_OS_TEST_NAMESPACE_STATE=owned AGENT_OS_TEST_WORKLOAD_STATE=namespace \
  AGENT_OS_TEST_RESOURCE_STATE=foreign run_generic uninstall --yes >/dev/null 2>&1 || foreign_uninstall_rc=$?
[ "$foreign_uninstall_rc" -eq 2 ] || fail "uninstall must reject same-name foreign namespaced resources"
if grep -F ' delete --ignore-not-found -f ' "$CALLS" >/dev/null; then
  fail "uninstall must preflight all namespaced ownership before deletion"
fi
pass "uninstall refuses foreign deterministic-name resources"

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
retry_residue_out=''
retry_residue_rc=0
retry_residue_out=$(AGENT_OS_TEST_NAMESPACE_STATE=owned AGENT_OS_TEST_WORKLOAD_STATE=absent \
  run_generic uninstall --yes 2>&1) || retry_residue_rc=$?
[ "$retry_residue_rc" -eq 3 ] || \
  fail "uninstall retry without workload history must require cluster absence evidence: $retry_residue_out"
assert_contains "$retry_residue_out" 'cleanup-cluster-rbac --yes' \
  "history-free uninstall retry must print the privileged absence-evidence command"
pass "uninstall retry cannot lose cluster-RBAC residue state"

: > "$CALLS"
AGENT_OS_TEST_NAMESPACE_STATE=owned AGENT_OS_TEST_WORKLOAD_STATE=namespace \
  run_generic uninstall --yes --delete-namespace
grep -Fqx 'kubectl --context kind-agent-os delete namespace portable-agent-os --wait=true --timeout=180s' "$CALLS" || \
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

: > "$CALLS"
foreign_lease_rc=0
AGENT_OS_TEST_NAMESPACE_STATE=owned AGENT_OS_TEST_WORKLOAD_STATE=namespace \
  AGENT_OS_TEST_FOREIGN_LEASE=foreign-leader run_generic uninstall --yes --delete-namespace >/dev/null 2>&1 || \
  foreign_lease_rc=$?
[ "$foreign_lease_rc" -eq 2 ] || fail "foreign Lease must block namespace deletion"
if grep -F 'delete namespace portable-agent-os' "$CALLS" >/dev/null; then
  fail "namespace deletion must include Leases in its foreign-resource proof"
fi
pass "optional namespace deletion refuses foreign Leases"
