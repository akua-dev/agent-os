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
TEMPLATE=${AGENT_OS_CREWMATE_TEMPLATE:-/opt/agent-os/tools/agent-os/packages/firstmate/crewmate.yaml}
INSTALLATION_ID="agent-os-firstmate:$NAMESPACE"
OPERATION_ID=${AGENT_OS_OPERATION_ID:-"$(date -u '+%Y%m%d%H%M%S')-$$-$RANDOM"}

if [ ! -f "$TEMPLATE" ]; then
  TEMPLATE="$ROOT/tools/agent-os/packages/firstmate/crewmate.yaml"
fi

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
LOCK_NAMESPACE=$NAMESPACE
EXPECTED_POD="$POD"$'\t'"agent-os"$'\t'"$ID"$'\t'"$INSTALLATION_ID"
EXPECTED_PVC="$PVC"$'\t'"agent-os"$'\t'"$ID"$'\t'"$INSTALLATION_ID"
EXPECTED_LOCK="$LOCK"$'\t'"agent-os"$'\t'"$ID"$'\t'"$INSTALLATION_ID"
LOCK_UID=
LOCK_RV=
LOCK_RENEW_PID=
LOCK_DURATION_SECONDS=${AGENT_OS_LOCK_DURATION_SECONDS:-300}
LOCK_CLOCK_SKEW_SECONDS=${AGENT_OS_LOCK_CLOCK_SKEW_SECONDS:-5}
LOCK_ACQUIRE_SECONDS=${AGENT_OS_LOCK_ACQUIRE_SECONDS:-30}

for seconds in "$LOCK_DURATION_SECONDS" "$LOCK_CLOCK_SKEW_SECONDS" "$LOCK_ACQUIRE_SECONDS"; do
  case "$seconds" in ''|*[!0-9]*) echo "error: lifecycle Lease timing must use whole seconds" >&2; exit 2 ;; esac
done
[ "$LOCK_DURATION_SECONDS" -ge 3 ] || { echo "error: lifecycle Lease duration must be at least 3 seconds" >&2; exit 2; }

kube() {
  "$KUBECTL" "${KUBECTL_ARGS[@]}" -n "$NAMESPACE" "$@"
}

resource_identity() {
  local kind=$1 name=$2
  kube get "$kind" "$name" --ignore-not-found \
    -o 'jsonpath={.metadata.name}{"\t"}{.metadata.labels.app\.kubernetes\.io/managed-by}{"\t"}{.metadata.labels.agent-os\.dev/crewmate}{"\t"}{.metadata.annotations.agent-os\.dev/installation-id}'
}

pod_record() {
  kube get pod "$POD" --ignore-not-found \
    -o 'jsonpath={.metadata.name}{"\t"}{.metadata.labels.app\.kubernetes\.io/managed-by}{"\t"}{.metadata.labels.agent-os\.dev/crewmate}{"\t"}{.metadata.annotations.agent-os\.dev/installation-id}{"\t"}{.metadata.labels.agent-os\.dev/operation-id}{"\t"}{.metadata.uid}{"\t"}{.metadata.resourceVersion}'
}

pvc_record() {
  kube get pvc "$PVC" --ignore-not-found \
    -o 'jsonpath={.metadata.name}{"\t"}{.metadata.labels.app\.kubernetes\.io/managed-by}{"\t"}{.metadata.labels.agent-os\.dev/crewmate}{"\t"}{.metadata.annotations.agent-os\.dev/installation-id}{"\t"}{.metadata.annotations.agent-os\.dev/checkpoint-state}{"\t"}{.metadata.annotations.agent-os\.dev/checkpoint-at}{"\t"}{.metadata.annotations.agent-os\.dev/quiesced-operation}{"\t"}{.metadata.annotations.agent-os\.dev/checkpoint-operation}{"\t"}{.metadata.uid}{"\t"}{.metadata.resourceVersion}'
}

lock_record() {
  kube get lease "$LOCK" --ignore-not-found \
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
  local acquired_at=$1 renewed_at=$2 uid=${3:-} rv=${4:-}
  cat <<YAML
apiVersion: coordination.k8s.io/v1
kind: Lease
metadata:
  name: $LOCK
  namespace: $NAMESPACE
${uid:+  uid: $uid}
${rv:+  resourceVersion: $rv}
  labels:
    app.kubernetes.io/managed-by: agent-os
    agent-os.dev/crewmate: $ID
  annotations:
    agent-os.dev/installation-id: $INSTALLATION_ID
spec:
  holderIdentity: $OPERATION_ID
  acquireTime: $acquired_at
  renewTime: $renewed_at
  leaseDurationSeconds: $LOCK_DURATION_SECONDS
YAML
}

