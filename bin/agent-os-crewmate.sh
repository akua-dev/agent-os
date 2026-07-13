#!/usr/bin/env bash
# agent-os-crewmate.sh - create, inspect, or delete one isolated crewmate Pod.
# Usage: bin/agent-os-crewmate.sh create|status|delete <crewmate-id>
set -eu

COMMAND=${1:-}
ID=${2:-}
NAMESPACE=${AGENT_OS_NAMESPACE:-agent-os}
IMAGE=${AGENT_OS_IMAGE:-}
IMAGE_PULL_POLICY=${AGENT_OS_IMAGE_PULL_POLICY:-IfNotPresent}
AI_SECRET=${AGENT_OS_AI_SECRET:-}
KUBECTL=${AGENT_OS_KUBECTL:-kubectl}
TEMPLATE=${AGENT_OS_CREWMATE_TEMPLATE:-/opt/agent-os/tools/agent-os/packages/firstmate/crewmate.yaml}

if [ ! -f "$TEMPLATE" ]; then
  TEMPLATE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tools/agent-os/packages/firstmate/crewmate.yaml"
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

case "$COMMAND" in
  create)
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
    sed \
      -e "s|__AGENT_OS_CREWMATE_ID__|$ID|g" \
      -e "s|__AGENT_OS_NAMESPACE__|$NAMESPACE|g" \
      -e "s|__AGENT_OS_IMAGE__|$IMAGE|g" \
      -e "s|__AGENT_OS_IMAGE_PULL_POLICY__|$IMAGE_PULL_POLICY|g" \
      -e "s|__AGENT_OS_AI_SECRET__|$AI_SECRET|g" \
      "$TEMPLATE" | "$KUBECTL" "${KUBECTL_ARGS[@]}" -n "$NAMESPACE" apply -f -
    if ! "$KUBECTL" "${KUBECTL_ARGS[@]}" -n "$NAMESPACE" wait --for=condition=Ready "pod/$POD" --timeout=180s; then
      "$KUBECTL" "${KUBECTL_ARGS[@]}" -n "$NAMESPACE" delete pod "$POD" --ignore-not-found
      echo "error: crewmate Pod did not become ready with the authorized AI Secret" >&2
      exit 1
    fi
    ;;
  status)
    "$KUBECTL" "${KUBECTL_ARGS[@]}" -n "$NAMESPACE" get pod "$POD"
    ;;
  delete)
    "$KUBECTL" "${KUBECTL_ARGS[@]}" -n "$NAMESPACE" delete pod "$POD" --ignore-not-found
    "$KUBECTL" "${KUBECTL_ARGS[@]}" -n "$NAMESPACE" delete pvc "$PVC" --ignore-not-found
    ;;
  *)
    echo "usage: $0 create|status|delete <crewmate-id>" >&2
    exit 2
    ;;
esac
