#!/usr/bin/env bash
# agent-os-crewmate.sh - operate one isolated crewmate Pod and persistent home.
# Usage: bin/agent-os-crewmate.sh create|status|stop|restart|purge|delete <crewmate-id> [--yes]
set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
COMMAND=${1:-}
ID=${2:-}
CONFIRM=${3:-}
NAMESPACE=${AGENT_OS_NAMESPACE:-agent-os}
IMAGE=${AGENT_OS_IMAGE:-}
IMAGE_PULL_POLICY=${AGENT_OS_IMAGE_PULL_POLICY:-IfNotPresent}
AI_SECRET=${AGENT_OS_AI_SECRET:-}
KUBECTL=${AGENT_OS_KUBECTL:-kubectl}
TEMPLATE=${AGENT_OS_CREWMATE_TEMPLATE:-"$ROOT/tools/agent-os/packages/firstmate/crewmate.yaml"}
INSTALLATION_ID="agent-os-firstmate:$NAMESPACE"
OPERATION_ID=${AGENT_OS_OPERATION_ID:-"$(date -u '+%Y%m%d%H%M%S')-$$-$RANDOM"}
LOCK_NONCE=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
LOCK_HOLDER_ID="$OPERATION_ID.$LOCK_NONCE"
CONTROL_LOCK_UID=
CONTROL_LOCK_RV=
CONTROL_LOCK_RENEW_PID=
CONTROL_LOCK_VALID_UNTIL=

[ -f "$TEMPLATE" ] || { echo "error: crewmate template is unavailable in canonical source" >&2; exit 2; }

case "$ID" in
  ''|*[!a-z0-9-]*|-*|*-) echo "error: invalid crewmate id '$ID'" >&2; exit 2 ;;
esac
case "$OPERATION_ID" in
  ''|*[!a-z0-9.-]*|[.-]*|*[-.]) echo "error: invalid operation id" >&2; exit 2 ;;
esac
[ "${#OPERATION_ID}" -le 63 ] || { echo "error: invalid operation id" >&2; exit 2; }

KUBECTL_ARGS=()
if [ -n "${AGENT_OS_CONTEXT:-}" ]; then
  KUBECTL_ARGS=(--context "$AGENT_OS_CONTEXT")
elif [ "${AGENT_OS_IN_CLUSTER:-0}" != 1 ] && [ ! -f /var/run/secrets/kubernetes.io/serviceaccount/token ]; then
  echo "error: set AGENT_OS_CONTEXT outside Kubernetes; ambient contexts are refused" >&2
  exit 2
fi

POD="agent-os-crewmate-$ID"
PVC="$POD-home"
LOCK="$POD-lifecycle"
[ "${#ID}" -le 63 ] || { echo "error: invalid crewmate id '$ID'" >&2; exit 2; }
for derived_name in "$POD" "$PVC" "$LOCK"; do
  [ "${#derived_name}" -le 63 ] || { echo "error: crewmate id '$ID' makes Kubernetes resource names too long" >&2; exit 2; }
done
LOCK_NAMESPACE=$NAMESPACE
LOCK_SCOPE=crewmate
EXPECTED_POD="$POD"$'\t'"agent-os"$'\t'"$ID"$'\t'"$INSTALLATION_ID"
EXPECTED_PVC="$PVC"$'\t'"agent-os"$'\t'"$ID"$'\t'"$INSTALLATION_ID"
EXPECTED_LOCK="$LOCK"$'\t'"agent-os"$'\t'"$ID"$'\t'"$INSTALLATION_ID"
LOCK_UID=
LOCK_RV=
LOCK_RENEW_PID=
LOCK_PERSISTENT=0
LOCK_DURATION_SECONDS=${AGENT_OS_LOCK_DURATION_SECONDS:-300}
LOCK_CLOCK_SKEW_SECONDS=${AGENT_OS_LOCK_CLOCK_SKEW_SECONDS:-5}
LOCK_ACQUIRE_SECONDS=${AGENT_OS_LOCK_ACQUIRE_SECONDS:-30}
LOCK_REQUEST_CEILING_SECONDS=${AGENT_OS_LOCK_REQUEST_CEILING_SECONDS:-5}
RESOURCE_REQUEST_CEILING_SECONDS=${AGENT_OS_RESOURCE_REQUEST_CEILING_SECONDS:-5}
DELETE_OUTCOME=
DELETE_CAPTURED_UID=
DELETE_OBSERVED_UID=

for seconds in "$LOCK_DURATION_SECONDS" "$LOCK_CLOCK_SKEW_SECONDS" "$LOCK_ACQUIRE_SECONDS" "$LOCK_REQUEST_CEILING_SECONDS" "$RESOURCE_REQUEST_CEILING_SECONDS"; do
  case "$seconds" in ''|*[!0-9]*) echo "error: lifecycle Lease timing must use whole seconds" >&2; exit 2 ;; esac