. "$ROOT/bin/agent-os-kubernetes-lease.sh"

finish_lifecycle() {
  local status=$?
  trap - EXIT
  if ! release_lock && [ "$status" -eq 0 ]; then
    status=3
  fi
  exit "$status"
}

trap finish_lifecycle EXIT
trap lock_renewal_failed TERM

cleanup_new_owned_pod() {
  local expected_uid=${1:-} after current identity after_operation after_uid
  after=$(pod_record)
  if [ -z "$after" ]; then
    echo "partial state: crewmate create left no Pod; persistent home retained" >&2
    return
  fi
  identity=$(printf '%s' "$after" | cut -f1-4)
  after_operation=$(printf '%s' "$after" | cut -f5)
  after_uid=$(printf '%s' "$after" | cut -f6)
  if [ "$identity" != "$EXPECTED_POD" ] || [ "$after_operation" != "$OPERATION_ID" ] || \
    [ -z "$after_uid" ] || { [ -n "$expected_uid" ] && [ "$after_uid" != "$expected_uid" ]; }; then
    echo "partial state: replacement or ownership mismatch retained; persistent home retained" >&2
    return
  fi
  current=$(pod_record)
  if [ "$current" != "$after" ]; then
    echo "partial state: Pod identity changed during cleanup; no Pod deleted and persistent home retained" >&2
    return
  fi
  echo "partial state: removing newly created owned Pod '$POD' uid=$after_uid; persistent home retained" >&2
  if ! printf '{"apiVersion":"v1","kind":"DeleteOptions","preconditions":{"uid":"%s"}}\n' "$after_uid" | \
    kube delete --raw "/api/v1/namespaces/$NAMESPACE/pods/$POD" -f -; then
    echo "partial state: UID-precondition rejected; replacement or ownership mismatch retained" >&2
    return
  fi
  kube wait --for=delete "pod/$POD" --timeout=180s
}

create_and_wait() {
  local pvc_before pvc_current pvc_uid pvc_rv pod pod_uid pod_rv
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
  if [ -z "$pod_uid" ] || [ -z "$pod_rv" ]; then
    echo "error: created Pod lacks exact UID or resourceVersion evidence" >&2
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
  local pod uid rv
  pod=$(pod_record)
  if [ -z "$pod" ]; then
    return
  fi
  if [ "$(printf '%s' "$pod" | cut -f1-4)" != "$EXPECTED_POD" ]; then
    echo "error: pod '$POD' does not have the exact crewmate installation identity" >&2
    exit 2
  fi
  uid=$(printf '%s' "$pod" | cut -f6)
  rv=$(printf '%s' "$pod" | cut -f7)
  if [ -z "$uid" ] || [ -z "$rv" ]; then
    echo "error: Pod deletion requires exact UID and resourceVersion evidence" >&2
    exit 2
  fi
  printf '{"apiVersion":"v1","kind":"DeleteOptions","preconditions":{"uid":"%s"}}\n' "$uid" | \
    kube delete --raw "/api/v1/namespaces/$NAMESPACE/pods/$POD" -f -
  kube wait --for=delete "pod/$POD" --timeout=180s
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
  local phase=$1 checkpoint_at=$2 timestamp
  timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  printf '%s\t%s\tnamespace=%s\tcrewmate=%s\tpod=%s\tpvc=%s\tcheckpoint-at=%s\n' \
    "$timestamp" "$phase" "$NAMESPACE" "$ID" "$POD" "$PVC" "$checkpoint_at" >&3
}

case "$COMMAND" in
  create)
    [ -z "$CONFIRM" ] || { echo "usage: $0 create <crewmate-id>" >&2; exit 2; }
    validate_ai_grant
    acquire_lock
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
    acquire_lock
    require_owned_pvc_or_absent >/dev/null
    quiesce_owned_home
    ;;
  restart)
    [ -z "$CONFIRM" ] || { echo "usage: $0 restart <crewmate-id>" >&2; exit 2; }
    validate_ai_grant
    acquire_lock
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
    acquire_lock
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
    record_purge purge-requested "$checkpoint_at"
    printf '{"apiVersion":"v1","kind":"DeleteOptions","preconditions":{"uid":"%s","resourceVersion":"%s"}}\n' \
      "$pvc_uid" "$pvc_rv" | \
      kube delete --raw "/api/v1/namespaces/$NAMESPACE/persistentvolumeclaims/$PVC" -f -
    kube wait --for=delete "pvc/$PVC" --timeout=180s
    record_purge purge-complete "$checkpoint_at"
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
