#!/usr/bin/env bash
# Kubernetes manifest and isolated crewmate launcher tests.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

assert_grep 'configure_control_lock' "$ROOT/bin/agent-os-crewmate.sh" \
  "crewmate mutations must acquire the stable installation control lock"
assert_grep 'CONTROL_LOCK_UID' "$ROOT/bin/agent-os-crewmate.sh" \
  "crewmate mutations must retain control-lock CAS evidence"
assert_grep 'LOCK_INSTALLATION_ID=$CONTROL_LOCK_INSTALLATION_ID' "$ROOT/bin/agent-os-crewmate.sh" \
  "crewmate control Leases must render their scope-specific installation identity"
assert_grep 'configure_control_lock' "$ROOT/bin/agent-os-akua-auth.sh" \
  "authorization mutations must acquire the stable installation control lock"
assert_grep 'agent-os-firstmate-lifecycle' "$ROOT/bin/agent-os-akua-auth.sh" \
  "authorization mutations must also acquire the namespace fleet lock"
assert_grep 'current=absent' "$ROOT/bin/agent-os-kubernetes.sh" \
  "upgrade snapshots must represent an absent authorization overlay explicitly"
assert_grep 'transfer_runtime_authority' "$ROOT/bin/agent-os-kubernetes.sh" \
  "rollback must transactionally transfer runtime authority"
assert_grep 'compensate_rollback' "$ROOT/bin/agent-os-kubernetes.sh" \
  "failed rollback must restore the current revision and authority"
assert_grep 'wait_for_revision_history_absence' "$ROOT/bin/agent-os-kubernetes.sh" \
  "uninstall must retire historical ServiceAccounts only after revision history"
assert_grep 'fail_grant_closed "grant CAS failed ambiguously"' "$ROOT/bin/agent-os-akua-auth.sh" \
  "ambiguous grant mutations must enter fail-closed reconciliation"
assert_grep 'fail_grant_closed "grant rollout failed"' "$ROOT/bin/agent-os-akua-auth.sh" \
  "failed grant rollouts must enter fail-closed reconciliation"
assert_grep 'reconcile_failed_akua_upgrade' "$ROOT/bin/agent-os-kubernetes.sh" \
  "upgrade authorization drift must be removed and verified fail closed"
assert_grep 'inventory_revision_service_accounts' "$ROOT/bin/agent-os-kubernetes.sh" \
  "uninstall must inventory every historical revision ServiceAccount"
assert_grep 'verify_no_runtime_authority' "$ROOT/bin/agent-os-kubernetes.sh" \
  "RBAC none must verify namespace, cluster, and control authority absence"
assert_grep 'rollback_source_digest' "$ROOT/bin/agent-os-kubernetes.sh" \
  "rollback compensation must verify its immutable source revision digest"
assert_grep 'if [ "$COMMAND" = grant ]; then' "$ROOT/bin/agent-os-akua-auth.sh" \
  "authorization Secret validation must apply only to grant"
assert_grep 'verify_overlay absent "$STATE_UID" 0' "$ROOT/bin/agent-os-akua-auth.sh" \
  "authorization revoke must verify absence without requiring a Secret record"
assert_grep '.metadata.annotations["agent-os.dev/akua-auth-rejected-record"] // ""' "$ROOT/bin/agent-os-akua-auth.sh" \
  "authorization revoke must verify the rejected Secret identity marker is absent"
assert_grep 'STATEFULSET_CAS_ATTEMPTED' "$ROOT/bin/agent-os-kubernetes.sh" \
  "post-CAS upgrade failures must enter fail-closed authorization reconciliation"
assert_grep 'STATEFULSET_CAS_UID' "$ROOT/bin/agent-os-kubernetes.sh" \
  "upgrade compensation must remain bound to the pre-CAS StatefulSet UID"
assert_grep 'inventory_owned_service_accounts' "$ROOT/bin/agent-os-kubernetes.sh" \
  "uninstall retries must recover exact-owned historical ServiceAccounts independently"
assert_grep 'verify_runtime_role_rules' "$ROOT/bin/agent-os-kubernetes.sh" \
  "rollback must verify exact namespace runtime Role rules"
assert_grep 'verify_control_role_rules' "$ROOT/bin/agent-os-kubernetes.sh" \
  "rollback must verify exact control Role rules"
assert_grep '    REMOVE_CONTROL_ACCESS=1' "$ROOT/bin/agent-os-kubernetes.sh" \
  "uninstall must always remove exact-owned control RBAC"

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
assert_not_contains "$rendered" 'mountPath: /usr/local' "primary must keep image-owned /usr/local immutable"
pass "OrbStack profile renders the canonical persistent primary"

cat > "$FAKEBIN/kubectl" <<'SH'
#!/usr/bin/env bash
printf 'kubectl' >> "$AGENT_OS_TEST_LOG"
printf ' %s' "$@" >> "$AGENT_OS_TEST_LOG"
printf '\n' >> "$AGENT_OS_TEST_LOG"
filtered_args=()
for argument in "$@"; do
  [[ "$argument" = --request-timeout=* ]] || filtered_args+=("$argument")
done
set -- "${filtered_args[@]}"
effective_binding_account() {
  local binding=$1 account patch
  patch=$(grep -F " patch rolebinding $binding " "$AGENT_OS_TEST_LOG" | tail -n 1 | sed -n 's/.* -p //p')
  account=$(printf '%s' "$patch" | jq -r '.subjects[0].name // empty' 2>/dev/null || true)
  if [ -z "$account" ]; then
    account=$(grep 'akua-input-service-account ' "$AGENT_OS_TEST_LOG" | tail -n 1 | awk '{print $2}')
  fi
  if [ "${AGENT_OS_TEST_COMMAND:-}" = rollback ] && [ -z "$patch" ]; then
    account=${AGENT_OS_TEST_WORKLOAD_SERVICE_ACCOUNT:-agent-os-firstmate}
  fi
  printf '%s' "${account:-agent-os-firstmate}"
}
stdin_data=''
previous=''
for argument in "$@"; do
  if [ "$previous" = --patch-file ]; then
    printf '%s\n' "$(cat "$argument")" >> "${AGENT_OS_STDIN_LOG:-$AGENT_OS_TEST_LOG.stdin}"
  fi
  previous=$argument
done
if [ "${*: -2}" = "-f -" ]; then
  stdin_data=$(cat)
  printf '%s\n' "$stdin_data" >> "${AGENT_OS_STDIN_LOG:-$AGENT_OS_TEST_LOG.stdin}"
  stdin_kind=$(printf '%s\n' "$stdin_data" | awk '$1 == "kind:" { print $2; exit }')
  [ -n "$stdin_kind" ] || stdin_kind=$(printf '%s' "$stdin_data" | jq -r '.kind // empty' 2>/dev/null || true)
  printf 'stdin-kind %s\n' "$stdin_kind" >> "$AGENT_OS_TEST_LOG"
  stdin_name=$(printf '%s' "$stdin_data" | jq -r '.metadata.name // empty' 2>/dev/null || true)
  [ -z "$stdin_name" ] || printf 'stdin-resource %s %s\n' "$stdin_kind" "$stdin_name" >> "$AGENT_OS_TEST_LOG"
  if [ "$stdin_kind" = Lease ]; then
    stdin_name=$(printf '%s\n' "$stdin_data" | awk '$1 == "name:" { print $2; exit }')
    printf 'stdin-lease %s\n' "$stdin_name" >> "$AGENT_OS_TEST_LOG"
  fi
fi
if [ "${AGENT_OS_TEST_FAIL_APPLY:-0}" = 1 ] && [[ " $* " = *" create -f - "* ]] && \
  [ "$stdin_kind" = Pod ]; then
  exit 1
fi
if { [ "${AGENT_OS_TEST_LOCK_STATE:-free}" != free ] || [ "${AGENT_OS_TEST_PRIMARY_LOCK_STATE:-free}" != free ]; } && \
  [[ " $* " = *" create -f - "* ]] && \
  [ "$stdin_kind" = Lease ]; then
  exit 1
fi
if [ "${AGENT_OS_TEST_FAIL_PVC_PATCH:-0}" = 1 ] && [[ " $* " = *" patch pvc "* ]]; then
  exit 1
fi
if [ "${AGENT_OS_TEST_FAIL_POD_LIST:-0}" = 1 ] && [[ " $* " = *" get pods -o json "* ]]; then
  exit 1
fi
if [ "${AGENT_OS_TEST_FAIL_GENERIC_APPLY:-0}" = 1 ] && \
  { [[ " $* " = *" apply -f "* ]] || [[ " $* " = *" create -f "*statefulset.yaml* ]] || \
    [[ " $* " = *" patch StatefulSet agent-os-firstmate "* ]]; }; then
  exit 1
fi
if [ "${AGENT_OS_TEST_FAIL_WAIT:-0}" = 1 ] && [ "${1:-}" = -n ] && [ "${3:-}" = wait ]; then
  exit 1
fi
if [ -n "${AGENT_OS_TEST_FAIL_WAIT_TARGET:-}" ] && [[ " $* " = *" wait --for=delete $AGENT_OS_TEST_FAIL_WAIT_TARGET "* ]]; then
  printf 'error: timed out waiting for the condition on %s\n' "$AGENT_OS_TEST_FAIL_WAIT_TARGET" >&2
  exit 1
fi
if [ "${AGENT_OS_TEST_FAIL_ROLLOUT:-0}" = 1 ] && [[ " $* " = *" rollout status statefulset/agent-os-firstmate "* ]]; then
  exit 1
fi
if [ "${AGENT_OS_TEST_FAIL_FIRST_ROLLOUT:-0}" = 1 ] && \
  [[ " $* " = *" rollout status statefulset/agent-os-firstmate "* ]] && \
  [ "$(grep -Fc 'rollout status statefulset/agent-os-firstmate' "$AGENT_OS_TEST_LOG")" -eq 1 ]; then
  exit 1
fi
if [ "${AGENT_OS_TEST_LOCK_STATE:-free}" = held ] && [[ " $* " = *" wait --for=delete lease/"* ]]; then
  exit 1
fi
if [ "${AGENT_OS_TEST_FAIL_ANNOTATE:-0}" = 1 ] && \
  { [[ " $* " = *" annotate statefulset agent-os-firstmate "* ]] || \
    { [[ " $* " = *" patch StatefulSet agent-os-firstmate "* ]] && [[ " $* " = *"cluster-rbac-cleanup"* ]]; }; }; then
  exit 1
fi
if [ -n "${AGENT_OS_TEST_FAIL_DELETE_FILE:-}" ] && [[ " $* " = *" delete "* ]] && \
  [[ " $* " = *"$AGENT_OS_TEST_FAIL_DELETE_FILE"* ]]; then
  exit 1
fi
if [ -n "${AGENT_OS_TEST_FAIL_DELETE_TARGET:-}" ] && [[ " $* " = *"$AGENT_OS_TEST_FAIL_DELETE_TARGET"* ]]; then
  printf '%s\n' "${AGENT_OS_TEST_DELETE_ERROR:-transport error}" >&2
  exit 1
fi
if [ -n "${AGENT_OS_TEST_READY_DELAY:-}" ] && [[ " $* " = *" wait --for=condition=Ready pod/"* ]]; then
  sleep "$AGENT_OS_TEST_READY_DELAY"
fi
if [ -n "${AGENT_OS_TEST_ROLLOUT_DELAY:-}" ] && [[ " $* " = *" rollout status statefulset/agent-os-firstmate "* ]]; then
  sleep "$AGENT_OS_TEST_ROLLOUT_DELAY"
fi
if [[ " $* " = *" get Role agent-os-lifecycle-"*" -o json "* ]] || \
  [[ " $* " = *" get role agent-os-lifecycle-"*" -o json "* ]]; then
  control_name=$(printf '%s\n' "$*" | sed -n 's/.* get [Rr]ole \([^ ]*\) .*/\1/p')
  if ! grep -Fq "/roles/$control_name" "$AGENT_OS_TEST_LOG"; then
    if [ "${AGENT_OS_TEST_CONTROL_RBAC_STATE:-exact}" = bad-rules ]; then
      printf '{"metadata":{"name":"%s","uid":"uid-control-role","resourceVersion":"rv-control-role","labels":{"app.kubernetes.io/managed-by":"agent-os"},"annotations":{"agent-os.dev/installation-id":"agent-os-firstmate:portable-agent-os"}},"rules":[]}\n' "$control_name"
    else
      printf '{"metadata":{"name":"%s","uid":"uid-control-role","resourceVersion":"rv-control-role","labels":{"app.kubernetes.io/managed-by":"agent-os"},"annotations":{"agent-os.dev/installation-id":"agent-os-firstmate:portable-agent-os"}},"rules":[{"apiGroups":["coordination.k8s.io"],"resources":["leases"],"resourceNames":["%s"],"verbs":["get","update"]}]}\n' "$control_name" "$control_name"
    fi
  fi
  exit 0
