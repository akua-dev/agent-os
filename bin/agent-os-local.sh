#!/usr/bin/env bash
# agent-os-local.sh - build and operate the local OrbStack Agent OS demo.
# Usage: bin/agent-os-local.sh build|deploy|status|shell|attach|destroy [--yes]
set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CONTEXT=${AGENT_OS_CONTEXT:-orbstack}
NAMESPACE=${AGENT_OS_NAMESPACE:-agent-os-demo}
IMAGE=${AGENT_OS_IMAGE:-agent-os:dev}
COMMAND=${1:-}

if [ "$CONTEXT" != orbstack ] && [ "${AGENT_OS_ALLOW_NON_ORBSTACK:-0}" != 1 ]; then
  echo "error: refusing Kubernetes context '$CONTEXT'; set AGENT_OS_ALLOW_NON_ORBSTACK=1 to opt in" >&2
  exit 2
fi

cd "$ROOT"

case "$COMMAND" in
  build)
    docker build -t "$IMAGE" .
    ;;
  deploy)
    if [ "$CONTEXT" = orbstack ]; then
      orbctl start k8s
      kubectl --context "$CONTEXT" wait --for=condition=Ready node/orbstack --timeout=120s
    fi
    kubectl --context "$CONTEXT" apply -k deploy/orbstack
    ;;
  status)
    kubectl --context "$CONTEXT" -n "$NAMESPACE" get statefulset agent-os-firstmate
    ;;
  shell)
    kubectl --context "$CONTEXT" -n "$NAMESPACE" exec -it statefulset/agent-os-firstmate -- bash
    ;;
  attach)
    kubectl --context "$CONTEXT" -n "$NAMESPACE" exec -it statefulset/agent-os-firstmate -- herdr
    ;;
  destroy)
    if [ "${2:-}" != --yes ]; then
      echo "error: destroy requires --yes and deletes only namespace '$NAMESPACE'" >&2
      exit 2
    fi
    kubectl --context "$CONTEXT" delete namespace "$NAMESPACE"
    ;;
  *)
    echo "usage: $0 build|deploy|status|shell|attach|destroy [--yes]" >&2
    exit 2
    ;;
esac