done
[ "$LOCK_DURATION_SECONDS" -ge 3 ] || { echo "error: lifecycle Lease duration must be at least 3 seconds" >&2; exit 2; }
[ "$LOCK_ACQUIRE_SECONDS" -ge 1 ] || { echo "error: lifecycle Lease acquisition must allow at least 1 second" >&2; exit 2; }
[ "$LOCK_REQUEST_CEILING_SECONDS" -ge 1 ] || { echo "error: lifecycle Lease request ceiling must be at least 1 second" >&2; exit 2; }
[ "$RESOURCE_REQUEST_CEILING_SECONDS" -ge 1 ] || { echo "error: resource request ceiling must be at least 1 second" >&2; exit 2; }

kube() {
  "$KUBECTL" "${KUBECTL_ARGS[@]}" -n "$LOCK_NAMESPACE" "$@"
}

resource_identity() {
  local kind=$1 name=$2
  kube get "$kind" "$name" --ignore-not-found \
    -o 'jsonpath={.metadata.name}{"\t"}{.metadata.labels.app\.kubernetes\.io/managed-by}{"\t"}{.metadata.labels.agent-os\.dev/crewmate}{"\t"}{.metadata.annotations.agent-os\.dev/installation-id}'
}

pod_record() {
  local deadline=${1:-} request_args=()
  if [ -n "$deadline" ]; then
    request_seconds=$(resource_request_seconds "$deadline") || return 124
    request_args=(--request-timeout="${request_seconds}s")
  fi
  kube "${request_args[@]}" get pod "$POD" --ignore-not-found \
    -o 'jsonpath={.metadata.name}{"\t"}{.metadata.labels.app\.kubernetes\.io/managed-by}{"\t"}{.metadata.labels.agent-os\.dev/crewmate}{"\t"}{.metadata.annotations.agent-os\.dev/installation-id}{"\t"}{.metadata.labels.agent-os\.dev/operation-id}{"\t"}{.metadata.uid}{"\t"}{.metadata.resourceVersion}{"\t"}{range .spec.volumes[?(@.name=="home")]}{.persistentVolumeClaim.claimName}{end}'
}

pvc_record() {
  local deadline=${1:-} request_args=()
  if [ -n "$deadline" ]; then
    request_seconds=$(resource_request_seconds "$deadline") || return 124
    request_args=(--request-timeout="${request_seconds}s")
  fi
  kube "${request_args[@]}" get pvc "$PVC" --ignore-not-found \
    -o 'jsonpath={.metadata.name}{"\t"}{.metadata.labels.app\.kubernetes\.io/managed-by}{"\t"}{.metadata.labels.agent-os\.dev/crewmate}{"\t"}{.metadata.annotations.agent-os\.dev/installation-id}{"\t"}{.metadata.annotations.agent-os\.dev/checkpoint-state}{"\t"}{.metadata.annotations.agent-os\.dev/checkpoint-at}{"\t"}{.metadata.annotations.agent-os\.dev/quiesced-operation}{"\t"}{.metadata.annotations.agent-os\.dev/checkpoint-operation}{"\t"}{.metadata.uid}{"\t"}{.metadata.resourceVersion}'
}

lock_record() {
  local deadline=${1:-}
  [ -n "$deadline" ] || deadline=$(lock_default_deadline)
  if [ "$LOCK_SCOPE" != crewmate ]; then
    lock_kube "$deadline" get lease "$LOCK" --ignore-not-found \
      -o 'jsonpath={.metadata.name}{"\t"}{.metadata.labels.app\.kubernetes\.io/managed-by}{"\t"}{.metadata.labels.agent-os\.dev/lifecycle}{"\t"}{.metadata.annotations.agent-os\.dev/installation-id}{"\t"}{.spec.holderIdentity}{"\t"}{.spec.acquireTime}{"\t"}{.spec.renewTime}{"\t"}{.spec.leaseDurationSeconds}{"\t"}{.metadata.uid}{"\t"}{.metadata.resourceVersion}'
    return
  fi
  lock_kube "$deadline" get lease "$LOCK" --ignore-not-found \
    -o 'jsonpath={.metadata.name}{"\t"}{.metadata.labels.app\.kubernetes\.io/managed-by}{"\t"}{.metadata.labels.agent-os\.dev/crewmate}{"\t"}{.metadata.annotations.agent-os\.dev/installation-id}{"\t"}{.spec.holderIdentity}{"\t"}{.spec.acquireTime}{"\t"}{.spec.renewTime}{"\t"}{.spec.leaseDurationSeconds}{"\t"}{.metadata.uid}{"\t"}{.metadata.resourceVersion}'
}

require_owned_or_absent() {
  local kind=$1 name=$2 expected=$3 identity
  identity=$(resource_identity "$kind" "$name")
  if [ -n "$identity" ] && [ "$identity" != "$expected" ]; then
    echo "error: $kind '$name' does not have the exact crewmate installation identity" >&2
    exit 2
  fi
  printf '%s' "$identity"
}