fi
if [[ " $* " = *" get RoleBinding agent-os-lifecycle-"*" -o json "* ]] || \
  [[ " $* " = *" get rolebinding agent-os-lifecycle-"*" -o json "* ]]; then
  control_name=$(printf '%s\n' "$*" | sed -n 's/.* get [Rr]ole[Bb]inding \([^ ]*\) .*/\1/p')
  if ! grep -Fq "/rolebindings/$control_name" "$AGENT_OS_TEST_LOG"; then
    control_account=$(effective_binding_account "$control_name")
    printf '{"metadata":{"name":"%s","uid":"uid-control-binding","resourceVersion":"rv-control-binding","labels":{"app.kubernetes.io/managed-by":"agent-os"},"annotations":{"agent-os.dev/installation-id":"agent-os-firstmate:portable-agent-os"}},"roleRef":{"apiGroup":"rbac.authorization.k8s.io","kind":"Role","name":"%s"},"subjects":[{"kind":"ServiceAccount","name":"%s","namespace":"portable-agent-os"}]}\n' "$control_name" "$control_name" "$control_account"
  fi
  exit 0
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
      pod_state=${AGENT_OS_TEST_POD_AFTER_DELETE:-absent}
    fi
    case "$pod_state" in
      absent) ;;
      owned)
        printf 'agent-os-crewmate-%s\tagent-os\t%s\tagent-os-firstmate:agent-os-demo' "$id" "$id"
        [[ " $* " != *'.metadata.uid'* ]] || printf '\toperation-test\tuid-owned\trv-pod-owned\tagent-os-crewmate-%s-home' "$id"
        ;;
      replacement)
        printf 'agent-os-crewmate-%s\tagent-os\t%s\tagent-os-firstmate:agent-os-demo' "$id" "$id"
        [[ " $* " != *'.metadata.uid'* ]] || printf '\tother-operation\tuid-replacement\trv-pod-replacement\tagent-os-crewmate-%s-home' "$id"
        ;;
      replaced-after-ready)
        printf 'agent-os-crewmate-%s\tagent-os\t%s\tagent-os-firstmate:agent-os-demo' "$id" "$id"
        if [[ " $* " = *'.metadata.uid'* ]]; then
          if grep -F 'wait --for=condition=Ready pod/' "$AGENT_OS_TEST_LOG" >/dev/null; then
            printf '\tother-operation\tuid-replacement\trv-pod-replacement\tagent-os-crewmate-%s-home' "$id"
          else
            printf '\toperation-test\tuid-owned\trv-pod-owned\tagent-os-crewmate-%s-home' "$id"
          fi
        fi
        ;;
      foreign)
        printf 'agent-os-crewmate-%s\tother\tother\tother-installation' "$id"
        [[ " $* " != *'.metadata.uid'* ]] || printf '\tother-operation\tuid-foreign\trv-pod-foreign\tforeign-home'
        ;;
    esac
    ;;
  *" get pvc agent-os-crewmate-"*" --ignore-not-found -o jsonpath="*)
    id=${AGENT_OS_TEST_CREWMATE_ID:-scout-1}
    pvc_state=${AGENT_OS_TEST_PVC_STATE:-absent}
    if grep -F "/persistentvolumeclaims/agent-os-crewmate-$id-home" "$AGENT_OS_TEST_LOG" | grep -F 'delete --raw' >/dev/null; then
      if [ -n "${AGENT_OS_TEST_PVC_AFTER_DELETE:-}" ]; then
        pvc_state=$AGENT_OS_TEST_PVC_AFTER_DELETE
      elif [[ "${AGENT_OS_TEST_FAIL_DELETE_TARGET:-}" != *"/persistentvolumeclaims/agent-os-crewmate-$id-home"* ]]; then
        pvc_state=absent
      fi
    fi
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
      binder-rv)
        pvc_reads=$(grep -Fc ' get pvc agent-os-crewmate-' "$AGENT_OS_TEST_LOG")
        printf 'agent-os-crewmate-%s-home\tagent-os\t%s\tagent-os-firstmate:agent-os-demo\tpending\t\t\t\tuid-pvc-owned\trv-pvc-%s' "$id" "$id" "$pvc_reads"
        ;;
      replaced-after-pod)
        if grep -F 'stdin-kind Pod' "$AGENT_OS_TEST_LOG" >/dev/null; then
          printf 'agent-os-crewmate-%s-home\tagent-os\t%s\tagent-os-firstmate:agent-os-demo\tpending\t\t\t\tuid-pvc-replacement\trv-pvc-replacement' "$id" "$id"
        else
          printf 'agent-os-crewmate-%s-home\tagent-os\t%s\tagent-os-firstmate:agent-os-demo\tpending\t\t\t\tuid-pvc-owned\trv-pvc-owned' "$id" "$id"
        fi
        ;;
      replaced-after-ready)
        if grep -F 'wait --for=condition=Ready pod/' "$AGENT_OS_TEST_LOG" >/dev/null; then
          printf 'agent-os-crewmate-%s-home\tagent-os\t%s\tagent-os-firstmate:agent-os-demo\tpending\t\t\t\tuid-pvc-after-ready\trv-pvc-after-ready' "$id" "$id"
        else
          printf 'agent-os-crewmate-%s-home\tagent-os\t%s\tagent-os-firstmate:agent-os-demo\tpending\t\t\t\tuid-pvc-owned\trv-pvc-owned' "$id" "$id"
        fi
        ;;
    esac
    ;;
  *get\ lease\ agent-os-crewmate-*--ignore-not-found*-o\ jsonpath=*)
    id=${AGENT_OS_TEST_CREWMATE_ID:-scout-1}
    lease_holder=$(awk '/holderIdentity:/ { holder=$2 } END { print holder }' "${AGENT_OS_STDIN_LOG:-$AGENT_OS_TEST_LOG.stdin}")
    case "${AGENT_OS_TEST_LOCK_STATE:-free}" in
      held) printf 'agent-os-crewmate-%s-lifecycle\tagent-os\t%s\tagent-os-firstmate:agent-os-demo\tother-operation\t2099-01-01T00:00:00Z\t2099-01-01T00:00:00Z\t300\tuid-lock-other\trv-lock-other' "$id" "$id" ;;
      foreign) printf 'agent-os-crewmate-%s-lifecycle\tother\tother\tother-installation\tother-operation\t2099-01-01T00:00:00Z\t2099-01-01T00:00:00Z\t300\tuid-lock-foreign\trv-lock-foreign' "$id" ;;
      expired)
        last_expired_delete=$(grep -Fn "/leases/agent-os-crewmate-$id-lifecycle" "$AGENT_OS_TEST_LOG" | grep 'delete --raw' | tail -n 1 | cut -d: -f1)
        if [ -n "$last_expired_delete" ]; then
          :
        elif grep -F ' replace -f -' "$AGENT_OS_TEST_LOG" >/dev/null; then
          acquire_time=$(awk '/acquireTime:/ { value=$2 } END { print value }' "${AGENT_OS_STDIN_LOG:-$AGENT_OS_TEST_LOG.stdin}")
          renew_time=$(awk '/renewTime:/ { value=$2 } END { print value }' "${AGENT_OS_STDIN_LOG:-$AGENT_OS_TEST_LOG.stdin}")
          printf 'agent-os-crewmate-%s-lifecycle\tagent-os\t%s\tagent-os-firstmate:agent-os-demo\t%s\t%s\t%s\t%s\tuid-lock-expired\trv-lock-taken' \
            "$id" "$id" "$lease_holder" "$acquire_time" "$renew_time" "${AGENT_OS_LOCK_DURATION_SECONDS:-300}"
        else
          printf 'agent-os-crewmate-%s-lifecycle\tagent-os\t%s\tagent-os-firstmate:agent-os-demo\tother-operation\t2000-01-01T00:00:00Z\t2000-01-01T00:00:00Z\t300\tuid-lock-expired\t%s' "$id" "$id" "${AGENT_OS_TEST_LOCK_RV:-rv-lock-expired}"
        fi
        ;;
      *)
        last_lock_write=$(grep -Fn 'stdin-kind Lease' "$AGENT_OS_TEST_LOG" | tail -n 1 | cut -d: -f1)
        last_lock_delete=$(grep -Fn "/leases/agent-os-crewmate-$id-lifecycle" "$AGENT_OS_TEST_LOG" | grep 'delete --raw' | tail -n 1 | cut -d: -f1)
        if [ -n "$last_lock_delete" ] && [ "${AGENT_OS_TEST_LOCK_RELEASE_STATE:-}" = next-owner ]; then
          printf 'agent-os-crewmate-%s-lifecycle\tagent-os\t%s\tagent-os-firstmate:agent-os-demo\tnext-operation\t2026-07-13T00:00:00Z\t2026-07-13T00:00:00Z\t300\tuid-lock-next\trv-lock-next' "$id" "$id"
        elif [ -n "$last_lock_delete" ] && [ "${AGENT_OS_TEST_LOCK_RELEASE_STATE:-}" = foreign ]; then
          printf 'agent-os-crewmate-%s-lifecycle\tother\tother\tother-installation\tother-operation\t2099-01-01T00:00:00Z\t2099-01-01T00:00:00Z\t300\tuid-lock-foreign\trv-lock-foreign' "$id"
        elif [ -n "$last_lock_write" ] && { [ -z "$last_lock_delete" ] || [ "$last_lock_write" -gt "$last_lock_delete" ]; }; then
          acquire_time=$(awk '/acquireTime:/ { value=$2 } END { print value }' "${AGENT_OS_STDIN_LOG:-$AGENT_OS_TEST_LOG.stdin}")
          renew_time=$(awk '/renewTime:/ { value=$2 } END { print value }' "${AGENT_OS_STDIN_LOG:-$AGENT_OS_TEST_LOG.stdin}")
          renew_rv=rv-lock
          if grep -F ' replace -f -' "$AGENT_OS_TEST_LOG" >/dev/null; then
            renew_rv=rv-lock-renewed
            [ "${AGENT_OS_TEST_RENEW_READBACK:-exact}" != wrong ] || renew_time=2000-01-01T00:00:00Z
          fi
          printf 'agent-os-crewmate-%s-lifecycle\tagent-os\t%s\tagent-os-firstmate:agent-os-demo\t%s\t%s\t%s\t%s\tuid-lock\t%s' \
            "$id" "$id" "$lease_holder" "$acquire_time" "$renew_time" "${AGENT_OS_LOCK_DURATION_SECONDS:-300}" "$renew_rv"
        fi
        ;;
    esac
    ;;
  *get\ lease\ agent-os-firstmate-lifecycle*--ignore-not-found*-o\ jsonpath=*|\
  *get\ lease\ agent-os-lifecycle-*--ignore-not-found*-o\ jsonpath=*)
    lock_name=$(printf '%s\n' "$*" | sed -n 's/.* get lease \([^ ]*\) .*/\1/p')
    last_lock_write=$(grep -Fn "stdin-lease $lock_name" "$AGENT_OS_TEST_LOG" | tail -n 1 | cut -d: -f1)
    last_lock_delete=$(grep -Fn "/leases/$lock_name" "$AGENT_OS_TEST_LOG" | grep 'delete --raw' | tail -n 1 | cut -d: -f1)
    lock_installation="agent-os-firstmate:${AGENT_OS_TEST_NAMESPACE:-${AGENT_OS_NAMESPACE:-portable-agent-os}}"
    if [[ "$lock_name" = agent-os-lifecycle-* ]]; then
      control_digest=$(printf 'agent-os-installation:%s' "${AGENT_OS_TEST_NAMESPACE:-${AGENT_OS_NAMESPACE:-portable-agent-os}}" | shasum -a 256 | awk '{print $1}')
      control_uuid="${control_digest:0:8}-${control_digest:8:4}-5${control_digest:13:3}-8${control_digest:17:3}-${control_digest:20:12}"
      lock_installation="agent-os-control:$control_uuid"
    fi
    if [ "${AGENT_OS_TEST_PRIMARY_LOCK_STATE:-free}" = expired ] && ! grep -F ' replace -f -' "$AGENT_OS_TEST_LOG" >/dev/null; then
      printf '%s\tagent-os\tprimary\t%s\tother-operation\t2000-01-01T00:00:00Z\t2000-01-01T00:00:00Z\t300\tuid-primary-lock\t%s' "$lock_name" "$lock_installation" "${AGENT_OS_TEST_PRIMARY_LOCK_RV:-rv-primary-lock}"
    elif [ -n "$last_lock_write" ] && { [ -z "$last_lock_delete" ] || [ "$last_lock_write" -gt "$last_lock_delete" ]; }; then
      lock_stdin=${AGENT_OS_STDIN_LOG:-$AGENT_OS_TEST_LOG.stdin}
      lock_holder=$(awk '/holderIdentity:/ { holder=$2 } END { print holder }' "$lock_stdin")
      lock_acquired=$(awk '/acquireTime:/ { value=$2 } END { print value }' "$lock_stdin")
      lock_renewed=$(awk '/renewTime:/ { value=$2 } END { print value }' "$lock_stdin")
      lock_replace_count=$(awk -v name="$lock_name" '
        /kubectl .* replace -f -/ { replacing=1; next }
        /^stdin-lease / { if (replacing && $2 == name) count++; replacing=0 }
        END { print count+0 }
      ' "$AGENT_OS_TEST_LOG")
      lock_rv="${AGENT_OS_TEST_PRIMARY_LOCK_RV:-rv-primary-lock}-$lock_replace_count"
      printf '%s\tagent-os\tprimary\t%s\t%s\t%s\t%s\t%s\tuid-primary-lock\t%s' \
        "$lock_name" "$lock_installation" "$lock_holder" "$lock_acquired" "$lock_renewed" \
        "${AGENT_OS_LOCK_DURATION_SECONDS:-300}" "$lock_rv"
    fi
    ;;
  *" get namespace "*" --ignore-not-found -o name "*)
    namespace_state=${AGENT_OS_TEST_NAMESPACE_STATE:-absent}
    if grep -F ' create -f ' "$AGENT_OS_TEST_LOG" | grep -F 'namespace.yaml' >/dev/null || \
      grep -F ' apply -f ' "$AGENT_OS_TEST_LOG" >/dev/null; then
      namespace_state=${AGENT_OS_TEST_NAMESPACE_AFTER_APPLY:-owned}
    fi
    case "$namespace_state" in
      absent) ;;
      *) printf 'namespace/%s\n' "${AGENT_OS_TEST_NAMESPACE:-portable-agent-os}" ;;
    esac
    ;;
  *" get namespace "*" -o jsonpath="*|*" get Namespace "*" -o jsonpath="*)
    namespace_state=${AGENT_OS_TEST_NAMESPACE_STATE:-absent}
    if grep -F ' create -f ' "$AGENT_OS_TEST_LOG" | grep -F 'namespace.yaml' >/dev/null || \
      grep -F ' apply -f ' "$AGENT_OS_TEST_LOG" >/dev/null; then
      namespace_state=${AGENT_OS_TEST_NAMESPACE_AFTER_APPLY:-owned}
    fi
    case "$namespace_state" in
      owned)
        if [[ " $* " = *'.metadata.resourceVersion'* ]]; then
          current_operation=$(grep 'akua-input-operation ' "$AGENT_OS_TEST_LOG" | tail -n 1 | awk '{print $2}')
          printf '%s\tagent-os\tagent-os-firstmate:%s\tuid-namespace\trv-namespace\t%s' \
            "${AGENT_OS_TEST_NAMESPACE:-portable-agent-os}" "${AGENT_OS_TEST_NAMESPACE:-portable-agent-os}" "$current_operation"
        elif [[ " $* " = *'.metadata.uid'* ]]; then
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
    if grep -F ' create -f ' "$AGENT_OS_TEST_LOG" | grep -F 'statefulset.yaml' >/dev/null || \
      grep -F ' patch StatefulSet agent-os-firstmate ' "$AGENT_OS_TEST_LOG" >/dev/null || \
      grep -F ' apply -f ' "$AGENT_OS_TEST_LOG" >/dev/null; then
      workload_state=${AGENT_OS_TEST_WORKLOAD_AFTER_APPLY:-namespace}
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
  *" get ServiceAccount agent-os-firstmate"*" --ignore-not-found -o jsonpath="*|\
  *" get PersistentVolumeClaim agent-os-firstmate-home --ignore-not-found -o jsonpath="*|\
  *" get Service agent-os-firstmate --ignore-not-found -o jsonpath="*|\
  *" get Role agent-os-firstmate-runtime --ignore-not-found -o jsonpath="*|\
  *" get RoleBinding agent-os-firstmate-runtime --ignore-not-found -o jsonpath="*)
    kind=''
    name=''
    case " $* " in
      *" StatefulSet "*) kind=StatefulSet; name=agent-os-firstmate ;;
      *" ServiceAccount "*) kind=ServiceAccount; name=$(printf '%s\n' "$*" | sed -n 's/.* get ServiceAccount \([^ ]*\) .*/\1/p') ;;
      *" PersistentVolumeClaim "*) kind=PersistentVolumeClaim; name=agent-os-firstmate-home ;;
      *" Service "*) kind=Service; name=agent-os-firstmate ;;
      *" RoleBinding "*) kind=RoleBinding; name=agent-os-firstmate-runtime ;;
      *" Role "*) kind=Role; name=agent-os-firstmate-runtime ;;
    esac
    resource_state=${AGENT_OS_TEST_RESOURCE_STATE:-absent}
    if { [ "$kind" = Role ] || [ "$kind" = RoleBinding ]; } && [ -n "${AGENT_OS_TEST_STALE_RBAC_STATE:-}" ]; then
      resource_state=$AGENT_OS_TEST_STALE_RBAC_STATE
    fi
    if [ "$kind" = ServiceAccount ] && [ "$name" = "${AGENT_OS_TEST_RESIDUAL_SERVICE_ACCOUNT:-}" ]; then
      resource_state=owned
      grep -F "/serviceaccounts/$name" "$AGENT_OS_TEST_LOG" | grep -F 'delete --raw' >/dev/null && resource_state=absent
    fi
    if grep -E ' create -f .+\.yaml' "$AGENT_OS_TEST_LOG" | grep -v 'namespace.yaml' >/dev/null || \
      grep -F ' --patch-file ' "$AGENT_OS_TEST_LOG" >/dev/null || \
      grep -F ' apply -f ' "$AGENT_OS_TEST_LOG" >/dev/null; then
      resource_state=${AGENT_OS_TEST_RESOURCE_AFTER_APPLY:-owned}
    fi
    case "$resource_state" in
      absent) ;;
      owned)
        printf '%s\tagent-os\tagent-os-firstmate:portable-agent-os' "$name"
        if [[ " $* " = *'.metadata.resourceVersion'* ]]; then
          current_operation=$(grep 'akua-input-operation ' "$AGENT_OS_TEST_LOG" | tail -n 1 | awk '{print $2}')
          printf '\tuid-%s\t%s\t%s' "$(printf '%s' "$kind" | tr '[:upper:]' '[:lower:]')" "${AGENT_OS_TEST_RESOURCE_RV:-rv-$(printf '%s' "$kind" | tr '[:upper:]' '[:lower:]')}" "$current_operation"
        elif [[ " $* " = *'.spec.replicas'* ]]; then
          printf '\tuid-statefulset\toperation-test\t\t[kubernetes.io/pvc-protection]\t1\t1\t0\t0\t0\trev-old\trev-new\t2\t1'
        elif [[ " $* " = *'.metadata.uid'* ]]; then
          printf '\tuid-%s\toperation-test\tTrue\t[kubernetes.io/pvc-protection]' "$(printf '%s' "$kind" | tr '[:upper:]' '[:lower:]')"
        fi
        ;;
      foreign) printf '%s\tother\tother-installation' "$name" ;;
    esac
    ;;
  *" get statefulset agent-os-firstmate -o json "*)
    rollback_current=${AGENT_OS_TEST_ROLLBACK_CURRENT:-agent-os-firstmate-previous}
    rollback_update=${AGENT_OS_TEST_ROLLBACK_UPDATE:-agent-os-firstmate-current}
    if [ "${AGENT_OS_TEST_FAIL_ROLLOUT:-0}" != 1 ] && \
      grep -F 'rollout status statefulset/agent-os-firstmate' "$AGENT_OS_TEST_LOG" >/dev/null; then
      rollback_current=agent-os-firstmate-previous
      rollback_update=agent-os-firstmate-previous
    fi
    if [ "${AGENT_OS_TEST_ROLLBACK_VERIFY_MISMATCH:-0}" = 1 ] && \
      grep -F 'rollout status statefulset/agent-os-firstmate' "$AGENT_OS_TEST_LOG" >/dev/null; then
      rollback_current=agent-os-firstmate-current
      rollback_update=agent-os-firstmate-current
    fi
    checkpoint_annotations=''
    akua_annotations=''
    akua_env=''
    akua_mount=''
    akua_volume=''
    if [ -n "${AGENT_OS_TEST_AKUA_OVERLAY_SECRET:-}" ] && \
      ! grep -F 'agent-os.dev/akua-auth-rejected-record' "$AGENT_OS_TEST_LOG" >/dev/null; then
      akua_annotations=$(printf ',"agent-os.dev/akua-auth-secret":"%s"' "$AGENT_OS_TEST_AKUA_OVERLAY_SECRET")
      akua_env=',{"name":"AKUA_AUTH_HEADER_FILE","value":"/var/run/secrets/agent-os/akua/authorization"}'
      akua_mount=',{"name":"akua-auth","mountPath":"/var/run/secrets/agent-os/akua","readOnly":true}'
      akua_volume=$(printf ',{"name":"akua-auth","secret":{"secretName":"%s","defaultMode":256}}' "$AGENT_OS_TEST_AKUA_OVERLAY_SECRET")
    fi
    if [ -n "${AGENT_OS_TEST_ROLLBACK_CHECKPOINT_DIGEST:-}" ]; then
      checkpoint_source_digest=$(printf '%s' '{"metadata":{"labels":{"rollback":"current"}},"spec":{"serviceAccountName":"agent-os-firstmate"}}' | jq -cS . | shasum -a 256 | awk '{print $1}')
      checkpoint_annotations=$(printf ',"agent-os.dev/rollback-operation":"checkpoint-operation","agent-os.dev/rollback-target-name":"agent-os-firstmate-previous","agent-os.dev/rollback-target-uid":"uid-revision-previous","agent-os.dev/rollback-target-digest":"%s","agent-os.dev/rollback-source-name":"agent-os-firstmate-current","agent-os.dev/rollback-source-uid":"uid-revision-current","agent-os.dev/rollback-source-digest":"%s"' "$AGENT_OS_TEST_ROLLBACK_CHECKPOINT_DIGEST" "$checkpoint_source_digest")
    elif checkpoint_call=$(grep 'patch StatefulSet agent-os-firstmate --type=merge' "$AGENT_OS_TEST_LOG" | grep 'rollback-target-digest' | head -n 1); then
      checkpoint_operation=$(printf '%s' "$checkpoint_call" | sed -n 's/.*rollback-operation":"\([^"]*\).*/\1/p')
      checkpoint_name=$(printf '%s' "$checkpoint_call" | sed -n 's/.*rollback-target-name":"\([^"]*\).*/\1/p')
      checkpoint_uid=$(printf '%s' "$checkpoint_call" | sed -n 's/.*rollback-target-uid":"\([^"]*\).*/\1/p')
      checkpoint_digest=$(printf '%s' "$checkpoint_call" | sed -n 's/.*rollback-target-digest":"\([0-9a-f]*\).*/\1/p')
      checkpoint_source_name=$(printf '%s' "$checkpoint_call" | sed -n 's/.*rollback-source-name":"\([^"]*\).*/\1/p')
      checkpoint_source_uid=$(printf '%s' "$checkpoint_call" | sed -n 's/.*rollback-source-uid":"\([^"]*\).*/\1/p')
      checkpoint_source_digest=$(printf '%s' "$checkpoint_call" | sed -n 's/.*rollback-source-digest":"\([0-9a-f]*\).*/\1/p')
      checkpoint_annotations=$(printf ',"agent-os.dev/rollback-operation":"%s","agent-os.dev/rollback-target-name":"%s","agent-os.dev/rollback-target-uid":"%s","agent-os.dev/rollback-target-digest":"%s","agent-os.dev/rollback-source-name":"%s","agent-os.dev/rollback-source-uid":"%s","agent-os.dev/rollback-source-digest":"%s"' \
        "$checkpoint_operation" "$checkpoint_name" "$checkpoint_uid" "$checkpoint_digest" "$checkpoint_source_name" "$checkpoint_source_uid" "$checkpoint_source_digest")
    fi
    if [ "${AGENT_OS_TEST_ROLLBACK_CHECKPOINT_MUTATE:-0}" = 1 ] && \
      grep -F 'rollout status statefulset/agent-os-firstmate' "$AGENT_OS_TEST_LOG" >/dev/null; then
      checkpoint_annotations=$(printf '%s' "$checkpoint_annotations" | \
        sed 's/rollback-operation":"[^"]*/rollback-operation":"other-operation/')
    fi
    if [ "${AGENT_OS_TEST_ROLLBACK_CHECKPOINT_MUTATE_ON_READ:-0}" = 1 ] && [ -n "$checkpoint_call" ] && \
      ! grep -F 'rollout status statefulset/agent-os-firstmate' "$AGENT_OS_TEST_LOG" >/dev/null; then
      checkpoint_annotations=$(printf '%s' "$checkpoint_annotations" | \
        sed 's/rollback-operation":"[^"]*/rollback-operation":"other-operation/')
    fi
    statefulset_uid=uid-statefulset
    if [ "${AGENT_OS_TEST_REPLACE_STATEFULSET_AFTER_ROLLOUT:-0}" = 1 ] && \
      grep -F 'rollout status statefulset/agent-os-firstmate' "$AGENT_OS_TEST_LOG" >/dev/null; then
      statefulset_uid=uid-statefulset-replacement
    fi
    printf '{"metadata":{"name":"agent-os-firstmate","uid":"%s","resourceVersion":"%s","labels":{"app.kubernetes.io/managed-by":"agent-os"},"annotations":{"agent-os.dev/installation-id":"agent-os-firstmate:portable-agent-os"%s%s}},"spec":{"template":{"spec":{"serviceAccountName":"%s","containers":[{"name":"firstmate","env":[%s],"volumeMounts":[%s]}],"volumes":[%s]}}},"status":{"currentRevision":"%s","updateRevision":"%s"}}\n' \
      "$statefulset_uid" "${AGENT_OS_TEST_RESOURCE_RV:-rv-statefulset}" "$checkpoint_annotations" "$akua_annotations" "${AGENT_OS_TEST_WORKLOAD_SERVICE_ACCOUNT:-agent-os-firstmate}" "${akua_env#,}" "${akua_mount#,}" "${akua_volume#,}" "$rollback_current" "$rollback_update"
    ;;
  *" get secret "*" --ignore-not-found -o jsonpath="*)
    secret_name=$(printf '%s\n' "$*" | sed -n 's/.* get secret \([^ ]*\) .*/\1/p')
    if [ "$secret_name" = "${AGENT_OS_TEST_AKUA_OVERLAY_SECRET:-}" ]; then
      printf '%s\tuid-secret\trv-secret\tauthorization' "$secret_name"
    fi
    ;;
  *" get controllerrevisions.apps -o json "*)
    if grep -Fq '/statefulsets/agent-os-firstmate' "$AGENT_OS_TEST_LOG" && grep -Fq 'delete --raw' "$AGENT_OS_TEST_LOG"; then
      printf '%s\n' '{"items":[]}'
    elif [ "${AGENT_OS_TEST_ROLLBACK_RENUMBERED:-0}" = 1 ]; then
      printf '%s\n' '{"items":[{"metadata":{"name":"agent-os-firstmate-previous","uid":"uid-revision-previous","ownerReferences":[{"apiVersion":"apps/v1","kind":"StatefulSet","name":"agent-os-firstmate","uid":"uid-statefulset","controller":true}]},"revision":1,"data":{"spec":{"template":{"metadata":{"labels":{"rollback":"previous"}},"spec":{"serviceAccountName":"agent-os-firstmate"}}}}},{"metadata":{"name":"agent-os-firstmate-current","uid":"uid-revision-current","ownerReferences":[{"apiVersion":"apps/v1","kind":"StatefulSet","name":"agent-os-firstmate","uid":"uid-statefulset","controller":true}]},"revision":2,"data":{"spec":{"template":{"metadata":{"labels":{"rollback":"current"}},"spec":{"serviceAccountName":"agent-os-firstmate"}}}}},{"metadata":{"name":"agent-os-firstmate-renumbered","uid":"uid-revision-renumbered","ownerReferences":[{"apiVersion":"apps/v1","kind":"StatefulSet","name":"agent-os-firstmate","uid":"uid-statefulset","controller":true}]},"revision":3,"data":{"spec":{"template":{"metadata":{"labels":{"rollback":"previous"}},"spec":{"serviceAccountName":"agent-os-firstmate"}}}}}]}'
    else
      printf '%s\n' '{"items":[{"metadata":{"name":"agent-os-firstmate-previous","uid":"uid-revision-previous","ownerReferences":[{"apiVersion":"apps/v1","kind":"StatefulSet","name":"agent-os-firstmate","uid":"uid-statefulset","controller":true}]},"revision":1,"data":{"spec":{"template":{"metadata":{"labels":{"rollback":"previous"}},"spec":{"serviceAccountName":"agent-os-firstmate"}}}}},{"metadata":{"name":"agent-os-firstmate-current","uid":"uid-revision-current","ownerReferences":[{"apiVersion":"apps/v1","kind":"StatefulSet","name":"agent-os-firstmate","uid":"uid-statefulset","controller":true}]},"revision":2,"data":{"spec":{"template":{"metadata":{"labels":{"rollback":"current"}},"spec":{"serviceAccountName":"agent-os-firstmate"}}}}}]}'
    fi
    ;;
  *" get Role agent-os-lifecycle-"*" --ignore-not-found -o json "*|\
  *" get RoleBinding agent-os-lifecycle-"*" --ignore-not-found -o json "*|\
  *" get role agent-os-lifecycle-"*" --ignore-not-found -o json "*|\
  *" get rolebinding agent-os-lifecycle-"*" --ignore-not-found -o json "*|\
  *" get rolebinding agent-os-lifecycle-"*" -o json "*)
    control_name=$(printf '%s\n' "$*" | sed -n 's/.* get \([Rr]ole\|[Rr]ole[Bb]inding\) \([^ ]*\) .*/\2/p')
    control_kind=$(printf '%s\n' "$*" | sed -n 's/.* get \([Rr]ole\|[Rr]ole[Bb]inding\) .*/\1/p')
    case "$control_kind" in role) control_kind=Role ;; rolebinding) control_kind=RoleBinding ;; esac
    if ! grep -Fq "/$([ "$control_kind" = Role ] && printf roles || printf rolebindings)/$control_name" "$AGENT_OS_TEST_LOG"; then
      control_account=$(effective_binding_account "$control_name")
      if [ "$control_kind" = Role ]; then
        if [ "${AGENT_OS_TEST_CONTROL_RBAC_STATE:-exact}" = bad-rules ]; then
          printf '{"metadata":{"name":"%s","uid":"uid-control-role","resourceVersion":"rv-control-role","labels":{"app.kubernetes.io/managed-by":"agent-os"},"annotations":{"agent-os.dev/installation-id":"agent-os-firstmate:portable-agent-os"}},"rules":[]}\n' "$control_name"
        else
          printf '{"metadata":{"name":"%s","uid":"uid-control-role","resourceVersion":"rv-control-role","labels":{"app.kubernetes.io/managed-by":"agent-os"},"annotations":{"agent-os.dev/installation-id":"agent-os-firstmate:portable-agent-os"}},"rules":[{"apiGroups":["coordination.k8s.io"],"resources":["leases"],"resourceNames":["%s"],"verbs":["get","update"]}]}\n' "$control_name" "$control_name"
        fi
      else
        printf '{"metadata":{"name":"%s","uid":"uid-control-binding","resourceVersion":"rv-control-binding","labels":{"app.kubernetes.io/managed-by":"agent-os"},"annotations":{"agent-os.dev/installation-id":"agent-os-firstmate:portable-agent-os"}},"roleRef":{"apiGroup":"rbac.authorization.k8s.io","kind":"Role","name":"%s"},"subjects":[{"kind":"ServiceAccount","name":"%s","namespace":"portable-agent-os"}]}\n' "$control_name" "$control_name" "$control_account"
      fi
    fi
    ;;
  *" get role agent-os-firstmate-runtime -o json "*)
    if [ "${AGENT_OS_TEST_RBAC_STATE:-exact}" = bad-rules ]; then
      printf '%s\n' '{"metadata":{"name":"agent-os-firstmate-runtime","labels":{"app.kubernetes.io/managed-by":"agent-os"},"annotations":{"agent-os.dev/installation-id":"agent-os-firstmate:portable-agent-os"}},"rules":[]}'
    else
      printf '%s\n' '{"metadata":{"name":"agent-os-firstmate-runtime","labels":{"app.kubernetes.io/managed-by":"agent-os"},"annotations":{"agent-os.dev/installation-id":"agent-os-firstmate:portable-agent-os"}},"rules":[{"apiGroups":[""],"resources":["pods","persistentvolumeclaims"],"verbs":["get","list","watch","create","delete","patch"]},{"apiGroups":[""],"resources":["pods/log","pods/exec"],"verbs":["get","list","watch","create","delete"]},{"apiGroups":["apps"],"resources":["statefulsets"],"verbs":["get","list","watch"]},{"apiGroups":["coordination.k8s.io"],"resources":["leases"],"verbs":["get","create","update","delete"]}]}'
    fi
    ;;
  *" get rolebinding agent-os-firstmate-runtime -o json "*)
    service_account=$(effective_binding_account agent-os-firstmate-runtime)
    if [ "${AGENT_OS_TEST_RBAC_STATE:-exact}" = extra-subject ]; then
      printf '{"metadata":{"name":"agent-os-firstmate-runtime","uid":"uid-runtime-binding","resourceVersion":"rv-runtime-binding","labels":{"app.kubernetes.io/managed-by":"agent-os"},"annotations":{"agent-os.dev/installation-id":"agent-os-firstmate:portable-agent-os"}},"roleRef":{"apiGroup":"rbac.authorization.k8s.io","kind":"Role","name":"agent-os-firstmate-runtime"},"subjects":[{"kind":"ServiceAccount","name":"%s","namespace":"portable-agent-os"},{"kind":"ServiceAccount","name":"foreign","namespace":"portable-agent-os"}]}\n' "$service_account"
    else
      printf '{"metadata":{"name":"agent-os-firstmate-runtime","uid":"uid-runtime-binding","resourceVersion":"rv-runtime-binding","labels":{"app.kubernetes.io/managed-by":"agent-os"},"annotations":{"agent-os.dev/installation-id":"agent-os-firstmate:portable-agent-os"}},"roleRef":{"apiGroup":"rbac.authorization.k8s.io","kind":"Role","name":"agent-os-firstmate-runtime"},"subjects":[{"kind":"ServiceAccount","name":"%s","namespace":"portable-agent-os"}]}\n' "$service_account"
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
    if grep -F '/clusterrolebindings/agent-os-firstmate-portable-agent-os' "$AGENT_OS_TEST_LOG" | grep -F 'delete --raw' >/dev/null && \
      [ -n "${AGENT_OS_TEST_DELETE_READBACK_STATE:-}" ]; then
      cluster_state=$AGENT_OS_TEST_DELETE_READBACK_STATE
    fi
    if [ -n "${AGENT_OS_TEST_CLUSTER_RBAC_AFTER_APPLY:-}" ] && \
      { grep -E ' create -f .+\.yaml' "$AGENT_OS_TEST_LOG" >/dev/null || grep -F ' --patch-file ' "$AGENT_OS_TEST_LOG" >/dev/null; }; then
      cluster_state=$AGENT_OS_TEST_CLUSTER_RBAC_AFTER_APPLY
    elif grep -F ' create -f ' "$AGENT_OS_TEST_LOG" | grep -F 'clusterrolebinding.yaml' >/dev/null || \
      grep -F ' patch ClusterRoleBinding agent-os-firstmate-' "$AGENT_OS_TEST_LOG" >/dev/null || \
      grep -F ' apply -f ' "$AGENT_OS_TEST_LOG" >/dev/null; then
      cluster_state=${AGENT_OS_TEST_CLUSTER_RBAC_AFTER_APPLY:-owned}
    fi
    case "$cluster_state" in
      absent) ;;
      owned)
        printf 'agent-os-firstmate-%s\tagent-os\tagent-os-firstmate:%s' \
          "${AGENT_OS_TEST_NAMESPACE:-portable-agent-os}" "${AGENT_OS_TEST_NAMESPACE:-portable-agent-os}"
        if [[ " $* " = *'.metadata.resourceVersion'* ]]; then
          current_operation=$(grep 'akua-input-operation ' "$AGENT_OS_TEST_LOG" | tail -n 1 | awk '{print $2}')
          printf '\tuid-clusterrolebinding\trv-clusterrolebinding\t%s' "$current_operation"
        elif [[ " $* " = *'.metadata.uid'* ]]; then
          printf '\tuid-clusterrolebinding\toperation-test\tTrue\t[]'
        fi
        ;;
      replacement)
        printf 'agent-os-firstmate-%s\tagent-os\tagent-os-firstmate:%s\tuid-clusterrolebinding-replacement\trv-clusterrolebinding-replacement\tother-operation' \
          "${AGENT_OS_TEST_NAMESPACE:-portable-agent-os}" "${AGENT_OS_TEST_NAMESPACE:-portable-agent-os}"
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
  *" get serviceaccounts -o json "*)
    residual=${AGENT_OS_TEST_RESIDUAL_SERVICE_ACCOUNT:-}
    if [ -n "$residual" ]; then
      printf '{"items":[{"metadata":{"name":"%s","uid":"uid-residual-serviceaccount","resourceVersion":"rv-residual-serviceaccount","labels":{"app.kubernetes.io/managed-by":"agent-os"},"annotations":{"agent-os.dev/installation-id":"agent-os-firstmate:portable-agent-os"}}}]}\n' "$residual"
    else
      printf '%s\n' '{"items":[]}'
    fi
    ;;
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
    AGENT_OS_LOCK_ACQUIRE_SECONDS=3 \
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
assert_grep 'acquireTime:' "$STDIN_LOG" \
  "lifecycle Leases must record their acquisition time"
