#!/usr/bin/env bash
# agent-os-kubernetes.sh - render and operate the portable Agent OS package.
# Usage: bin/agent-os-kubernetes.sh install|upgrade|rollback|status|uninstall|cleanup-cluster-rbac [--yes] [--delete-namespace]
set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
COMMAND=${1:-}
shift || true
PACKAGE=${AGENT_OS_PACKAGE:-"$ROOT/tools/agent-os/packages/firstmate/package.k"}
INPUTS=${AGENT_OS_INPUTS:-"$ROOT/tools/agent-os/packages/firstmate/inputs.example.yaml"}
CONTEXT=${AGENT_OS_CONTEXT:-}
REQUESTED_NAMESPACE=${AGENT_OS_NAMESPACE:-}
NAMESPACE=${REQUESTED_NAMESPACE:-agent-os}
AKUA=${AGENT_OS_AKUA:-akua}
KUBECTL=${AGENT_OS_KUBECTL:-kubectl}
OUT=$(mktemp -d)
CONFIRMED=0
DELETE_NAMESPACE=0
MANAGES_NAMESPACE=0
DESIRED_RBAC=none
INSTALLATION_ID=

cleanup() {
  rm -rf "$OUT"
}
trap cleanup EXIT

usage() {
  echo "usage: $0 install|upgrade|rollback|status|uninstall|cleanup-cluster-rbac [--yes] [--delete-namespace]" >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --yes) CONFIRMED=1 ;;
    --delete-namespace) DELETE_NAMESPACE=1 ;;
    *) usage ;;
  esac
  shift
done

if [ -z "$CONTEXT" ]; then
  echo "error: set AGENT_OS_CONTEXT to the Kubernetes context to operate" >&2
  exit 2
fi

render_has_kind() {
  grep -R -Eq "^kind:[[:space:]]*$1$" "$OUT"
}

rendered_statefulset() {
  grep -Rl '^kind:[[:space:]]*StatefulSet$' "$OUT" || true
}

render() {
  local statefulset statefulset_count rendered_namespace
  if ! command -v "$AKUA" >/dev/null 2>&1; then
    echo "error: Akua renderer '$AKUA' is required for Kubernetes package operations" >&2
    exit 2
  fi
  "$AKUA" render --no-agent-mode --package "$PACKAGE" --inputs "$INPUTS" --out "$OUT"
  statefulset=$(rendered_statefulset)
  statefulset_count=$(printf '%s\n' "$statefulset" | sed '/^$/d' | wc -l | tr -d ' ')
  if [ "$statefulset_count" -ne 1 ]; then
    echo "error: package must render exactly one StatefulSet" >&2
    exit 2
  fi
  rendered_namespace=$(awk '$1 == "namespace:" { print $2; exit }' "$statefulset")
  if [ -z "$rendered_namespace" ]; then
    echo "error: rendered StatefulSet has no namespace" >&2
    exit 2
  fi
  if [ -n "$REQUESTED_NAMESPACE" ] && [ "$REQUESTED_NAMESPACE" != "$rendered_namespace" ]; then
    echo "error: AGENT_OS_NAMESPACE '$REQUESTED_NAMESPACE' does not match rendered namespace '$rendered_namespace'" >&2
    exit 2
  fi
  NAMESPACE=$rendered_namespace
  INSTALLATION_ID="agent-os-firstmate:$NAMESPACE"
  if render_has_kind Namespace; then
    MANAGES_NAMESPACE=1
  fi
  if render_has_kind ClusterRoleBinding; then
    DESIRED_RBAC=cluster-admin
  elif render_has_kind Role; then
    DESIRED_RBAC=namespace
  fi
}

namespace_name() {
  "$KUBECTL" --context "$CONTEXT" get namespace "$NAMESPACE" --ignore-not-found -o name
}