require_owned_pvc_or_absent() {
  local record identity
  record=$(pvc_record)
  identity=$(printf '%s' "$record" | cut -f1-4)
  if [ -n "$record" ] && [ "$identity" != "$EXPECTED_PVC" ]; then
    echo "error: pvc '$PVC' does not have the exact crewmate installation identity" >&2
    exit 2
  fi
  printf '%s' "$record"
}

validate_ai_grant() {
  if [ -z "$IMAGE" ]; then
    echo "error: AGENT_OS_IMAGE must name the immutable image selected for this cluster" >&2
    exit 2
  fi
  case "$AI_SECRET" in
    ''|*[!a-z0-9.-]*|[.-]*|*[-.])
      echo "error: AGENT_OS_AI_SECRET must name an explicitly authorized namespace-local Secret" >&2
      exit 2
      ;;
  esac
  if [ "${#AI_SECRET}" -gt 253 ]; then
    echo "error: AGENT_OS_AI_SECRET must be a valid Kubernetes Secret name" >&2
    exit 2
  fi
}

render_resources() {
  sed \
    -e "s|__AGENT_OS_CREWMATE_ID__|$ID|g" \
    -e "s|__AGENT_OS_NAMESPACE__|$NAMESPACE|g" \
    -e "s|__AGENT_OS_IMAGE__|$IMAGE|g" \
    -e "s|__AGENT_OS_IMAGE_PULL_POLICY__|$IMAGE_PULL_POLICY|g" \
    -e "s|__AGENT_OS_AI_SECRET__|$AI_SECRET|g" \
    -e "s|__AGENT_OS_OPERATION_ID__|$OPERATION_ID|g" \
    "$TEMPLATE"
}

render_pvc() {
  render_resources | awk '/^---$/ { exit } { print }'
}

render_pod() {
  render_resources | awk 'found { print } /^---$/ { found=1 }'
}

render_lock() {
  local acquired_at=$1 renewed_at=$2 uid=${3:-} rv=${4:-} uid_value='' rv_value=''
  [ -z "$uid" ] || uid_value=$(yaml_string "$uid")
  [ -z "$rv" ] || rv_value=$(yaml_string "$rv")
  if [ "$LOCK_SCOPE" != crewmate ]; then
    cat <<YAML
apiVersion: coordination.k8s.io/v1
kind: Lease
metadata:
  name: $LOCK
  namespace: $LOCK_NAMESPACE
${uid:+  uid: $uid_value}
${rv:+  resourceVersion: $rv_value}
  labels:
    app.kubernetes.io/managed-by: agent-os
    agent-os.dev/lifecycle: primary
  annotations:
    agent-os.dev/installation-id: ${LOCK_INSTALLATION_ID:-$INSTALLATION_ID}
spec:
  holderIdentity: $LOCK_HOLDER_ID
  acquireTime: $acquired_at
  renewTime: $renewed_at
  leaseDurationSeconds: $LOCK_DURATION_SECONDS
YAML
    return
  fi
  cat <<YAML
apiVersion: coordination.k8s.io/v1
kind: Lease
metadata:
  name: $LOCK
  namespace: $LOCK_NAMESPACE
${uid:+  uid: $uid_value}
${rv:+  resourceVersion: $rv_value}
  labels:
    app.kubernetes.io/managed-by: agent-os
    agent-os.dev/crewmate: $ID
  annotations:
    agent-os.dev/installation-id: $INSTALLATION_ID
spec:
  holderIdentity: $LOCK_HOLDER_ID
  acquireTime: $acquired_at
  renewTime: $renewed_at
  leaseDurationSeconds: $LOCK_DURATION_SECONDS
YAML
}

. "$ROOT/bin/agent-os-kubernetes-control.sh"
. "$ROOT/bin/agent-os-kubernetes-lease.sh"

acquire_lifecycle_locks() {
  CREWMATE_LOCK=$LOCK
  CREWMATE_EXPECTED_LOCK=$EXPECTED_LOCK
  configure_control_lock
  LOCK=$CONTROL_LOCK
  LOCK_NAMESPACE=$CONTROL_NAMESPACE
  EXPECTED_LOCK="$LOCK"$'\t'"agent-os"$'\t'"primary"$'\t'"$CONTROL_LOCK_INSTALLATION_ID"
  LOCK_SCOPE=control
  LOCK_PERSISTENT=1
  acquire_lock
  CONTROL_LOCK_UID=$LOCK_UID
  CONTROL_LOCK_RV=$LOCK_RV
  CONTROL_LOCK_RENEW_PID=$LOCK_RENEW_PID
  CONTROL_LOCK_VALID_UNTIL=$LOCK_VALID_UNTIL
  LOCK=agent-os-firstmate-lifecycle
  LOCK_NAMESPACE=$NAMESPACE
  EXPECTED_LOCK="$LOCK"$'\t'"agent-os"$'\t'"primary"$'\t'"$INSTALLATION_ID"
  LOCK_SCOPE=fleet
  LOCK_PERSISTENT=0
  acquire_lock
  FLEET_LOCK_UID=$LOCK_UID
  FLEET_LOCK_RV=$LOCK_RV
  FLEET_LOCK_RENEW_PID=$LOCK_RENEW_PID
  FLEET_LOCK_VALID_UNTIL=$LOCK_VALID_UNTIL
  LOCK=$CREWMATE_LOCK
  EXPECTED_LOCK=$CREWMATE_EXPECTED_LOCK
  LOCK_SCOPE=crewmate
  LOCK_PERSISTENT=0
  LOCK_UID=
  LOCK_RV=
  LOCK_RENEW_PID=
  LOCK_VALID_UNTIL=
  acquire_lock
}