assert_grep 'renewTime:' "$STDIN_LOG" \
  "lifecycle Leases must record renewable expiry evidence"
fleet_lock_line=$(grep -Fn 'name: agent-os-firstmate-lifecycle' "$STDIN_LOG" | head -n 1 | cut -d: -f1)
crewmate_lock_line=$(grep -Fn 'name: agent-os-crewmate-scout-1-lifecycle' "$STDIN_LOG" | head -n 1 | cut -d: -f1)
[ -n "$fleet_lock_line" ] && [ -n "$crewmate_lock_line" ] && [ "$fleet_lock_line" -lt "$crewmate_lock_line" ] || \
  fail "crewmate mutation must enter the installation-wide barrier before its resource lock"
lease_holder=$(awk '/holderIdentity:/ { print $2; exit }' "$STDIN_LOG")
case "$lease_holder" in operation-test.*) ;; *) fail "lifecycle Lease identity must add an internal per-invocation nonce" ;; esac
pass "crewmate mutations share the installation-wide lifecycle barrier"
assert_grep 'automountServiceAccountToken: false' "$STDIN_LOG" "children must not receive Kubernetes credentials"
assert_grep 'claimName: agent-os-crewmate-scout-1-home' "$STDIN_LOG" "child work must use its own PVC"
assert_no_grep 'hostUsers: false' "$STDIN_LOG" "OrbStack children must not request unsupported Pod user namespaces"
assert_grep 'runAsUser: 0' "$STDIN_LOG" "children must run as container root"
assert_grep 'name: agent-os-init' "$STDIN_LOG" "children must seed persistent tools"
assert_no_grep 'mountPath: /usr/local' "$STDIN_LOG" "children must keep image-owned /usr/local immutable"
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
grep -Fqx 'kubectl -n agent-os-demo --request-timeout=5s delete --raw /api/v1/namespaces/agent-os-demo/pods/agent-os-crewmate-scout-1 -f -' "$CALLS" || \
  fail "failed create must use an atomic UID-preconditioned delete"
