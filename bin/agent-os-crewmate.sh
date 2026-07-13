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

if [ ! -f "$TEMPLATE" ]; then
  TEMPLATE="$ROOT/tools/agent-os/packages/firstmate/crewmate.yaml"
fi

case "$ID" in
  ''|*[!a-z0-9-]*|-*|*-) echo "error: invalid crewmate id '$ID'" >&2; exit 2 ;;
esac

KUBECTL_ARGS=()
if [ -n "${AGENT_OS_CONTEXT:-}" ]; then
  KUBECTL_ARGS=(--context "$AGENT_OS_CONTEXT")
elif [ "${AGENT_OS_IN_CLUSTER:-0}" != 1 ] && [ ! -f /var/run/secrets/kubernetes.io/serviceaccount/token ]; then
  echo "error: set AGENT_OS_CONTEXT outside Kubernetes; ambient contexts are refused" >&2
  exit 2
fi

POD="agent-os-crewmate-$ID"
PVC="$POD-home"
EXPECTED_POD="$POD"$'\t'"agent-os"$'\t'"$ID"$'\t'"$INSTALLATION_ID"
EXPECTED_PVC="$PVC"$'\t'"agent-os"$'\t'"$ID"$'\t'"$INSTALLATION_ID"

kube() {
  "$KUBECTL" "${KUBECTL_ARGS[@]}" -n "$NAMESPACE" "$@"
}

resource_identity() {
  local kind=$1 name=$2
  kube get "$kind" "$name" --ignore-not-found \
    -o 'jsonpath={.metadata.name}{"\t"}{.metadata.labels.app\.kubernetes\.io/managed-by}{"\t"}{.metadata.labels.agent-os\.dev/crewmate}{"\t"}{.metadata.annotations.agent-os\.dev/installation-id}'
}

pvc_record() {
  kube get pvc "$PVC" --ignore-not-found \
    -o 'jsonpath={.metadata.name}{"\t"}{.metadata.labels.app\.kubernetes\.io/managed-by}{"\t"}{.metadata.labels.agent-os\.dev/crewmate}{"\t"}{.metadata.annotations.agent-os\.dev/installation-id}{"\t"}{.metadata.annotations.agent-os\.dev/checkpoint-state}{"\t"}{.metadata.annotations.agent-os\.dev/checkpoint-at}'
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
    "$TEMPLATE"
}

apply_and_wait() {
  render_resources | kube apply -f -
  if ! kube wait --for=condition=Ready "pod/$POD" --timeout=180s; then
    kube delete pod "$POD" --ignore-not-found
    echo "error: crewmate Pod did not become ready with the authorized AI Secret" >&2
    exit 1
  fi
}

preflight_create() {
  require_owned_or_absent pod "$POD" "$EXPECTED_POD" >/dev/null
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
    preflight_create
    apply_and_wait
    ;;
  status)
    [ -z "$CONFIRM" ] || { echo "usage: $0 status <crewmate-id>" >&2; exit 2; }
    if [ -z "$(require_owned_or_absent pod "$POD" "$EXPECTED_POD")" ]; then
      echo "error: crewmate Pod '$POD' does not exist" >&2
      exit 2
    fi
    require_owned_pvc_or_absent >/dev/null
    kube get pod "$POD"
    ;;
  stop)
    [ -z "$CONFIRM" ] || { echo "usage: $0 stop <crewmate-id>" >&2; exit 2; }
    require_owned_or_absent pod "$POD" "$EXPECTED_POD" >/dev/null
    require_owned_pvc_or_absent >/dev/null
    kube delete pod "$POD" --ignore-not-found
    ;;
  restart)
    [ -z "$CONFIRM" ] || { echo "usage: $0 restart <crewmate-id>" >&2; exit 2; }
    validate_ai_grant
    preflight_existing_home >/dev/null
    kube delete pod "$POD" --ignore-not-found
    apply_and_wait
    ;;
  purge)
    echo "purge target: namespace/$NAMESPACE pod/$POD pvc/$PVC" >&2
    if [ "$CONFIRM" != --yes ]; then
      echo "error: purge requires the purge-specific --yes confirmation" >&2
      exit 2
    fi
    pvc=$(preflight_existing_home)
    checkpoint_state=$(printf '%s' "$pvc" | cut -f5)
    checkpoint_at=$(printf '%s' "$pvc" | cut -f6)
    if [[ ! "$checkpoint_at" =~ ^[0-9]{4}-(0[1-9]|1[0-2])-([0-2][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]Z$ ]]; then
      echo "error: purge requires a valid non-secret checkpoint timestamp" >&2
      exit 2
    fi
    if [ "$checkpoint_state" != clean ]; then
      echo "error: purge requires agent-os.dev/checkpoint-state=clean on '$PVC'" >&2
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
    kube delete pod "$POD" --ignore-not-found
    kube delete pvc "$PVC" --ignore-not-found
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