release_lifecycle_locks() {
  local status=0
  release_lock || status=$?
  LOCK=agent-os-firstmate-lifecycle
  EXPECTED_LOCK="$LOCK"$'\t'"agent-os"$'\t'"primary"$'\t'"$INSTALLATION_ID"
  LOCK_SCOPE=fleet
  LOCK_PERSISTENT=0
  LOCK_UID=${FLEET_LOCK_UID:-}
  LOCK_RV=${FLEET_LOCK_RV:-}
  LOCK_RENEW_PID=${FLEET_LOCK_RENEW_PID:-}
  LOCK_VALID_UNTIL=${FLEET_LOCK_VALID_UNTIL:-}
  release_lock || status=$?
  if [ -n "${CONTROL_LOCK_UID:-}" ]; then
    LOCK=$CONTROL_LOCK
    LOCK_NAMESPACE=$CONTROL_NAMESPACE
    EXPECTED_LOCK="$LOCK"$'\t'"agent-os"$'\t'"primary"$'\t'"$CONTROL_LOCK_INSTALLATION_ID"
    LOCK_SCOPE=control
    LOCK_PERSISTENT=1
    LOCK_UID=$CONTROL_LOCK_UID
    LOCK_RV=${CONTROL_LOCK_RV:-}
    LOCK_RENEW_PID=${CONTROL_LOCK_RENEW_PID:-}
    LOCK_VALID_UNTIL=${CONTROL_LOCK_VALID_UNTIL:-}
    release_lock || status=$?
  fi
  return "$status"
}

finish_lifecycle() {
  local status=$?
  trap - EXIT
  if ! release_lifecycle_locks && [ "$status" -eq 0 ]; then
    status=3
  fi
  exit "$status"
}

trap finish_lifecycle EXIT
trap lock_renewal_failed TERM

resource_request_seconds() {
  local deadline=$1 remaining seconds
  remaining=$((deadline - $(date -u '+%s')))
  [ "$remaining" -gt 0 ] || return 1
  seconds=$RESOURCE_REQUEST_CEILING_SECONDS
  [ "$seconds" -le "$remaining" ] || seconds=$remaining
  [ "$seconds" -gt 0 ] || return 1
  printf '%s' "$seconds"
}

resource_mutation_seconds() {
  local deadline=$1 remaining seconds
  remaining=$((deadline - $(date -u '+%s') - 1))
  [ "$remaining" -gt 0 ] || return 1
  seconds=$RESOURCE_REQUEST_CEILING_SECONDS
  [ "$seconds" -le "$remaining" ] || seconds=$remaining
  [ "$seconds" -gt 0 ] || return 1
  printf '%s' "$seconds"
}

resource_wait_seconds() {
  local deadline=$1 remaining reserve
  remaining=$((deadline - $(date -u '+%s')))
  [ "$remaining" -gt 1 ] || return 1
  reserve=$RESOURCE_REQUEST_CEILING_SECONDS
  [ "$reserve" -lt "$remaining" ] || reserve=$((remaining - 1))
  printf '%s' "$((remaining - reserve))"
}