assert_grep '"uid":"uid-owned"' "$STDIN_LOG" \
  "failed create must precondition deletion on the observed Pod UID"
if grep -F 'delete pvc agent-os-crewmate-scout-1-home' "$CALLS" >/dev/null; then
  fail "failed create must retain the crewmate PVC for an authorized retry"
fi
pass "crewmate create fails closed while retaining its persistent home"

: > "$CALLS"
pod_replacement_out=''
pod_replacement_rc=0
pod_replacement_out=$(AGENT_OS_TEST_POD_AFTER_APPLY=replaced-after-ready \
  run_launcher create scout-1 2>&1) || pod_replacement_rc=$?
[ "$pod_replacement_rc" -eq 3 ] || \
  fail "post-ready Pod replacement must exit incomplete: $pod_replacement_out"
assert_contains "$pod_replacement_out" 'captured uid=uid-owned observed uid=uid-replacement' \
  "post-ready continuity failure must report both Pod identities"
if grep -F '/pods/agent-os-crewmate-scout-1' "$CALLS" | grep -F 'delete --raw' >/dev/null; then
  fail "post-ready continuity failure must retain a same-name replacement Pod"
fi
pass "crewmate readiness verifies the original Pod identity"

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
grep -Fqx 'kubectl -n agent-os-demo --request-timeout=5s delete --raw /api/v1/namespaces/agent-os-demo/pods/agent-os-crewmate-scout-1 -f -' "$CALLS" || \
  fail "partial apply cleanup must use an atomic UID-preconditioned delete"
assert_grep '"uid":"uid-owned"' "$STDIN_LOG" \
  "partial apply cleanup must bind deletion to the observed Pod UID"
assert_no_grep 'delete pvc agent-os-crewmate-scout-1-home' "$CALLS" \
  "partial apply cleanup must retain the persistent home"
pass "crewmate partial create cleans only a newly created owned Pod"

: > "$CALLS"
AGENT_OS_TEST_PVC_STATE=clean run_launcher create scout-1
writer_patch_line=$(grep -Fn 'patch pvc agent-os-crewmate-scout-1-home --type=merge' "$CALLS" | head -n 1 | cut -d: -f1)
writer_create_line=$(grep -Fn 'stdin-kind Pod' "$CALLS" | head -n 1 | cut -d: -f1)
[ -n "$writer_patch_line" ] && [ -n "$writer_create_line" ] && [ "$writer_patch_line" -lt "$writer_create_line" ] || \
  fail "every Pod start must invalidate clean checkpoint evidence before creation"
assert_grep '"agent-os.dev/checkpoint-state":"pending"' "$CALLS" \
  "writer activation must CAS the PVC to pending"
assert_grep '"agent-os.dev/writer-state":"active"' "$CALLS" \
  "writer activation must mark the retained PVC as active"
pass "crewmate starts invalidate quiesced checkpoint evidence"

: > "$CALLS"
AGENT_OS_TEST_PVC_STATE=binder-rv run_launcher create scout-1 || \
  fail "normal PVC resourceVersion movement must not change stable UID identity"
pass "crewmate creation tracks PVC UID instead of binder resourceVersion"

: > "$CALLS"
pvc_replaced_rc=0
AGENT_OS_TEST_PVC_STATE=replaced-after-pod run_launcher create scout-1 >/dev/null 2>&1 || pvc_replaced_rc=$?
[ "$pvc_replaced_rc" -ne 0 ] || fail "PVC replacement after Pod creation must fail closed"
grep -F '/pods/agent-os-crewmate-scout-1' "$CALLS" | grep -F 'delete --raw' >/dev/null || \
  fail "PVC replacement must UID-delete only the newly created owned Pod"
pass "crewmate creation retains replacement claims and removes its Pod"

: > "$CALLS"
after_ready_out=''
after_ready_rc=0
after_ready_out=$(AGENT_OS_TEST_PVC_STATE=replaced-after-ready run_launcher create scout-1 2>&1) || after_ready_rc=$?
[ "$after_ready_rc" -eq 3 ] || fail "PVC replacement after Ready must exit incomplete: $after_ready_out"
assert_contains "$after_ready_out" 'uid-pvc-owned' \
  "post-Ready PVC mismatch must report the captured claim UID"