namespace_identity() {
  "$KUBECTL" --context "$CONTEXT" get namespace "$NAMESPACE" \
    -o 'jsonpath={.metadata.labels.app\.kubernetes\.io/managed-by}{"\t"}{.metadata.annotations.agent-os\.dev/installation-id}'
}

require_namespace_contract() {
  local name identity
  name=$(namespace_name)
  if [ "$MANAGES_NAMESPACE" -eq 1 ]; then
    if [ -z "$name" ]; then
      return
    fi
    identity=$(namespace_identity)
    if [ "$identity" != "agent-os"$'\t'"$INSTALLATION_ID" ]; then
      echo "error: namespace '$NAMESPACE' exists without the exact Agent OS installation identity" >&2
      exit 2
    fi
    return
  fi
  if [ -z "$name" ]; then
    echo "error: createNamespace=false requires the pre-existing namespace '$NAMESPACE'" >&2
    exit 2
  fi
  identity=$(namespace_identity)
  if [ "$identity" != $'\t' ]; then
    echo "error: createNamespace=false requires an unowned namespace; '$NAMESPACE' carries ownership metadata" >&2
    exit 2
  fi
}

workload_state() {
  "$KUBECTL" --context "$CONTEXT" -n "$NAMESPACE" get statefulset agent-os-firstmate \
    --ignore-not-found \
    -o 'jsonpath={.metadata.name}{"\t"}{.metadata.annotations.agent-os\.dev/rbac-mode}{"\t"}{.metadata.annotations.agent-os\.dev/cluster-rbac-cleanup}'
}

delete_namespace_rbac() {
  "$KUBECTL" --context "$CONTEXT" -n "$NAMESPACE" delete rolebinding agent-os-firstmate-runtime --ignore-not-found
  "$KUBECTL" --context "$CONTEXT" -n "$NAMESPACE" delete role agent-os-firstmate-runtime --ignore-not-found
}

apply_rendered() {
  "$KUBECTL" --context "$CONTEXT" apply -f "$OUT"
  "$KUBECTL" --context "$CONTEXT" -n "$NAMESPACE" rollout status statefulset/agent-os-firstmate --timeout=180s
}

verify_desired_rbac() {
  local role_name binding_identity expected_identity
  if [ "$DESIRED_RBAC" = namespace ]; then
    role_name=$("$KUBECTL" --context "$CONTEXT" -n "$NAMESPACE" get role agent-os-firstmate-runtime \
      -o 'jsonpath={.metadata.name}')
    binding_identity=$("$KUBECTL" --context "$CONTEXT" -n "$NAMESPACE" get rolebinding agent-os-firstmate-runtime \
      -o 'jsonpath={.roleRef.kind}{"\t"}{.roleRef.name}{"\t"}{.subjects[0].kind}{"\t"}{.subjects[0].name}{"\t"}{.subjects[0].namespace}')
    expected_identity="Role"$'\t'"agent-os-firstmate-runtime"$'\t'"ServiceAccount"$'\t'"agent-os-firstmate"$'\t'"$NAMESPACE"
    if [ "$role_name" != agent-os-firstmate-runtime ] || [ "$binding_identity" != "$expected_identity" ]; then
      echo "error: desired namespace RBAC did not verify after apply" >&2
      exit 2
    fi
  fi
}

cleanup_command() {
  printf 'AGENT_OS_CONTEXT=%q AGENT_OS_NAMESPACE=%q AGENT_OS_PACKAGE=%q AGENT_OS_INPUTS=%q AGENT_OS_AKUA=%q AGENT_OS_KUBECTL=%q %q cleanup-cluster-rbac --yes' \
    "$CONTEXT" "$NAMESPACE" "$PACKAGE" "$INPUTS" "$AKUA" "$KUBECTL" "$0"
}

report_cluster_cleanup() {
  echo "incomplete: privileged cleanup is required: $(cleanup_command)" >&2
  echo "required evidence: clusterrolebinding/agent-os-firstmate-$NAMESPACE absent" >&2
}