delete_owned_crewmate_resource() {
  local kind=$1 name=$2 expected_uid=${3:-} expected_rv=${4:-} expected_operation=${5:-}
  local started deadline record identity uid rv path request_seconds current current_uid wait_seconds delete_ok=0
  started=$(date -u '+%s')
  deadline=$((started + 180))
  DELETE_OUTCOME=unknown
  DELETE_CAPTURED_UID=$expected_uid
  DELETE_OBSERVED_UID=unavailable
  case "$kind" in
    pod) record=$(pod_record "$deadline") || { echo "error: pod/$name observation unavailable before bounded deletion captured uid=${expected_uid:-unknown}" >&2; return 3; } ;;
    pvc) record=$(pvc_record "$deadline") || { echo "error: pvc/$name observation unavailable before bounded deletion captured uid=${expected_uid:-unknown}" >&2; return 3; } ;;
    *) return 2 ;;
  esac
  if [ -z "$record" ]; then
    DELETE_OUTCOME=absent
    DELETE_OBSERVED_UID=absent
    echo "confirmed absent: $kind/$name captured uid=${expected_uid:-absent}" >&2
    return 0
  fi
  identity=$(printf '%s' "$record" | cut -f1-4)
  if { [ "$kind" = pod ] && [ "$identity" != "$EXPECTED_POD" ]; } || \
    { [ "$kind" = pvc ] && [ "$identity" != "$EXPECTED_PVC" ]; }; then
    echo "error: $kind/$name ownership changed before deletion; retained" >&2
    return 2
  fi
  if [ "$kind" = pod ]; then
    [ -z "$expected_operation" ] || [ "$(printf '%s' "$record" | cut -f5)" = "$expected_operation" ] || {
      echo "error: pod/$name replacement or ownership mismatch retained; operation identity changed before deletion" >&2
      return 3
    }
    uid=$(printf '%s' "$record" | cut -f6)
    rv=$(printf '%s' "$record" | cut -f7)
    path="/api/v1/namespaces/$NAMESPACE/pods/$name"
  else
    uid=$(printf '%s' "$record" | cut -f9)
    rv=$(printf '%s' "$record" | cut -f10)
    path="/api/v1/namespaces/$NAMESPACE/persistentvolumeclaims/$name"
  fi
  DELETE_CAPTURED_UID=$uid
  [ -n "$uid" ] && [ -n "$rv" ] || { echo "error: $kind/$name lacks deletion preconditions" >&2; return 2; }
  if [ -n "$expected_uid" ] && [ "$uid" != "$expected_uid" ]; then
    DELETE_OUTCOME=replacement-retained
    DELETE_CAPTURED_UID=$expected_uid
    DELETE_OBSERVED_UID=$uid
    echo "error: $kind/$name replacement uid=$uid retained; captured uid=$expected_uid" >&2
    return 3
  fi
  [ -z "$expected_rv" ] || [ "$rv" = "$expected_rv" ] || {
    DELETE_OUTCOME=original-retained
    DELETE_OBSERVED_UID=$uid
    echo "error: $kind/$name resourceVersion changed before deletion; retained" >&2
    return 3
  }
  request_seconds=$(resource_mutation_seconds "$deadline") || {
    echo "error: $kind/$name deletion deadline left no reconciliation reserve; retained uid=$uid" >&2
    return 3
  }
  if printf '{"apiVersion":"v1","kind":"DeleteOptions","preconditions":{"uid":"%s","resourceVersion":"%s"}}\n' "$uid" "$rv" | \
    kube --request-timeout="${request_seconds}s" delete --raw "$path" -f - >/dev/null; then
    delete_ok=1
  fi
  if [ "$delete_ok" -eq 1 ]; then
    wait_seconds=$(resource_wait_seconds "$deadline") || wait_seconds=0
    if [ "$wait_seconds" -gt 0 ]; then
      kube --request-timeout="${wait_seconds}s" wait --for=delete "$kind/$name" --timeout="${wait_seconds}s" >/dev/null 2>&1 || true
    fi
  fi
  case "$kind" in
    pod) current=$(pod_record "$deadline") || { echo "error: pod/$name deletion result unavailable; captured uid=$uid retained-state=unknown" >&2; return 3; } ;;
    pvc) current=$(pvc_record "$deadline") || { echo "error: pvc/$name deletion result unavailable; captured uid=$uid retained-state=unknown" >&2; return 3; } ;;
  esac
  if [ -z "$current" ]; then
    DELETE_OUTCOME=absent
    DELETE_OBSERVED_UID=absent
    echo "confirmed absent: $kind/$name captured uid=$uid" >&2
    return 0
  fi
  if [ "$kind" = pod ]; then
    current_uid=$(printf '%s' "$current" | cut -f6)
  else
    current_uid=$(printf '%s' "$current" | cut -f9)
  fi
  DELETE_OBSERVED_UID=$current_uid
  if [ "$current_uid" != "$uid" ]; then
    DELETE_OUTCOME=replacement-retained
    echo "error: $kind/$name replacement uid=$current_uid retained; captured uid=$uid" >&2
    return 3
  fi
  DELETE_OUTCOME=original-retained
  echo "error: $kind/$name original uid=$uid remains after bounded deletion; retained" >&2
  return 3
}

cleanup_new_owned_pod() {
  local expected_uid=${1:-}
  echo "partial state: reconciling newly created owned Pod '$POD' uid=${expected_uid:-observed}; persistent home retained" >&2
  delete_owned_crewmate_resource pod "$POD" "$expected_uid" '' "$OPERATION_ID" || true
}