assert_contains "$after_ready_out" 'uid-pvc-after-ready' \
  "post-Ready PVC mismatch must report the observed replacement UID"
grep -F '/pods/agent-os-crewmate-scout-1' "$CALLS" | grep -F 'delete --raw' >/dev/null || \
  fail "post-Ready PVC mismatch must UID-delete only the operation Pod"
assert_grep '"agent-os.dev/checkpoint-state":"pending"' "$CALLS" \
  "post-Ready PVC mismatch must invalidate checkpoint evidence"
pass "crewmate revalidates mounted PVC identity after readiness"

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
grep -Fqx 'kubectl -n agent-os-demo --request-timeout=5s delete --raw /api/v1/namespaces/agent-os-demo/pods/agent-os-crewmate-scout-1 -f -' "$CALLS" || \
  fail "stop must UID-precondition deletion of the exactly owned crewmate Pod"
grep -F 'wait --for=delete pod/agent-os-crewmate-scout-1' "$CALLS" | grep -F -- '--request-timeout=' >/dev/null || \
  fail "stop must prove Pod absence within its total deletion deadline"
if grep -F 'wait --for=delete pod/agent-os-crewmate-scout-1' "$CALLS" | grep -F -- '--timeout=5s' >/dev/null; then
  fail "stop must use the remaining operation deadline rather than the request ceiling for deletion polling"
fi
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
ambiguous_stop_out=''
ambiguous_stop_rc=0
ambiguous_stop_out=$(AGENT_OS_TEST_POD_STATE=owned AGENT_OS_TEST_PVC_STATE=owned \
  AGENT_OS_TEST_FAIL_DELETE_TARGET=/pods/agent-os-crewmate-scout-1 \
  AGENT_OS_TEST_DELETE_ERROR='context deadline exceeded' run_launcher stop scout-1 2>&1) || ambiguous_stop_rc=$?
[ "$ambiguous_stop_rc" -eq 0 ] || fail "accepted ambiguous Pod delete must reconcile absence: $ambiguous_stop_out"
assert_contains "$ambiguous_stop_out" 'confirmed absent: pod/agent-os-crewmate-scout-1 captured uid=uid-owned' \
  "ambiguous stop must report terminal absence evidence"
assert_grep 'agent-os.dev/quiesced-operation' "$CALLS" \
  "stop may record quiescence only after ambiguous deletion is reconciled as absent"
pass "crewmate stop reconciles ambiguous Pod deletion"

: > "$CALLS"
replacement_stop_out=''
replacement_stop_rc=0
replacement_stop_out=$(AGENT_OS_TEST_POD_STATE=owned AGENT_OS_TEST_POD_AFTER_DELETE=replacement \
  AGENT_OS_TEST_PVC_STATE=owned AGENT_OS_TEST_FAIL_DELETE_TARGET=/pods/agent-os-crewmate-scout-1 \
  AGENT_OS_TEST_DELETE_ERROR='context deadline exceeded' run_launcher stop scout-1 2>&1) || replacement_stop_rc=$?
[ "$replacement_stop_rc" -eq 3 ] || fail "ambiguous Pod replacement must exit incomplete: $replacement_stop_out"
assert_contains "$replacement_stop_out" 'replacement uid=uid-replacement retained; captured uid=uid-owned' \
  "ambiguous stop must retain and report a same-name replacement"
assert_no_grep 'agent-os.dev/writer-state":"quiesced' "$CALLS" \
  "stop must not record quiescence for a replacement Pod"
pass "crewmate stop retains ambiguous same-name replacements"

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
grep -Fqx 'kubectl -n agent-os-demo --request-timeout=5s delete --raw /api/v1/namespaces/agent-os-demo/persistentvolumeclaims/agent-os-crewmate-scout-1-home -f -' "$CALLS" || \
  fail "purge must atomically delete the exactly owned persistent home"
assert_grep '"uid":"uid-pvc-owned","resourceVersion":"rv-pvc-owned"' "$STDIN_LOG" \
  "purge must precondition deletion on the captured PVC UID and resourceVersion"
assert_grep 'purge-complete' "$PURGE_EVIDENCE" "purge must record non-secret completion evidence"
assert_no_grep 'scout-1-ai-auth' "$PURGE_EVIDENCE" "purge evidence must never contain credential references"
pass "crewmate purge requires confirmation and a clean checkpoint"

: > "$CALLS"
: > "$PURGE_EVIDENCE"
ambiguous_purge_out=''
ambiguous_purge_rc=0
ambiguous_purge_out=$(AGENT_OS_TEST_POD_STATE=absent AGENT_OS_TEST_PVC_STATE=clean \
  AGENT_OS_TEST_PVC_AFTER_DELETE=absent \
  AGENT_OS_TEST_FAIL_DELETE_TARGET=/persistentvolumeclaims/agent-os-crewmate-scout-1-home \
  AGENT_OS_TEST_DELETE_ERROR='context deadline exceeded' run_launcher purge scout-1 --yes 2>&1) || ambiguous_purge_rc=$?
[ "$ambiguous_purge_rc" -eq 0 ] || fail "accepted ambiguous PVC delete must reconcile absence: $ambiguous_purge_out"
assert_grep 'purge-complete' "$PURGE_EVIDENCE" \
  "ambiguous purge accepted by the API must record terminal completion evidence"
assert_grep 'outcome=absent' "$PURGE_EVIDENCE" \
  "completed purge evidence must classify the captured PVC as absent"
assert_grep 'captured-uid=uid-pvc-owned' "$PURGE_EVIDENCE" \
  "completed purge evidence must retain the captured PVC UID"
assert_grep 'observed-uid=absent' "$PURGE_EVIDENCE" \
  "completed purge evidence must classify the captured PVC as absent"
assert_contains "$ambiguous_purge_out" 'confirmed absent: pvc/agent-os-crewmate-scout-1-home captured uid=uid-pvc-owned' \
  "ambiguous purge must report the captured PVC identity as absent"
pass "crewmate purge reconciles ambiguous PVC deletion"

: > "$CALLS"
: > "$PURGE_EVIDENCE"
retained_purge_out=''
retained_purge_rc=0
retained_purge_out=$(AGENT_OS_TEST_POD_STATE=absent AGENT_OS_TEST_PVC_STATE=clean \
  AGENT_OS_TEST_FAIL_DELETE_TARGET=/persistentvolumeclaims/agent-os-crewmate-scout-1-home \
  AGENT_OS_TEST_DELETE_ERROR='context deadline exceeded' run_launcher purge scout-1 --yes 2>&1) || retained_purge_rc=$?
[ "$retained_purge_rc" -eq 3 ] || fail "ambiguous retained PVC must exit incomplete: $retained_purge_out"
assert_contains "$retained_purge_out" 'original uid=uid-pvc-owned remains' \
  "ambiguous purge must report the retained original PVC identity"
assert_grep 'purge-incomplete-original-retained' "$PURGE_EVIDENCE" \
  "ambiguous retained PVC must record terminal incomplete evidence"
assert_grep 'outcome=original-retained' "$PURGE_EVIDENCE" \
  "ambiguous retained PVC must classify the original identity"
assert_grep 'captured-uid=uid-pvc-owned' "$PURGE_EVIDENCE" \
  "ambiguous retained PVC must retain its captured identity"
assert_grep 'observed-uid=uid-pvc-owned' "$PURGE_EVIDENCE" \
  "ambiguous retained PVC must record terminal incomplete evidence"
pass "crewmate purge records retained original PVC evidence"

: > "$CALLS"
: > "$PURGE_EVIDENCE"
replacement_purge_out=''
replacement_purge_rc=0
replacement_purge_out=$(AGENT_OS_TEST_POD_STATE=absent AGENT_OS_TEST_PVC_STATE=clean \
  AGENT_OS_TEST_PVC_AFTER_DELETE=foreign \
  AGENT_OS_TEST_FAIL_DELETE_TARGET=/persistentvolumeclaims/agent-os-crewmate-scout-1-home \
  AGENT_OS_TEST_DELETE_ERROR='context deadline exceeded' run_launcher purge scout-1 --yes 2>&1) || replacement_purge_rc=$?
[ "$replacement_purge_rc" -eq 3 ] || fail "ambiguous PVC replacement must exit incomplete: $replacement_purge_out"
assert_contains "$replacement_purge_out" 'replacement uid=uid-pvc-foreign retained; captured uid=uid-pvc-owned' \
  "ambiguous purge must retain and report a same-name replacement PVC"
assert_grep 'purge-incomplete-replacement-retained' "$PURGE_EVIDENCE" \
  "replacement PVC must record terminal incomplete evidence"
assert_grep 'outcome=replacement-retained' "$PURGE_EVIDENCE" \
  "replacement PVC must classify its terminal outcome"
assert_grep 'captured-uid=uid-pvc-owned' "$PURGE_EVIDENCE" \
  "replacement PVC must retain the captured UID"
assert_grep 'observed-uid=uid-pvc-foreign' "$PURGE_EVIDENCE" \
  "replacement PVC must record terminal incomplete evidence"
pass "crewmate purge retains ambiguous same-name replacements"

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
assert_contains "$lock_out" "still holds Lease 'agent-os-crewmate-scout-1-lifecycle' after 3s" \
  "lifecycle contention must report the exact holder and bounded timeout"
pass "crewmate lifecycle operations use a bounded coordination lock"

: > "$CALLS"
expired_lock_rc=0
expired_lock_out=$(AGENT_OS_TEST_LOCK_STATE=expired AGENT_OS_TEST_PVC_STATE=owned run_launcher stop scout-1 2>&1) || expired_lock_rc=$?
[ "$expired_lock_rc" -eq 0 ] || fail "expired exact-owned lifecycle Lease takeover must complete cleanly: $expired_lock_out"
grep -F 'replace -f -' "$CALLS" >/dev/null || \
  fail "expired exact-owned lifecycle Leases must use resourceVersion-CAS takeover"
pass "crewmate lifecycle can recover exact-owned expired Leases"

: > "$CALLS"
ambiguous_lock_out=''
ambiguous_lock_rc=0
ambiguous_lock_out=$(AGENT_OS_TEST_LOCK_STATE=ambiguous-create AGENT_OS_TEST_PVC_STATE=owned \
  run_launcher stop scout-1 2>&1) || ambiguous_lock_rc=$?
[ "$ambiguous_lock_rc" -eq 0 ] || \
  fail "ambiguous Lease create must accept verified own-holder read-back: $ambiguous_lock_out"
pass "crewmate Lease acquisition reconciles ambiguous create success"

: > "$CALLS"
: > "$STDIN_LOG"
AGENT_OS_TEST_LOCK_STATE=expired AGENT_OS_TEST_LOCK_RV=12345 AGENT_OS_TEST_PVC_STATE=owned \
  run_launcher stop scout-1
assert_grep 'resourceVersion: "12345"' "$STDIN_LOG" \
  "Lease takeover must serialize decimal resourceVersion as a string"
pass "crewmate Lease CAS preserves opaque resourceVersion typing"

: > "$CALLS"
AGENT_OS_LOCK_DURATION_SECONDS=10 AGENT_OS_TEST_READY_DELAY=4 \
  AGENT_OS_TEST_PVC_STATE=owned run_launcher create scout-1
grep -F 'replace -f -' "$CALLS" >/dev/null || \
  fail "active lifecycle operations must renew their exact-owned Lease"
pass "crewmate lifecycle renews its Lease while active"

: > "$CALLS"
renewal_rc=0
AGENT_OS_LOCK_DURATION_SECONDS=10 AGENT_OS_TEST_READY_DELAY=4 \
  AGENT_OS_TEST_RENEW_READBACK=wrong AGENT_OS_TEST_PVC_STATE=owned \
  run_launcher create scout-1 >/dev/null 2>&1 || renewal_rc=$?
[ "$renewal_rc" -eq 3 ] || fail "renewal must fail closed when exact renewTime read-back is not committed"
pass "crewmate Lease renewal verifies the committed renewTime"

: > "$CALLS"
AGENT_OS_TEST_POD_STATE=absent AGENT_OS_TEST_PVC_STATE=owned run_launcher stop scout-1
lease_create_call=$(grep 'create -f -' "$CALLS" | head -n 1)
assert_contains "$lease_create_call" '--request-timeout=2s' \
  "Lease create must reserve acquisition time for mandatory result reconciliation"
pass "crewmate Lease mutations reserve read-back budget"

lease_call_without_timeout=$(awk '
  /^kubectl / { call=$0 }
  / get lease | delete --raw .*\/leases\// { if ($0 !~ /--request-timeout=/) print }
  /^stdin-kind Lease$/ { if (call !~ /--request-timeout=/) print call }
' "$CALLS")
[ -z "$lease_call_without_timeout" ] || \
  fail "every Lease request must carry a bounded request timeout: $lease_call_without_timeout"
pass "crewmate Lease requests are bounded within lock validity"

: > "$CALLS"
AGENT_OS_TEST_POD_STATE=absent AGENT_OS_TEST_PVC_STATE=owned \
  AGENT_OS_TEST_LOCK_RELEASE_STATE=foreign run_launcher stop scout-1
pass "crewmate Lease release accepts an independently replaced Lease"

: > "$CALLS"
AGENT_OS_TEST_POD_STATE=absent AGENT_OS_TEST_PVC_STATE=owned \
  AGENT_OS_TEST_LOCK_RELEASE_STATE=next-owner run_launcher stop scout-1
pass "crewmate Lease release accepts a subsequent legitimate holder"

if run_launcher create 'Bad_ID' >/dev/null 2>&1; then
  fail "invalid Kubernetes crewmate IDs must be rejected"
fi
pass "crewmate IDs are validated before kubectl"

: > "$CALLS"
if run_launcher create 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' >/dev/null 2>&1; then
  fail "crewmate IDs that overflow a derived Lease name must be rejected"
fi
[ ! -s "$CALLS" ] || fail "derived Kubernetes names must be validated before kubectl"
pass "all crewmate-derived Kubernetes names are validated before cluster calls"

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
service_account=$(awk '/^serviceAccountName:/{print $2}' "$inputs")
[ -n "$service_account" ] || service_account=agent-os-firstmate
printf 'akua-input-operation %s\n' "$operation" >> "$AGENT_OS_TEST_LOG"
printf 'akua-input-service-account %s\n' "$service_account" >> "$AGENT_OS_TEST_LOG"
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
  resource_name=agent-os-firstmate
  [ "$resource" != ServiceAccount ] || resource_name=$service_account
  cat > "$out/$file.yaml" <<YAML
apiVersion: v1
kind: $resource
metadata:
  name: $resource_name
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
  local workload_state=${AGENT_OS_TEST_WORKLOAD_STATE:-absent} resource_state=${AGENT_OS_TEST_RESOURCE_STATE:-}
  if [ -z "$resource_state" ]; then
    [ "$workload_state" = absent ] && resource_state=absent || resource_state=owned
  fi
  PATH="$FAKEBIN:$PATH" AGENT_OS_TEST_LOG="$CALLS" AGENT_OS_STDIN_LOG="$STDIN_LOG" AGENT_OS_INPUTS="$GENERIC_INPUTS" \
    AGENT_OS_TEST_NAMESPACE=portable-agent-os \
    AGENT_OS_TEST_NAMESPACE_STATE="${AGENT_OS_TEST_NAMESPACE_STATE:-absent}" \
    AGENT_OS_TEST_WORKLOAD_STATE="$workload_state" AGENT_OS_TEST_RESOURCE_STATE="$resource_state" \
    AGENT_OS_TEST_CLUSTER_RBAC_STATE="${AGENT_OS_TEST_CLUSTER_RBAC_STATE:-absent}" \
    AGENT_OS_TEST_COMMAND="${1:-}" \
    AGENT_OS_OPERATION_ID=operation-test \
    AGENT_OS_CONTEXT=kind-agent-os AGENT_OS_NAMESPACE=portable-agent-os "$GENERIC" "$@"
}

