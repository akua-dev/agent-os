#!/usr/bin/env bash
# agent-os-kubernetes.sh - render and operate the portable Agent OS package.
# Usage: bin/agent-os-kubernetes.sh install|upgrade|rollback|status|uninstall [--yes]
set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
COMMAND=${1:-}
CONFIRM=${2:-}
PACKAGE=${AGENT_OS_PACKAGE:-"$ROOT/tools/agent-os/packages/firstmate/package.k"}
INPUTS=${AGENT_OS_INPUTS:-"$ROOT/tools/agent-os/packages/firstmate/inputs.example.yaml"}
CONTEXT=${AGENT_OS_CONTEXT:-}
NAMESPACE=${AGENT_OS_NAMESPACE:-agent-os}
AKUA=${AGENT_OS_AKUA:-akua}
KUBECTL=${AGENT_OS_KUBECTL:-kubectl}
OUT=$(mktemp -d)

cleanup() {
  rm -rf "$OUT"
}
trap cleanup EXIT

if [ -z "$CONTEXT" ]; then
  echo "error: set AGENT_OS_CONTEXT to the Kubernetes context to operate" >&2
  exit 2
fi

render() {
  "$AKUA" render --no-agent-mode --package "$PACKAGE" --inputs "$INPUTS" --out "$OUT"
}

case "$COMMAND" in
  install|upgrade)
    render
    "$KUBECTL" --context "$CONTEXT" apply -f "$OUT"
    "$KUBECTL" --context "$CONTEXT" -n "$NAMESPACE" rollout status statefulset/agent-os-firstmate --timeout=180s
    ;;
  rollback)
    "$KUBECTL" --context "$CONTEXT" -n "$NAMESPACE" rollout undo statefulset/agent-os-firstmate
    "$KUBECTL" --context "$CONTEXT" -n "$NAMESPACE" rollout status statefulset/agent-os-firstmate --timeout=180s
    ;;
  status)
    "$KUBECTL" --context "$CONTEXT" -n "$NAMESPACE" get statefulset agent-os-firstmate
    ;;
  uninstall)
    if [ "$CONFIRM" != --yes ]; then
      echo "error: uninstall requires --yes" >&2
      exit 2
    fi
    render
    "$KUBECTL" --context "$CONTEXT" delete --ignore-not-found -f "$OUT"
    ;;
  *)
    echo "usage: $0 install|upgrade|rollback|status|uninstall [--yes]" >&2
    exit 2
    ;;
esac