create_and_wait() {
  local pvc_before pvc_current pvc_identity pvc_uid pvc_current_uid pvc_rv pod pod_current pod_uid pod_rv pod_claim
  pvc_before=$(require_owned_pvc_or_absent)
  if [ -z "$pvc_before" ]; then
    if ! render_pvc | kube create -f - >/dev/null; then
      echo "error: create-only PVC operation conflicted; no resource was adopted" >&2
      exit 2
    fi
    pvc_before=$(require_owned_pvc_or_absent)
  fi
  pvc_current=$(require_owned_pvc_or_absent)
  if [ -z "$pvc_before" ] || [ -z "$pvc_current" ]; then
    echo "error: PVC identity disappeared before Pod creation" >&2
    exit 2
  fi
  pvc_uid=$(printf '%s' "$pvc_before" | cut -f9)
  pvc_rv=$(printf '%s' "$pvc_before" | cut -f10)
  if [ -z "$pvc_uid" ] || [ -z "$pvc_rv" ]; then
    echo "error: Pod creation requires exact PVC UID and resourceVersion evidence" >&2
    exit 2
  fi
  if [ "$(printf '%s' "$pvc_current" | cut -f9)" != "$pvc_uid" ]; then
    echo "error: PVC UID changed before Pod creation" >&2
    exit 2
  fi
  invalidate_checkpoint_evidence
  pvc_current=$(require_owned_pvc_or_absent)
  if [ -z "$pvc_current" ] || [ "$(printf '%s' "$pvc_current" | cut -f9)" != "$pvc_uid" ]; then
    echo "error: PVC UID changed while activating the writer" >&2
    exit 2
  fi
  if ! render_pod | kube create -f - >/dev/null; then
    cleanup_new_owned_pod
    echo "error: create-only Pod operation conflicted or was only partially acknowledged" >&2
    exit 1
  fi
  pod=$(pod_record)
  if [ "$(printf '%s' "$pod" | cut -f1-4)" != "$EXPECTED_POD" ] || \
    [ "$(printf '%s' "$pod" | cut -f5)" != "$OPERATION_ID" ]; then
    echo "error: created Pod did not retain the exact operation identity; no cleanup attempted" >&2
    exit 1
  fi
  pod_uid=$(printf '%s' "$pod" | cut -f6)
  pod_rv=$(printf '%s' "$pod" | cut -f7)
  pod_claim=$(printf '%s' "$pod" | cut -f8)
  if [ -z "$pod_uid" ] || [ -z "$pod_rv" ] || [ "$pod_claim" != "$PVC" ]; then
    echo "error: created Pod lacks exact UID, resourceVersion, or PVC relationship evidence" >&2
    exit 1
  fi
  pvc_current=$(require_owned_pvc_or_absent)
  if [ -z "$pvc_current" ] || [ "$(printf '%s' "$pvc_current" | cut -f9)" != "$pvc_uid" ]; then
    cleanup_new_owned_pod "$pod_uid"
    echo "error: PVC UID changed after Pod creation; replacement claim retained" >&2
    exit 3
  fi
  if ! kube wait --for=condition=Ready "pod/$POD" --timeout=180s; then
    cleanup_new_owned_pod "$pod_uid"
    echo "error: crewmate Pod did not become ready with the authorized AI Secret" >&2
    exit 1
  fi
  pod_current=$(pod_record)
  if [ "$(printf '%s' "$pod_current" | cut -f1-5)" != "$EXPECTED_POD"$'\t'"$OPERATION_ID" ] || \
    [ "$(printf '%s' "$pod_current" | cut -f6)" != "$pod_uid" ] || \
    [ "$(printf '%s' "$pod_current" | cut -f8)" != "$PVC" ]; then
    pvc_current=$(pvc_record)
    pvc_identity=$(printf '%s' "$pvc_current" | cut -f1-4)
    if [ "$pvc_identity" = "$EXPECTED_PVC" ]; then
      if ! invalidate_checkpoint_evidence; then
        echo "partial state: checkpoint invalidation failed after Pod continuity loss; persistent claims retained" >&2
      fi
    fi
    echo "error: Pod identity changed after readiness; captured uid=$pod_uid observed uid=$(printf '%s' "$pod_current" | cut -f6); replacement retained and persistent claims retained" >&2
    exit 3
  fi
  pvc_current=$(pvc_record)
  pvc_identity=$(printf '%s' "$pvc_current" | cut -f1-4)
  pvc_current_uid=$(printf '%s' "$pvc_current" | cut -f9)
  if [ "$pvc_identity" != "$EXPECTED_PVC" ] || [ "$pvc_current_uid" != "$pvc_uid" ]; then
    if ! cleanup_new_owned_pod "$pod_uid"; then
      echo "partial state: operation Pod cleanup did not complete; PVCs retained" >&2
    fi
    if [ "$pvc_identity" = "$EXPECTED_PVC" ]; then
      if ! invalidate_checkpoint_evidence; then
        echo "partial state: replacement PVC checkpoint invalidation did not complete; PVCs retained" >&2
      fi
    fi
    echo "error: mounted PVC identity changed after readiness; captured uid=$pvc_uid observed uid=${pvc_current_uid:-absent}; persistent claims retained" >&2
    exit 3
  fi
}

preflight_create() {
  local identity
  identity=$(resource_identity pod "$POD")
  if [ -n "$identity" ] && [ "$identity" != "$EXPECTED_POD" ]; then
    echo "error: pod '$POD' does not have the exact crewmate installation identity" >&2
    exit 2
  fi
  if [ -n "$identity" ]; then
    echo "error: crewmate Pod '$POD' already exists; use restart" >&2
    exit 2
  fi
  require_owned_pvc_or_absent >/dev/null
}