: > "$CALLS"
run_generic install
grep -Fq -- "akua render --no-agent-mode --package $ROOT/tools/agent-os/packages/firstmate/package.k --inputs " "$CALLS" || \
  fail "generic install must render the canonical package before applying it"
if grep -F 'kubectl --context kind-agent-os apply -f ' "$CALLS" >/dev/null; then
  fail "generic install must not adopt same-name resources through apply"
fi
grep -F 'kubectl --context kind-agent-os create -f ' "$CALLS" >/dev/null || \
  fail "generic install must create absent rendered resources atomically"
grep -F 'agent-os-firstmate-lifecycle' "$STDIN_LOG" >/dev/null || \
  fail "primary mutations must hold an exact-owned Kubernetes Lease"
grep -Fqx 'akua-input-operation operation-test' "$CALLS" || \
  fail "generic install must label every resource with its unique operation identity"
generated_service_account=$(grep 'akua-input-service-account ' "$CALLS" | tail -n 1 | awk '{print $2}')
case "$generated_service_account" in agent-os-firstmate-[a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9]) ;; \
  *) fail "install must use a fresh non-legacy ServiceAccount identity" ;; esac
grep -Fqx 'kubectl --context kind-agent-os -n portable-agent-os rollout status statefulset/agent-os-firstmate --timeout=180s' "$CALLS" || \
  fail "generic install must wait for the rendered Firstmate StatefulSet: $(tail -n 20 "$CALLS" | tr '\n' ';')"
if grep -F 'delete clusterrolebinding' "$CALLS" >/dev/null; then
  fail "fresh namespace-scoped install must not require cluster RBAC deletion authority"
fi
pass "generic install serializes create-only canonical package mutations"

: > "$CALLS"
stale_install_out=''
stale_install_rc=0
stale_install_out=$(AGENT_OS_TEST_CLUSTER_RBAC_STATE=owned run_generic install 2>&1) || stale_install_rc=$?
[ "$stale_install_rc" -eq 3 ] || fail "stale cluster authority must block a namespace reinstall: $stale_install_out"
assert_contains "$stale_install_out" 'must be removed through separately authorized cleanup' \
  "namespace reinstall must not reactivate a deterministic legacy cluster grant"
assert_no_grep 'create -f .*serviceaccount.yaml' "$CALLS" \
  "legacy cluster authority must fail before a new ServiceAccount is created"
pass "fresh installs preflight deterministic legacy cluster authority"

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
  AGENT_OS_TEST_FAIL_ROLLOUT=1 AGENT_OS_OPERATION_ID=operation-test \
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
  AGENT_OS_TEST_CLUSTER_RBAC_AFTER_APPLY=owned AGENT_OS_TEST_FAIL_ROLLOUT=1 \
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
conflicted_recovery_out=''
conflicted_recovery_rc=0
conflicted_recovery_out=$(AGENT_OS_TEST_WORKLOAD_STATE=namespace AGENT_OS_TEST_NAMESPACE_STATE=owned \
  AGENT_OS_TEST_WORKLOAD_AFTER_APPLY=namespace AGENT_OS_TEST_RESOURCE_STATE=owned \
  AGENT_OS_TEST_RESOURCE_AFTER_APPLY=foreign AGENT_OS_TEST_FAIL_ROLLOUT=1 \
  run_generic upgrade 2>&1) || conflicted_recovery_rc=$?
[ "$conflicted_recovery_rc" -eq 3 ] || \
  fail "conflicted partial recovery must remain incomplete: $conflicted_recovery_out"
assert_contains "$conflicted_recovery_out" 'safe recovery unavailable:' \
  "partial recovery must reject conflicts across the complete rendered resource set"
assert_not_contains "$conflicted_recovery_out" 'agent-os-kubernetes.sh upgrade' \
  "partial recovery must not advertise an upgrade that its preflight rejects"
pass "primary recovery reuses complete rendered ownership predicates"

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
grep -E 'kubectl --context kind-agent-os (create -f|.* patch )' "$CALLS" >/dev/null || \
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
apply_line=$(grep -Fn -- '--patch-file ' "$CALLS" | head -n 1 | cut -d: -f1)
marker_line=$(grep -Fn 'patch StatefulSet agent-os-firstmate' "$CALLS" | grep 'cluster-rbac-cleanup.*required' | head -n 1 | cut -d: -f1)
rollout_line=$(grep -Fn 'kubectl --context kind-agent-os -n portable-agent-os rollout status' "$CALLS" | head -n 1 | cut -d: -f1)
verify_line=$(grep -Fn 'kubectl --context kind-agent-os -n portable-agent-os get role agent-os-firstmate-runtime' "$CALLS" | head -n 1 | cut -d: -f1)
[ -n "$marker_line" ] && [ -n "$apply_line" ] && [ -n "$rollout_line" ] && [ -n "$verify_line" ] && \
  [ "$marker_line" -lt "$apply_line" ] && [ "$apply_line" -lt "$rollout_line" ] && \
  [ "$rollout_line" -lt "$verify_line" ] || \
  fail "downgrade must apply and roll out desired namespaced RBAC before privileged cleanup is requested"
assert_grep 'get clusterrolebinding agent-os-firstmate-portable-agent-os --ignore-not-found' "$CALLS" \
  "namespace upgrades must perform the separately authorized deterministic legacy-grant preflight"
assert_no_grep 'delete clusterrolebinding' "$CALLS" \
  "routine namespace upgrades must not delete cluster-scoped authority"
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
if grep -F -- '--patch-file ' "$CALLS" >/dev/null || grep -E ' create -f .+\.yaml' "$CALLS" >/dev/null; then
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
grep -F '/apis/rbac.authorization.k8s.io/v1/clusterrolebindings/agent-os-firstmate-portable-agent-os' "$CALLS" | grep -F 'delete --raw' >/dev/null || \
  fail "privileged cleanup must UID-delete only the exact owned ClusterRoleBinding"
assert_grep '"uid":"uid-clusterrolebinding","resourceVersion":"rv-clusterrolebinding"' "$STDIN_LOG" \
  "privileged cleanup must bind deletion to the observed grant identity"
grep -F 'wait --for=delete ClusterRoleBinding/agent-os-firstmate-portable-agent-os --timeout=' "$CALLS" >/dev/null || \
  fail "privileged cleanup must produce deletion evidence for the exact binding"
grep -F 'wait --for=delete ClusterRoleBinding/agent-os-firstmate-portable-agent-os --timeout=' "$CALLS" | \
  grep -F -- '--request-timeout=' >/dev/null || \
  fail "delete wait must reserve five seconds for bounded identity reconciliation"
pass "privileged cleanup verifies ownership and deletes one exact binding"

cleanup_delete_call=$(grep -F '/apis/rbac.authorization.k8s.io/v1/clusterrolebindings/agent-os-firstmate-portable-agent-os' "$CALLS" | \
  grep -F 'delete --raw' | tail -n 1)
assert_contains "$cleanup_delete_call" '--request-timeout=' \
  "raw delete requests must be bounded before the operation wait begins"
cleanup_observe_call=$(grep 'get ClusterRoleBinding agent-os-firstmate-portable-agent-os --ignore-not-found' "$CALLS" | \
  grep 'metadata.resourceVersion' | tail -n 1)
assert_contains "$cleanup_observe_call" '--request-timeout=' \
  "cluster cleanup deletion deadline must start before the ownership observation"

: > "$CALLS"
cleanup_stale_out=''
cleanup_stale_rc=0
cleanup_stale_out=$(AGENT_OS_TEST_NAMESPACE_STATE=owned AGENT_OS_TEST_WORKLOAD_STATE=pending \
  AGENT_OS_TEST_CLUSTER_RBAC_STATE=owned AGENT_OS_TEST_STALE_RBAC_STATE=foreign \
  run_generic cleanup-cluster-rbac --yes 2>&1) || cleanup_stale_rc=$?
[ "$cleanup_stale_rc" -eq 2 ] || fail "privileged cleanup must preflight foreign stale RBAC: $cleanup_stale_out"
assert_no_grep '/clusterrolebindings/agent-os-firstmate-portable-agent-os' "$CALLS" \
  "privileged cleanup must reject foreign namespaced RBAC before cluster mutation"
pass "privileged cleanup preflights deterministic namespaced RBAC"

: > "$CALLS"
cleanup_delete_out=''
cleanup_delete_rc=0
cleanup_delete_out=$(AGENT_OS_TEST_NAMESPACE_STATE=owned AGENT_OS_TEST_WORKLOAD_STATE=pending \
  AGENT_OS_TEST_CLUSTER_RBAC_STATE=owned \
  AGENT_OS_TEST_FAIL_DELETE_TARGET=clusterrolebindings/agent-os-firstmate-portable-agent-os \
  AGENT_OS_TEST_DELETE_ERROR='Error from server (Conflict): object changed' \
  run_generic cleanup-cluster-rbac --yes 2>&1) || cleanup_delete_rc=$?
[ "$cleanup_delete_rc" -eq 1 ] || fail "privileged cleanup delete conflict must exit failed: $cleanup_delete_out"
assert_contains "$cleanup_delete_out" 'delete-request-failure=Conflict' \
  "privileged cleanup must preserve immediate delete failure class"
assert_contains "$cleanup_delete_out" 'timeout=60s' \
  "privileged cleanup must report its actual deletion bound"
assert_contains "$cleanup_delete_out" 'retained: ClusterRoleBinding/agent-os-firstmate-portable-agent-os uid=uid-clusterrolebinding' \
  "privileged cleanup failure must inventory the retained exact grant"
assert_contains "$cleanup_delete_out" 'safe retry:' \
  "privileged cleanup failure must print exact retry evidence"
pass "privileged cleanup failures report retained grant evidence"

: > "$CALLS"
not_found_out=''
not_found_rc=0
not_found_out=$(AGENT_OS_TEST_NAMESPACE_STATE=owned AGENT_OS_TEST_WORKLOAD_STATE=pending \
  AGENT_OS_TEST_CLUSTER_RBAC_STATE=owned AGENT_OS_TEST_DELETE_READBACK_STATE=absent \
  AGENT_OS_TEST_FAIL_DELETE_TARGET=clusterrolebindings/agent-os-firstmate-portable-agent-os \
  AGENT_OS_TEST_DELETE_ERROR='Error from server (NotFound): object disappeared' \
  run_generic cleanup-cluster-rbac --yes 2>&1) || not_found_rc=$?
[ "$not_found_rc" -eq 0 ] || fail "NotFound with confirmed absence must complete: $not_found_out"
assert_contains "$not_found_out" 'clusterrolebinding/agent-os-firstmate-portable-agent-os absent' \
  "NotFound reconciliation must emit confirmed absence evidence"
pass "delete NotFound races reconcile confirmed absence"

: > "$CALLS"
replacement_delete_out=''
replacement_delete_rc=0
replacement_delete_out=$(AGENT_OS_TEST_NAMESPACE_STATE=owned AGENT_OS_TEST_WORKLOAD_STATE=pending \
  AGENT_OS_TEST_CLUSTER_RBAC_STATE=owned AGENT_OS_TEST_DELETE_READBACK_STATE=replacement \
  AGENT_OS_TEST_FAIL_DELETE_TARGET=clusterrolebindings/agent-os-firstmate-portable-agent-os \
  AGENT_OS_TEST_DELETE_ERROR='transport timeout' \
  run_generic cleanup-cluster-rbac --yes 2>&1) || replacement_delete_rc=$?
[ "$replacement_delete_rc" -eq 1 ] || \
  fail "ambiguous delete with replacement must remain incomplete: $replacement_delete_out"
assert_contains "$replacement_delete_out" 'replacement uid=uid-clusterrolebinding-replacement retained' \
  "ambiguous delete reconciliation must report and retain a replacement UID"
pass "ambiguous deletes retain same-name replacements"

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
  AGENT_OS_TEST_WORKLOAD_STATE=namespace AGENT_OS_TEST_RESOURCE_STATE=owned AGENT_OS_CONTEXT=kind-agent-os \
  AGENT_OS_NAMESPACE=portable-agent-os "$GENERIC" upgrade
grep -F '/apis/rbac.authorization.k8s.io/v1/namespaces/portable-agent-os/rolebindings/agent-os-firstmate-runtime' "$CALLS" | grep -F 'delete --raw' >/dev/null || \
  fail "cluster-admin upgrade must UID-delete the stale namespace RoleBinding"
grep -F '/apis/rbac.authorization.k8s.io/v1/namespaces/portable-agent-os/roles/agent-os-firstmate-runtime' "$CALLS" | grep -F 'delete --raw' >/dev/null || \
  fail "cluster-admin upgrade must UID-delete the stale namespace Role"