delete_rendered_namespaced_resources() {
  local files file kind
  files=$(find "$OUT" -type f -name '*.yaml' -print)
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    kind=$(awk '$1 == "kind:" { print $2; exit }' "$file")
    case "$kind" in
      Namespace|ClusterRoleBinding) ;;
      *) "$KUBECTL" --context "$CONTEXT" delete --ignore-not-found -f "$file" ;;
    esac
  done <<< "$files"
}

namespace_is_empty() {
  local resources resource objects object
  if ! resources=$("$KUBECTL" --context "$CONTEXT" api-resources --verbs=list --namespaced -o name); then
    echo "error: could not inventory namespaced Kubernetes resource types" >&2
    return 1
  fi
  while IFS= read -r resource; do
    [ -n "$resource" ] || continue
    case "$resource" in
      events|events.events.k8s.io|leases.coordination.k8s.io) continue ;;
    esac
    if ! objects=$("$KUBECTL" --context "$CONTEXT" -n "$NAMESPACE" get "$resource" -o name); then
      echo "error: could not inventory '$resource' in namespace '$NAMESPACE'" >&2
      return 1
    fi
    while IFS= read -r object; do
      [ -n "$object" ] || continue
      case "$object" in
        serviceaccount/default|configmap/kube-root-ca.crt) ;;
        *)
          echo "error: namespace '$NAMESPACE' still contains foreign resource '$object'" >&2
          return 1
          ;;
      esac
    done <<< "$objects"
  done <<< "$resources"
}

delete_owned_empty_namespace() {
  local identity
  if [ "$MANAGES_NAMESPACE" -ne 1 ]; then
    echo "error: --delete-namespace requires createNamespace=true in the current inputs" >&2
    exit 2
  fi
  identity=$(namespace_identity)
  if [ "$identity" != "agent-os"$'\t'"$INSTALLATION_ID" ]; then
    echo "error: namespace '$NAMESPACE' no longer has the exact Agent OS installation identity" >&2
    exit 2
  fi
  if ! namespace_is_empty; then
    exit 2
  fi
  identity=$(namespace_identity)
  if [ "$identity" != "agent-os"$'\t'"$INSTALLATION_ID" ]; then
    echo "error: namespace '$NAMESPACE' ownership changed during deletion checks" >&2
    exit 2
  fi
  "$KUBECTL" --context "$CONTEXT" delete namespace "$NAMESPACE"
}

cleanup_cluster_rbac() {
  local binding identity workload
  binding="agent-os-firstmate-$NAMESPACE"
  identity=$("$KUBECTL" --context "$CONTEXT" get clusterrolebinding "$binding" --ignore-not-found \
    -o 'jsonpath={.metadata.name}{"\t"}{.metadata.labels.app\.kubernetes\.io/managed-by}{"\t"}{.metadata.annotations.agent-os\.dev/installation-id}')
  if [ -n "$identity" ] && [ "$identity" != "$binding"$'\t'"agent-os"$'\t'"$INSTALLATION_ID" ]; then
    echo "error: clusterrolebinding '$binding' does not have the exact Agent OS installation identity" >&2
    exit 2
  fi
  if [ -n "$identity" ]; then
    "$KUBECTL" --context "$CONTEXT" delete clusterrolebinding "$binding"
    "$KUBECTL" --context "$CONTEXT" wait --for=delete "clusterrolebinding/$binding" --timeout=60s
  fi
  if [ -n "$(namespace_name)" ]; then
    workload=$(workload_state)
    if [ -n "$workload" ]; then
      "$KUBECTL" --context "$CONTEXT" -n "$NAMESPACE" annotate statefulset agent-os-firstmate \
        agent-os.dev/cluster-rbac-cleanup- >/dev/null
    fi
  fi
  echo "evidence: clusterrolebinding/$binding absent"
}

