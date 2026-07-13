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
  if ! command -v "$AKUA" >/dev/null 2>&1; then
    echo "error: Akua renderer '$AKUA' is required for Kubernetes package operations" >&2
    exit 2
  fi
  "$AKUA" render --no-agent-mode --package "$PACKAGE" --inputs "$INPUTS" --out "$OUT"
}

render_has_kind() {
  grep -R -Eq "^kind:[[:space:]]*$1$" "$OUT"
}

delete_namespace_rbac() {
  "$KUBECTL" --context "$CONTEXT" -n "$NAMESPACE" delete rolebinding agent-os-firstmate-runtime --ignore-not-found
  "$KUBECTL" --context "$CONTEXT" -n "$NAMESPACE" delete role agent-os-firstmate-runtime --ignore-not-found
}

delete_cluster_admin_rbac() {
  "$KUBECTL" --context "$CONTEXT" delete clusterrolebinding "agent-os-firstmate-$NAMESPACE" --ignore-not-found
}

reconcile_rbac() {
  render_has_kind Role || delete_namespace_rbac
  render_has_kind ClusterRoleBinding || delete_cluster_admin_rbac
}

apply_rendered() {
  "$KUBECTL" --context "$CONTEXT" apply -f "$OUT"
  "$KUBECTL" --context "$CONTEXT" -n "$NAMESPACE" rollout status statefulset/agent-os-firstmate --timeout=180s
}

case "$COMMAND" in
  install)
    render
    apply_rendered
    ;;
  upgrade)
    render
    reconcile_rbac
    apply_rendered
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
    delete_cluster_admin_rbac
    delete_namespace_rbac
    "$KUBECTL" --context "$CONTEXT" delete --ignore-not-found -f "$OUT"
    ;;
  *)
    echo "usage: $0 install|upgrade|rollback|status|uninstall [--yes]" >&2
    exit 2
    ;;
esac