apply_line=$(grep -Fn -- '--patch-file ' "$CALLS" | head -n 1 | cut -d: -f1)
delete_line=$(grep -Fn '/rolebindings/agent-os-firstmate-runtime' "$CALLS" | grep 'delete --raw' | head -n 1 | cut -d: -f1)
[ -n "$apply_line" ] && [ -n "$delete_line" ] && [ "$apply_line" -lt "$delete_line" ] || \
  fail "cluster-admin upgrade must apply replacement authority before removing namespace RBAC"
if grep -F 'delete clusterrolebinding agent-os-firstmate-portable-agent-os' "$CALLS" >/dev/null; then
  fail "routine cluster-admin upgrade must retain its rendered ClusterRoleBinding"
fi
pass "cluster-admin upgrade reconciles namespaced authority after apply"

: > "$CALLS"
: > "$STDIN_LOG"
AGENT_OS_TEST_NAMESPACE_STATE=owned AGENT_OS_TEST_RESOURCE_STATE=owned \
  AGENT_OS_TEST_RESOURCE_RV=67890 AGENT_OS_TEST_PRIMARY_LOCK_RV=12345 \
  AGENT_OS_TEST_PRIMARY_LOCK_STATE=expired \
  AGENT_OS_TEST_WORKLOAD_STATE=namespace run_generic upgrade
assert_grep 'resourceVersion: "67890"' "$STDIN_LOG" \
  "primary resource mutation must serialize decimal resourceVersion as a string"
assert_grep 'resourceVersion: "12345"' "$STDIN_LOG" \
  "primary Lease CAS must serialize decimal resourceVersion as a string"
pass "primary CAS preserves opaque resourceVersion typing"

: > "$CALLS"
stale_rbac_out=''
stale_rbac_rc=0
stale_rbac_out=$(PATH="$FAKEBIN:$PATH" AGENT_OS_TEST_LOG="$CALLS" AGENT_OS_INPUTS="$CLUSTER_ADMIN_INPUTS" \
  AGENT_OS_TEST_NAMESPACE=portable-agent-os AGENT_OS_TEST_NAMESPACE_STATE=owned \
  AGENT_OS_TEST_WORKLOAD_STATE=namespace AGENT_OS_TEST_RESOURCE_STATE=owned \
  AGENT_OS_TEST_STALE_RBAC_STATE=foreign AGENT_OS_CONTEXT=kind-agent-os \
  AGENT_OS_OPERATION_ID=operation-test AGENT_OS_NAMESPACE=portable-agent-os \
  "$GENERIC" upgrade 2>&1) || stale_rbac_rc=$?
[ "$stale_rbac_rc" -eq 2 ] || fail "foreign stale namespaced RBAC must fail preflight: $stale_rbac_out"
assert_contains "$stale_rbac_out" "Role 'agent-os-firstmate-runtime' does not have the exact Agent OS installation identity" \
  "every RBAC mode must preflight deterministic stale names"
assert_no_grep 'patch StatefulSet agent-os-firstmate' "$CALLS" \
  "foreign stale RBAC must fail before desired resources mutate"
pass "all RBAC modes preflight deterministic stale resources"

: > "$CALLS"
active_checkpoint_out=''
active_checkpoint_rc=0
active_checkpoint_digest=$(printf '%s' '{"metadata":{"labels":{"rollback":"previous"}},"spec":{"serviceAccountName":"agent-os-firstmate"}}' | jq -cS . | shasum -a 256 | awk '{print $1}')
active_checkpoint_out=$(AGENT_OS_TEST_NAMESPACE_STATE=owned AGENT_OS_TEST_RESOURCE_STATE=owned \
  AGENT_OS_TEST_WORKLOAD_STATE=namespace AGENT_OS_TEST_ROLLBACK_CHECKPOINT_DIGEST="$active_checkpoint_digest" \
  run_generic upgrade 2>&1) || active_checkpoint_rc=$?
[ "$active_checkpoint_rc" -eq 3 ] || fail "active rollback checkpoint must block upgrade: $active_checkpoint_out"
assert_contains "$active_checkpoint_out" 'active rollback checkpoint blocks upgrade' \
  "upgrade must require exact rollback recovery and checkpoint finalization"
assert_no_grep 'patch StatefulSet agent-os-firstmate --type=strategic --patch-file' "$CALLS" \
  "blocked upgrade must not mutate the StatefulSet template"
pass "upgrade refuses stale rollback checkpoints"

: > "$CALLS"
AGENT_OS_TEST_NAMESPACE_STATE=owned AGENT_OS_TEST_RESOURCE_STATE=owned \
  AGENT_OS_TEST_WORKLOAD_STATE=namespace AGENT_OS_TEST_AKUA_OVERLAY_SECRET=akua-auth \
  run_generic upgrade
assert_grep 'patch StatefulSet agent-os-firstmate --type=strategic --patch-file' "$CALLS" \
  "upgrade must preserve the verified authorization overlay in its StatefulSet CAS"
assert_grep 'get secret akua-auth --ignore-not-found' "$CALLS" \
  "upgrade must verify the namespace-local Secret reference without reading Secret bytes"
assert_no_grep 'authorization.*Bearer\|auth.json' "$STDIN_LOG" \
  "upgrade evidence must never contain Secret bytes"
pass "upgrade preserves verified Akua Secret-reference overlays"

statefulset_patch_line=$(grep -Fn 'patch StatefulSet agent-os-firstmate --type=strategic --patch-file' "$CALLS" | head -n 1 | cut -d: -f1)
secret_reads_before_patch=$(sed -n "1,${statefulset_patch_line}p" "$CALLS" | grep -Fc 'get secret akua-auth --ignore-not-found')
[ -n "$statefulset_patch_line" ] && [ "$secret_reads_before_patch" -ge 2 ] || \
  fail "upgrade must revalidate the exact Secret identity immediately before StatefulSet CAS"
pass "upgrade revalidates authorization immediately before CAS"

: > "$CALLS"
upgrade_reconcile_out=''
upgrade_reconcile_rc=0
upgrade_reconcile_out=$(AGENT_OS_TEST_NAMESPACE_STATE=owned AGENT_OS_TEST_RESOURCE_STATE=owned \
  AGENT_OS_TEST_WORKLOAD_STATE=namespace AGENT_OS_TEST_AKUA_OVERLAY_SECRET=akua-auth \
  AGENT_OS_TEST_FAIL_FIRST_ROLLOUT=1 run_generic upgrade 2>&1) || upgrade_reconcile_rc=$?
[ "$upgrade_reconcile_rc" -eq 3 ] || fail "post-CAS rollout failure must remain incomplete: $upgrade_reconcile_out"
assert_grep 'agent-os.dev/akua-auth-rejected-record' "$CALLS" \
  "post-CAS upgrade failure must record fail-closed authorization evidence"
assert_grep '"AKUA_AUTH_HEADER_FILE","$patch":"delete"' "$CALLS" \
  "post-CAS upgrade failure must remove the mounted authorization overlay"
pass "upgrade post-CAS failures reconcile authorization fail closed"

: > "$CALLS"
replacement_reconcile_out=''
replacement_reconcile_rc=0
replacement_reconcile_out=$(AGENT_OS_TEST_NAMESPACE_STATE=owned AGENT_OS_TEST_RESOURCE_STATE=owned \
  AGENT_OS_TEST_WORKLOAD_STATE=namespace AGENT_OS_TEST_AKUA_OVERLAY_SECRET=akua-auth \
  AGENT_OS_TEST_FAIL_FIRST_ROLLOUT=1 AGENT_OS_TEST_REPLACE_STATEFULSET_AFTER_ROLLOUT=1 \
  run_generic upgrade 2>&1) || replacement_reconcile_rc=$?
[ "$replacement_reconcile_rc" -eq 3 ] || fail "replacement workload reconciliation must fail closed: $replacement_reconcile_out"
assert_not_contains "$replacement_reconcile_out" 'authorization overlay removed' \
  "replacement workload must never be reported as reconciled"
assert_no_grep 'agent-os.dev/akua-auth-rejected-record' "$CALLS" \
  "upgrade compensation must not mutate a replacement StatefulSet"
pass "upgrade compensation leaves replacement workloads untouched"

: > "$CALLS"
AGENT_OS_TEST_NAMESPACE_STATE=owned AGENT_OS_TEST_RESOURCE_STATE=owned \
  AGENT_OS_TEST_WORKLOAD_STATE=namespace \
  AGENT_OS_TEST_WORKLOAD_SERVICE_ACCOUNT=agent-os-firstmate-bbbbbbbbbbbb run_generic upgrade
[ "$(grep 'akua-input-service-account ' "$CALLS" | tail -n 1 | awk '{print $2}')" = agent-os-firstmate-bbbbbbbbbbbb ] || \
  fail "upgrade retries must reuse the verified installation ServiceAccount identity"
assert_no_grep '/serviceaccounts/agent-os-firstmate-bbbbbbbbbbbb' "$CALLS" \
  "upgrade retries must not delete their active installation ServiceAccount"
pass "upgrade reuses fresh installation ServiceAccount identity"

: > "$CALLS"
AGENT_OS_TEST_NAMESPACE_STATE=owned AGENT_OS_TEST_RESOURCE_STATE=owned \
  AGENT_OS_TEST_WORKLOAD_STATE=namespace run_generic upgrade
assert_no_grep '/serviceaccounts/agent-os-firstmate ' "$CALLS" \
  "upgrade must retain a legacy ServiceAccount referenced by rollback history"
pass "upgrade retains rollback ServiceAccount dependencies"

: > "$CALLS"
AGENT_OS_TEST_NAMESPACE_STATE=owned AGENT_OS_TEST_RESOURCE_STATE=owned \
  AGENT_OS_TEST_WORKLOAD_STATE=namespace run_generic rollback
checkpoint_line=$(grep -Fn 'agent-os.dev/rollback-target-digest' "$CALLS" | head -n 1 | cut -d: -f1)
template_patch_line=$(grep -Fn '"rollback":"previous"' "$CALLS" | head -n 1 | cut -d: -f1)
[ -n "$checkpoint_line" ] && [ -n "$template_patch_line" ] && [ "$checkpoint_line" -lt "$template_patch_line" ] || \
  fail "rollback must persist its immutable target checkpoint before patching the template"
assert_grep 'agent-os.dev/rollback-target-uid' "$CALLS" \
  "rollback checkpoint must persist exact ControllerRevision identity"
checkpoint_read_call=$(awk '/rollback-target-digest/ { checkpoint=1; next } checkpoint && / get statefulset agent-os-firstmate -o json/ { print; exit }' "$CALLS")
assert_contains "$checkpoint_read_call" '--request-timeout=' \
  "rollback checkpoint persistence read-back must be request-bounded"
grep -F 'kubectl --context kind-agent-os -n portable-agent-os patch StatefulSet agent-os-firstmate --type=strategic' "$CALLS" >/dev/null || \
  fail "generic rollback must update only the captured Firstmate StatefulSet"
assert_grep '"uid":"uid-statefulset"' "$CALLS" \
  "rollback mutation must carry StatefulSet UID CAS"
assert_grep '"resourceVersion":"rv-statefulset"' "$CALLS" \
  "rollback mutation must carry StatefulSet resourceVersion CAS"
assert_grep '"rollback":"previous"' "$CALLS" \
  "rollback must return a failed updateRevision to the exact-owned currentRevision"
assert_no_grep 'rollout undo' "$CALLS" \
  "rollback must not use a non-CAS rollout undo mutation"
grep -Fq 'akua render --no-agent-mode' "$CALLS" || \
  fail "rollback must derive its namespace and identity from the current package render"
assert_grep 'get controllerrevisions.apps -o json' "$CALLS" \
  "rollback must resolve the exact-owned revision history"
pass "generic rollback applies a revision-derived StatefulSet CAS update"

: > "$CALLS"
rollback_rules_out=''
rollback_rules_rc=0
rollback_rules_out=$(AGENT_OS_TEST_NAMESPACE_STATE=owned AGENT_OS_TEST_RESOURCE_STATE=owned \
  AGENT_OS_TEST_WORKLOAD_STATE=namespace AGENT_OS_TEST_RBAC_STATE=bad-rules \
  run_generic rollback 2>&1) || rollback_rules_rc=$?
[ "$rollback_rules_rc" -eq 3 ] || fail "rollback must reject drifted runtime Role rules: $rollback_rules_out"
assert_no_grep '"rollback":"previous"' "$CALLS" \
  "drifted runtime Role rules must block rollback template mutation"
pass "rollback verifies exact runtime and control Role rules"

: > "$CALLS"
rollback_control_rules_out=''
rollback_control_rules_rc=0
rollback_control_rules_out=$(AGENT_OS_TEST_NAMESPACE_STATE=owned AGENT_OS_TEST_RESOURCE_STATE=owned \
  AGENT_OS_TEST_WORKLOAD_STATE=namespace AGENT_OS_TEST_CONTROL_RBAC_STATE=bad-rules \
  run_generic rollback 2>&1) || rollback_control_rules_rc=$?
[ "$rollback_control_rules_rc" -eq 3 ] || fail "rollback must reject drifted control Role rules: $rollback_control_rules_out"
assert_no_grep '"rollback":"previous"' "$CALLS" \
  "drifted control Role rules must block rollback template mutation"
pass "rollback rejects drifted control Role rules"

: > "$CALLS"
checkpoint_read_race_out=''
checkpoint_read_race_rc=0
checkpoint_read_race_out=$(AGENT_OS_TEST_NAMESPACE_STATE=owned AGENT_OS_TEST_RESOURCE_STATE=owned \
  AGENT_OS_TEST_WORKLOAD_STATE=namespace AGENT_OS_TEST_ROLLBACK_CHECKPOINT_MUTATE_ON_READ=1 \
  run_generic rollback 2>&1) || checkpoint_read_race_rc=$?
[ "$checkpoint_read_race_rc" -eq 3 ] || fail "rollback must fail closed when checkpoint identity changes before template mutation: $checkpoint_read_race_out"
assert_no_grep 'patch StatefulSet agent-os-firstmate --type=strategic' "$CALLS" \
  "checkpoint identity change must prevent strategic template mutation"
assert_contains "$checkpoint_read_race_out" 'rollback checkpoint did not persist exactly' \
  "checkpoint persistence failure must preserve an explicit retained-state error"
pass "rollback checkpoint read-back verifies immutable identity"