preflight_existing_home() {
  local pvc
  require_owned_or_absent pod "$POD" "$EXPECTED_POD" >/dev/null
  pvc=$(require_owned_pvc_or_absent)
  if [ -z "$pvc" ]; then
    echo "error: crewmate persistent home '$PVC' does not exist" >&2
    exit 2
  fi
  printf '%s' "$pvc"
}

stop_owned_pod() {
  delete_owned_crewmate_resource pod "$POD"
}

invalidate_checkpoint_evidence() {
  local pvc uid rv patch
  pvc=$(require_owned_pvc_or_absent)
  [ -n "$pvc" ] || return 0
  uid=$(printf '%s' "$pvc" | cut -f9)
  rv=$(printf '%s' "$pvc" | cut -f10)
  if [ -z "$uid" ] || [ -z "$rv" ]; then
    echo "error: checkpoint invalidation requires exact PVC UID and resourceVersion evidence" >&2
    exit 2
  fi
  patch=$(printf '{"metadata":{"uid":"%s","resourceVersion":"%s","annotations":{"agent-os.dev/checkpoint-state":"pending","agent-os.dev/writer-state":"active","agent-os.dev/checkpoint-at":null,"agent-os.dev/quiesced-operation":null,"agent-os.dev/checkpoint-operation":null}}}' "$uid" "$rv")
  kube patch pvc "$PVC" --type=merge -p "$patch" >/dev/null
}

record_quiesced_generation() {
  local pvc uid rv patch
  pvc=$(require_owned_pvc_or_absent)
  [ -n "$pvc" ] || return 0
  if [ "$(printf '%s' "$pvc" | cut -f5)" != pending ]; then
    echo "error: checkpoint evidence changed before quiesced generation could be recorded" >&2
    exit 2
  fi
  uid=$(printf '%s' "$pvc" | cut -f9)
  rv=$(printf '%s' "$pvc" | cut -f10)
  if [ -z "$uid" ] || [ -z "$rv" ]; then
    echo "error: quiesced generation requires exact PVC UID and resourceVersion evidence" >&2
    exit 2
  fi
  patch=$(printf '{"metadata":{"uid":"%s","resourceVersion":"%s","annotations":{"agent-os.dev/writer-state":"quiesced","agent-os.dev/quiesced-operation":"%s"}}}' "$uid" "$rv" "$OPERATION_ID")
  kube patch pvc "$PVC" --type=merge -p "$patch" >/dev/null
}

quiesce_owned_home() {
  local pod
  invalidate_checkpoint_evidence
  stop_owned_pod
  if ! pod=$(pod_record); then
    echo "error: could not prove Pod absence after deletion" >&2
    exit 3
  fi
  if [ -n "$pod" ]; then
    echo "error: Pod '$POD' reappeared before quiesced checkpoint generation" >&2
    exit 3
  fi
  record_quiesced_generation
}

record_purge() {
  local phase=$1 checkpoint_at=$2 outcome=${3:-requested} captured_uid=${4:-unknown} observed_uid=${5:-unknown} timestamp
  timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  printf '%s\t%s\tnamespace=%s\tcrewmate=%s\tpod=%s\tpvc=%s\tcheckpoint-at=%s\toutcome=%s\tcaptured-uid=%s\tobserved-uid=%s\n' \
    "$timestamp" "$phase" "$NAMESPACE" "$ID" "$POD" "$PVC" "$checkpoint_at" "$outcome" "$captured_uid" "$observed_uid" >&3
}