case "$COMMAND" in
  install)
    [ "$CONFIRMED" -eq 0 ] && [ "$DELETE_NAMESPACE" -eq 0 ] || usage
    render
    require_namespace_contract
    if [ -n "$(workload_state)" ]; then
      echo "error: agent-os-firstmate already exists; use upgrade" >&2
      exit 2
    fi
    apply_rendered
    ;;
  upgrade)
    [ "$CONFIRMED" -eq 0 ] && [ "$DELETE_NAMESPACE" -eq 0 ] || usage
    render
    require_namespace_contract
    previous=$(workload_state)
    if [ -z "$previous" ]; then
      echo "error: agent-os-firstmate does not exist; use install" >&2
      exit 2
    fi
    previous_mode=$(printf '%s' "$previous" | cut -f2)
    previous_cleanup=$(printf '%s' "$previous" | cut -f3)
    cleanup_required=0
    if [ "$DESIRED_RBAC" != cluster-admin ] && \
      { [ "$previous_mode" = cluster-admin ] || [ -z "$previous_mode" ] || [ "$previous_cleanup" = required ]; }; then
      cleanup_required=1
      "$KUBECTL" --context "$CONTEXT" -n "$NAMESPACE" annotate statefulset agent-os-firstmate \
        agent-os.dev/cluster-rbac-cleanup=required --overwrite >/dev/null
    fi
    apply_rendered
    verify_desired_rbac
    if [ "$DESIRED_RBAC" != namespace ]; then
      delete_namespace_rbac
    fi
    if [ "$DESIRED_RBAC" = cluster-admin ] && [ "$previous_cleanup" = required ]; then
      "$KUBECTL" --context "$CONTEXT" -n "$NAMESPACE" annotate statefulset agent-os-firstmate \
        agent-os.dev/cluster-rbac-cleanup- >/dev/null
    fi
    if [ "$cleanup_required" -eq 1 ]; then
      report_cluster_cleanup
      exit 3
    fi
    ;;
  rollback)
    [ "$CONFIRMED" -eq 0 ] && [ "$DELETE_NAMESPACE" -eq 0 ] || usage
    "$KUBECTL" --context "$CONTEXT" -n "$NAMESPACE" rollout undo statefulset/agent-os-firstmate
    "$KUBECTL" --context "$CONTEXT" -n "$NAMESPACE" rollout status statefulset/agent-os-firstmate --timeout=180s
    ;;
  status)
    [ "$CONFIRMED" -eq 0 ] && [ "$DELETE_NAMESPACE" -eq 0 ] || usage
    "$KUBECTL" --context "$CONTEXT" -n "$NAMESPACE" get statefulset agent-os-firstmate
    ;;
  uninstall)
    if [ "$CONFIRMED" -ne 1 ]; then
      echo "error: uninstall requires --yes" >&2
      exit 2
    fi
    render
    require_namespace_contract
    previous=$(workload_state)
    previous_mode=$(printf '%s' "$previous" | cut -f2)
    previous_cleanup=$(printf '%s' "$previous" | cut -f3)
    delete_rendered_namespaced_resources
    delete_namespace_rbac
    if [ "$DELETE_NAMESPACE" -eq 1 ]; then
      delete_owned_empty_namespace
    fi
    if [ "$DESIRED_RBAC" = cluster-admin ] || [ "$previous_mode" = cluster-admin ] || \
      [ "$previous_cleanup" = required ] || { [ -n "$previous" ] && [ -z "$previous_mode" ]; }; then
      report_cluster_cleanup
      exit 3
    fi
    ;;
  cleanup-cluster-rbac)
    if [ "$CONFIRMED" -ne 1 ] || [ "$DELETE_NAMESPACE" -eq 1 ]; then
      echo "error: cleanup-cluster-rbac requires --yes" >&2
      exit 2
    fi
    render
    cleanup_cluster_rbac
    ;;
  *) usage ;;
esac