previous_template_digest=$(printf '%s' '{"metadata":{"labels":{"rollback":"previous"}},"spec":{"serviceAccountName":"agent-os-firstmate"}}' | jq -cS . | shasum -a 256 | awk '{print $1}')
: > "$CALLS"
renumbered_out=''
renumbered_rc=0
renumbered_out=$(AGENT_OS_TEST_NAMESPACE_STATE=owned AGENT_OS_TEST_RESOURCE_STATE=owned \
  AGENT_OS_TEST_WORKLOAD_STATE=namespace AGENT_OS_TEST_PRIMARY_POD_STATE=owned \
  AGENT_OS_TEST_ROLLBACK_CURRENT=agent-os-firstmate-current \
  AGENT_OS_TEST_ROLLBACK_UPDATE=agent-os-firstmate-renumbered \
  AGENT_OS_TEST_ROLLBACK_RENUMBERED=1 \
  AGENT_OS_TEST_ROLLBACK_CHECKPOINT_DIGEST="$previous_template_digest" \
  AGENT_OS_TEST_FAIL_ROLLOUT=1 run_generic rollback 2>&1) || renumbered_rc=$?
[ "$renumbered_rc" -eq 3 ] || fail "renumbered rollback retry must remain incomplete: $renumbered_out"
assert_grep '"rollback":"current"' "$CALLS" \
  "rollback retry must compensate to its immutable checkpoint source template"
assert_contains "$renumbered_out" 'target-digest=' \
  "rollback retry must preserve the immutable checkpoint digest"
assert_contains "$renumbered_out" 'target=agent-os-firstmate-renumbered' \
  "rollback retry must adopt content-equivalent renumbered ControllerRevision"
assert_contains "$renumbered_out" 'checkpoint-target=agent-os-firstmate-previous checkpoint-uid=uid-revision-previous' \
  "rollback retry evidence must preserve the original immutable checkpoint identity"
pass "rollback retry adopts content-equivalent renumbered revisions"

: > "$CALLS"
verification_out=''
verification_rc=0
verification_out=$(AGENT_OS_TEST_NAMESPACE_STATE=owned AGENT_OS_TEST_RESOURCE_STATE=owned \
  AGENT_OS_TEST_WORKLOAD_STATE=namespace AGENT_OS_TEST_ROLLBACK_VERIFY_MISMATCH=1 \
  run_generic rollback 2>&1) || verification_rc=$?
[ "$verification_rc" -eq 3 ] || fail "rollback must fail closed when completed revisions do not match its checkpoint: $verification_out"
assert_contains "$verification_out" "rollback revision 'agent-os-firstmate-current' content differs" \
  "rollback must retain explicit evidence when another revision completes"
pass "rollback success verifies both revision targets by content"

: > "$CALLS"
checkpoint_mutation_out=''
checkpoint_mutation_rc=0
checkpoint_mutation_out=$(AGENT_OS_TEST_NAMESPACE_STATE=owned AGENT_OS_TEST_RESOURCE_STATE=owned \
  AGENT_OS_TEST_WORKLOAD_STATE=namespace AGENT_OS_TEST_ROLLBACK_CHECKPOINT_MUTATE=1 \
  run_generic rollback 2>&1) || checkpoint_mutation_rc=$?
[ "$checkpoint_mutation_rc" -eq 3 ] || fail "rollback must fail closed when checkpoint identity mutates: $checkpoint_mutation_out"
assert_contains "$checkpoint_mutation_out" 'rollback verification mismatch' \
  "rollback verification must require the complete immutable checkpoint tuple"
pass "rollback success preserves immutable checkpoint identity"

: > "$CALLS"
rollback_failure_out=''
rollback_failure_rc=0
rollback_failure_out=$(AGENT_OS_TEST_NAMESPACE_STATE=owned AGENT_OS_TEST_RESOURCE_STATE=owned \
  AGENT_OS_TEST_WORKLOAD_STATE=namespace AGENT_OS_TEST_PRIMARY_POD_STATE=owned \
  AGENT_OS_TEST_FAIL_ROLLOUT=1 run_generic rollback 2>&1) || rollback_failure_rc=$?
[ "$rollback_failure_rc" -eq 3 ] || fail "failed rollback rollout must exit incomplete: $rollback_failure_out"
assert_contains "$rollback_failure_out" 'rollback target=agent-os-firstmate-previous revision=1' \
  "rollback failure must preserve its selected revision"
assert_contains "$rollback_failure_out" 'current-revision=agent-os-firstmate-previous update-revision=agent-os-firstmate-current' \
  "rollback failure must report observed revision state"
assert_contains "$rollback_failure_out" 'Pod/agent-os-firstmate-0 uid=uid-pod' \
  "rollback failure must report Pod UID and readiness evidence"
assert_contains "$rollback_failure_out" 'lifecycle-lease=agent-os-firstmate-lifecycle uid=uid-primary-lock holder=operation-test' \
  "rollback failure must preserve exact lifecycle Lease evidence"
assert_contains "$rollback_failure_out" 'safe recovery:' \
  "rollback failure must print an exact non-reversing recovery command"
rollback_evidence_calls=$(awk '/rollout status statefulset\/agent-os-firstmate/ { after=1; next } after && / get (statefulset agent-os-firstmate -o json|Pod agent-os-firstmate-0 .*jsonpath=)/ { print }' "$CALLS")
if printf '%s\n' "$rollback_evidence_calls" | grep -v -- '--request-timeout=' >/dev/null; then
  fail "rollback failure evidence reads must each carry an independent request timeout: $rollback_evidence_calls"
fi
pass "failed rollback rollout preserves recovery evidence"

: > "$CALLS"
rollback_resume_out=''
rollback_resume_rc=0
rollback_resume_out=$(AGENT_OS_TEST_NAMESPACE_STATE=owned AGENT_OS_TEST_RESOURCE_STATE=owned \
  AGENT_OS_TEST_WORKLOAD_STATE=namespace AGENT_OS_TEST_PRIMARY_POD_STATE=owned \
  AGENT_OS_TEST_ROLLBACK_CURRENT=agent-os-firstmate-current \
  AGENT_OS_TEST_ROLLBACK_UPDATE=agent-os-firstmate-previous \
  AGENT_OS_TEST_ROLLBACK_CHECKPOINT_DIGEST="$previous_template_digest" \
  AGENT_OS_TEST_FAIL_ROLLOUT=1 run_generic rollback 2>&1) || rollback_resume_rc=$?
[ "$rollback_resume_rc" -eq 3 ] || fail "in-progress rollback retry must remain incomplete: $rollback_resume_out"
assert_no_grep 'patch StatefulSet agent-os-firstmate' "$CALLS" \
  "in-progress rollback retry must not reverse the selected target"
assert_contains "$rollback_resume_out" 'rollback target=agent-os-firstmate-previous revision=1' \
  "in-progress rollback retry must preserve the lower selected revision"
assert_contains "$rollback_resume_out" "persisted target digest remains" \
  "in-progress rollback retry must provide non-reversing recovery guidance"
pass "rollback retry resumes an existing lower-revision target"

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
AGENT_OS_TEST_NAMESPACE_STATE=owned AGENT_OS_TEST_WORKLOAD_STATE=namespace \
  AGENT_OS_TEST_RESOURCE_STATE=owned run_generic uninstall --yes
if grep -E 'kubectl .* (get|delete) clusterrolebinding' "$CALLS" >/dev/null; then
  fail "routine namespace uninstall must never request cluster-wide RBAC authority"
fi
if grep -F 'delete namespace portable-agent-os' "$CALLS" >/dev/null; then
  fail "bounded uninstall must retain its namespace by default"
fi
grep -F '/rolebindings/agent-os-firstmate-runtime' "$CALLS" | grep -F 'delete --raw' >/dev/null || \
  fail "uninstall must remove namespace runtime binding regardless of current inputs"
grep -F '/roles/agent-os-firstmate-runtime' "$CALLS" | grep -F 'delete --raw' >/dev/null || \
  fail "uninstall must remove namespace runtime Role regardless of current inputs"
stateful_delete_line=$(grep -Fn '/statefulsets/agent-os-firstmate' "$CALLS" | grep 'delete --raw' | head -n 1 | cut -d: -f1)
pvc_delete_line=$(grep -Fn '/persistentvolumeclaims/agent-os-firstmate-home' "$CALLS" | grep 'delete --raw' | head -n 1 | cut -d: -f1)
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
  AGENT_OS_TEST_PRIMARY_POD_STATE=owned AGENT_OS_TEST_FAIL_DELETE_TARGET=persistentvolumeclaims/agent-os-firstmate-home \
  AGENT_OS_TEST_DELETE_ERROR='Error from server (Forbidden): persistentvolumeclaims is forbidden' \
  AGENT_OS_OPERATION_ID=operation-test AGENT_OS_CONTEXT=kind-agent-os \
  AGENT_OS_NAMESPACE=portable-agent-os "$GENERIC" uninstall --yes 2>&1) || bounded_rc=$?
[ "$bounded_rc" -eq 3 ] || fail "timed-out uninstall must exit incomplete: $bounded_out"
assert_contains "$bounded_out" 'delete-request-failure=Forbidden' \
  "immediate deletion authorization failures must not be mislabeled as timeouts"
assert_contains "$bounded_out" 'timeout=180s' \
  "deletion evidence must report the configured operation timeout"
assert_contains "$bounded_out" 'uid=uid-persistentvolumeclaim' \
  "deletion evidence must report the captured target UID"
assert_not_contains "$bounded_out" 'timed out deleting PersistentVolumeClaim/agent-os-firstmate-home' \
  "immediate deletion failures must remain distinct from timeout evidence"
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
grep -F '/persistentvolumeclaims/agent-os-firstmate-home' "$CALLS" | grep -F 'delete --raw' >/dev/null || \
  fail "uninstall deletion must target the captured PVC identity"
pass "uninstall delete-request failures preserve class and retained evidence"

: > "$CALLS"
timeout_out=''
timeout_rc=0
timeout_out=$(PATH="$FAKEBIN:$PATH" AGENT_OS_TEST_LOG="$CALLS" AGENT_OS_INPUTS="$NONE_INPUTS" \
  AGENT_OS_TEST_NAMESPACE=portable-agent-os AGENT_OS_TEST_NAMESPACE_STATE=owned \
  AGENT_OS_TEST_WORKLOAD_STATE=none AGENT_OS_TEST_RESOURCE_STATE=owned \
  AGENT_OS_TEST_FAIL_WAIT_TARGET=StatefulSet/agent-os-firstmate \
  AGENT_OS_OPERATION_ID=operation-test AGENT_OS_CONTEXT=kind-agent-os \
  AGENT_OS_NAMESPACE=portable-agent-os "$GENERIC" uninstall --yes 2>&1) || timeout_rc=$?
[ "$timeout_rc" -eq 3 ] || fail "true deletion timeout must exit incomplete rc=$timeout_rc: $timeout_out"
assert_contains "$timeout_out" 'delete-wait-failure=timeout' \
  "wait timeout evidence must preserve its failure class"
assert_contains "$timeout_out" 'timeout=180s' \
  "wait timeout evidence must report the actual configured timeout"
assert_contains "$timeout_out" 'uid=uid-statefulset' \
  "wait timeout evidence must report the captured target UID"
pass "uninstall wait timeouts report actual bounds and retained state"

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
grep -F '/apis/rbac.authorization.k8s.io/v1/namespaces/kube-system/rolebindings/agent-os-lifecycle-' "$CALLS" | \
  grep -F 'delete --raw' >/dev/null || fail "cluster-admin uninstall must delete exact-owned control RoleBinding authority"
grep -F '/apis/rbac.authorization.k8s.io/v1/namespaces/kube-system/roles/agent-os-lifecycle-' "$CALLS" | \
  grep -F 'delete --raw' >/dev/null || fail "cluster-admin uninstall must delete exact-owned control Role authority"
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
retry_service_account=agent-os-firstmate-cccccccccccc
retry_sa_out=''
retry_sa_rc=0
retry_sa_out=$(AGENT_OS_TEST_NAMESPACE_STATE=owned AGENT_OS_TEST_WORKLOAD_STATE=absent \
  AGENT_OS_TEST_RESOURCE_STATE=absent AGENT_OS_TEST_RESIDUAL_SERVICE_ACCOUNT="$retry_service_account" \
  run_generic uninstall --yes 2>&1) || retry_sa_rc=$?
[ "$retry_sa_rc" -eq 3 ] || fail "history-free uninstall retry must retain cluster cleanup status: $retry_sa_out"
assert_grep "/serviceaccounts/$retry_service_account" "$CALLS" \
  "uninstall retry must independently recover and delete exact-owned historical ServiceAccounts"
pass "uninstall retry recovers historical ServiceAccounts independently"

: > "$CALLS"
AGENT_OS_TEST_NAMESPACE_STATE=owned AGENT_OS_TEST_WORKLOAD_STATE=namespace \
  run_generic uninstall --yes --delete-namespace
grep -F '/api/v1/namespaces/portable-agent-os' "$CALLS" | grep -F 'delete --raw' >/dev/null || \
  fail "optional namespace deletion must UID-delete only the exactly owned namespace"
assert_grep '"uid":"uid-namespace","resourceVersion":"rv-namespace"' "$STDIN_LOG" \
  "namespace deletion must bind to the final observed namespace identity"
grep -Fq 'kubectl --context kind-agent-os api-resources --verbs=list --namespaced -o name' "$CALLS" || \
  fail "optional namespace deletion must inventory every listable namespaced resource type"
namespace_lock_line=$(grep -Fn 'get lease agent-os-firstmate-lifecycle' "$CALLS" | head -n 1 | cut -d: -f1)
namespace_inventory_line=$(grep -Fn 'api-resources --verbs=list --namespaced -o name' "$CALLS" | head -n 1 | cut -d: -f1)
[ -n "$namespace_lock_line" ] && [ -n "$namespace_inventory_line" ] && \
  [ "$namespace_lock_line" -lt "$namespace_inventory_line" ] || \
  fail "namespace deletion must inventory only after holding the installation-wide barrier"
awk '
  /namespaces\/kube-system\/rolebindings\/agent-os-lifecycle-/ && /delete --raw/ && !control { control=NR }
  /\/api\/v1\/namespaces\/portable-agent-os -f -/ && /delete --raw/ && !namespace { namespace=NR }
  END { exit !(control && namespace && control < namespace) }
' "$CALLS" || fail "uninstall must delete and verify control RBAC before namespace finalization: $(grep -E 'rolebindings/agent-os-lifecycle-|/api/v1/namespaces/portable-agent-os' "$CALLS" | tr '\n' ';')"
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