case "$COMMAND" in
  create)
    [ -z "$CONFIRM" ] || { echo "usage: $0 create <crewmate-id>" >&2; exit 2; }
    validate_ai_grant
    acquire_lifecycle_locks
    preflight_create
    create_and_wait
    ;;
  status)
    [ -z "$CONFIRM" ] || { echo "usage: $0 status <crewmate-id>" >&2; exit 2; }
    pod=$(pod_record)
    if [ -z "$pod" ]; then
      echo "error: crewmate Pod '$POD' does not exist" >&2
      exit 2
    fi
    if [ "$(printf '%s' "$pod" | cut -f1-4)" != "$EXPECTED_POD" ]; then
      echo "error: pod '$POD' does not have the exact crewmate installation identity" >&2
      exit 2
    fi
    require_owned_pvc_or_absent >/dev/null
    kube get pod "$POD"
    ;;
  stop)
    [ -z "$CONFIRM" ] || { echo "usage: $0 stop <crewmate-id>" >&2; exit 2; }
    acquire_lifecycle_locks
    require_owned_pvc_or_absent >/dev/null
    quiesce_owned_home
    ;;
  restart)
    [ -z "$CONFIRM" ] || { echo "usage: $0 restart <crewmate-id>" >&2; exit 2; }
    validate_ai_grant
    acquire_lifecycle_locks
    preflight_existing_home >/dev/null
    quiesce_owned_home
    create_and_wait
    ;;
  purge)
    echo "purge target: namespace/$NAMESPACE pod/$POD pvc/$PVC" >&2
    if [ "$CONFIRM" != --yes ]; then
      echo "error: purge requires the purge-specific --yes confirmation" >&2
      exit 2
    fi
    acquire_lifecycle_locks
    if ! pod=$(pod_record); then
      echo "error: could not prove crewmate Pod absence before purge" >&2
      exit 3
    fi
    if [ -n "$pod" ]; then
      if [ "$(printf '%s' "$pod" | cut -f1-4)" != "$EXPECTED_POD" ]; then
        echo "error: pod '$POD' does not have the exact crewmate installation identity" >&2
        exit 2
      fi
      echo "error: stop the owned crewmate Pod and prove its absence before checkpointing for purge" >&2
      exit 2
    fi
    pvc=$(preflight_existing_home)
    checkpoint_state=$(printf '%s' "$pvc" | cut -f5)
    checkpoint_at=$(printf '%s' "$pvc" | cut -f6)
    quiesced_operation=$(printf '%s' "$pvc" | cut -f7)
    checkpoint_operation=$(printf '%s' "$pvc" | cut -f8)
    if [[ ! "$checkpoint_at" =~ ^[0-9]{4}-(0[1-9]|1[0-2])-([0-2][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]Z$ ]]; then
      echo "error: purge requires a valid non-secret checkpoint timestamp" >&2
      exit 2
    fi
    if [ "$checkpoint_state" != clean ]; then
      echo "error: purge requires agent-os.dev/checkpoint-state=clean on '$PVC'" >&2
      exit 2
    fi
    if [ -z "$quiesced_operation" ] || [ "$checkpoint_operation" != "$quiesced_operation" ]; then
      echo "error: purge requires checkpoint evidence created for the current quiesced PVC generation" >&2
      exit 2
    fi
    if ! command -v jq >/dev/null 2>&1; then
      echo "error: jq is required to prove that the persistent home is detached" >&2
      exit 2
    fi
    if ! pods_json=$(kube get pods -o json); then
      echo "error: purge could not inventory Pods that may reference PVC '$PVC'" >&2
      exit 3
    fi
    if ! attached=$(printf '%s' "$pods_json" | jq -r --arg claim "$PVC" \
      '[.items[]? | any(.spec.volumes[]?; .persistentVolumeClaim.claimName == $claim)] | any'); then
      echo "error: purge could not validate the Pod attachment inventory" >&2
      exit 3
    fi
    if [ "$attached" = true ]; then
      echo "error: purge refuses PVC '$PVC' while any Pod still references it" >&2
      exit 2
    fi
    if ! pod=$(pod_record); then
      echo "error: could not re-prove crewmate Pod absence during purge" >&2
      exit 3
    fi
    if [ -n "$pod" ]; then
      echo "error: crewmate Pod '$POD' reappeared during purge validation" >&2
      exit 3
    fi
    current_pvc=$(require_owned_pvc_or_absent)
    if [ "$current_pvc" != "$pvc" ]; then
      echo "error: PVC identity, checkpoint, UID, or resourceVersion changed during purge validation" >&2
      exit 3
    fi
    pvc_uid=$(printf '%s' "$pvc" | cut -f9)
    pvc_rv=$(printf '%s' "$pvc" | cut -f10)
    if [ -z "$pvc_uid" ] || [ -z "$pvc_rv" ]; then
      echo "error: purge requires exact PVC UID and resourceVersion evidence" >&2
      exit 2
    fi
    evidence_file=${AGENT_OS_PURGE_EVIDENCE_FILE:-}
    if [ -z "$evidence_file" ] && [ -n "${FM_HOME:-}" ]; then
      evidence_file="$FM_HOME/data/crewmate-purge-evidence.log"
    fi
    if [ -z "$evidence_file" ]; then
      echo "error: set AGENT_OS_PURGE_EVIDENCE_FILE or FM_HOME before purge" >&2
      exit 2
    fi
    mkdir -p "$(dirname "$evidence_file")"
    exec 3>>"$evidence_file"
    record_purge purge-requested "$checkpoint_at" requested "$pvc_uid" pending
    if delete_owned_crewmate_resource pvc "$PVC" "$pvc_uid" "$pvc_rv"; then
      record_purge purge-complete "$checkpoint_at" "$DELETE_OUTCOME" "$DELETE_CAPTURED_UID" "$DELETE_OBSERVED_UID"
    else
      purge_status=$?
      record_purge "purge-incomplete-$DELETE_OUTCOME" "$checkpoint_at" "$DELETE_OUTCOME" "$DELETE_CAPTURED_UID" "$DELETE_OBSERVED_UID"
      exit "$purge_status"
    fi
    ;;
  delete)
    echo "error: delete is ambiguous; use stop to preserve the home or purge <crewmate-id> --yes" >&2
    exit 2
    ;;
  *)
    echo "usage: $0 create|status|stop|restart|purge|delete <crewmate-id> [--yes]" >&2
    exit 2
    ;;
esac
