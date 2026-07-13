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
    -o 'jsonpath={.metadata.name}{"\t"}{.metadata.annotations.agent-os\.dev/rbac-mode}{"\t"}{.metadata.annotations.agent-os\.dev/cluster-rbac-cleanup}{"\t"}{.metadata.labels.app\.kubernetes\.io/managed-by}{"\t"}{.metadata.annotations.agent-os\.dev/installation-id}'
}

require_workload_owned() {
  local state=$1 required=${2:-required} identity
  if [ -z "$state" ]; then
    if [ "$required" = required ]; then
      echo "error: agent-os-firstmate does not exist" >&2
      exit 2
    fi
    return
  fi
  identity=$(printf '%s' "$state" | cut -f1,4,5)
  if [ "$identity" != "agent-os-firstmate"$'\t'"agent-os"$'\t'"$INSTALLATION_ID" ]; then
    echo "error: StatefulSet 'agent-os-firstmate' does not have the exact installation identity" >&2
    exit 2
  fi
}

rendered_resource_field() {
  local file=$1 field=$2
  awk -v field="$field" '$1 == field ":" { print $2; exit }' "$file"
}

live_resource_identity() {
  local kind=$1 name=$2
  "$KUBECTL" --context "$CONTEXT" -n "$NAMESPACE" get "$kind" "$name" --ignore-not-found \
    -o 'jsonpath={.metadata.name}{"\t"}{.metadata.labels.app\.kubernetes\.io/managed-by}{"\t"}{.metadata.annotations.agent-os\.dev/installation-id}'
}

require_namespaced_resource_owned_or_absent() {
  local kind=$1 name=$2 identity expected
  identity=$(live_resource_identity "$kind" "$name")
  expected="$name"$'\t'"agent-os"$'\t'"$INSTALLATION_ID"
  if [ -n "$identity" ] && [ "$identity" != "$expected" ]; then
    echo "error: $kind '$name' does not have the exact Agent OS installation identity" >&2
    exit 2
  fi
}

preflight_rendered_resources() {
  local include_cluster=${1:-0} file kind name identity binding
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    kind=$(rendered_resource_field "$file" kind)
    name=$(rendered_resource_field "$file" name)
    case "$kind" in
      Namespace) ;;
      ClusterRoleBinding)
        [ "$include_cluster" -eq 1 ] || continue
        identity=$("$KUBECTL" --context "$CONTEXT" get clusterrolebinding "$name" --ignore-not-found \
          -o 'jsonpath={.metadata.name}{"\t"}{.metadata.labels.app\.kubernetes\.io/managed-by}{"\t"}{.metadata.annotations.agent-os\.dev/installation-id}')
        binding="$name"$'\t'"agent-os"$'\t'"$INSTALLATION_ID"
        if [ -n "$identity" ] && [ "$identity" != "$binding" ]; then
          echo "error: ClusterRoleBinding '$name' does not have the exact Agent OS installation identity" >&2
          exit 2
        fi
        ;;
      *) require_namespaced_resource_owned_or_absent "$kind" "$name" ;;
    esac
  done < <(find "$OUT" -type f -name '*.yaml' -print)
}

delete_namespace_rbac() {
  require_namespaced_resource_owned_or_absent RoleBinding agent-os-firstmate-runtime
  require_namespaced_resource_owned_or_absent Role agent-os-firstmate-runtime
  "$KUBECTL" --context "$CONTEXT" -n "$NAMESPACE" delete rolebinding agent-os-firstmate-runtime --ignore-not-found
  "$KUBECTL" --context "$CONTEXT" -n "$NAMESPACE" delete role agent-os-firstmate-runtime --ignore-not-found
}

apply_rendered() {
  "$KUBECTL" --context "$CONTEXT" apply -f "$OUT"
  "$KUBECTL" --context "$CONTEXT" -n "$NAMESPACE" rollout status statefulset/agent-os-firstmate --timeout=180s
}

verify_desired_rbac() {
  local role_json binding_json
  if [ "$DESIRED_RBAC" = namespace ]; then
    if ! command -v jq >/dev/null 2>&1; then
      echo "error: jq is required to verify namespace RBAC exactly" >&2
      exit 2
    fi
    role_json=$("$KUBECTL" --context "$CONTEXT" -n "$NAMESPACE" get role agent-os-firstmate-runtime -o json)
    binding_json=$("$KUBECTL" --context "$CONTEXT" -n "$NAMESPACE" get rolebinding agent-os-firstmate-runtime -o json)
    if ! printf '%s' "$role_json" | jq -e '
      .metadata.name == "agent-os-firstmate-runtime" and
      .rules == [
        {"apiGroups":[""],"resources":["pods","persistentvolumeclaims"],"verbs":["get","list","watch","create","delete","patch"]},
        {"apiGroups":[""],"resources":["pods/log","pods/exec"],"verbs":["get","list","watch","create","delete"]},
        {"apiGroups":["apps"],"resources":["statefulsets"],"verbs":["get","list","watch"]}
      ]' >/dev/null ||
      ! printf '%s' "$binding_json" | jq -e --arg namespace "$NAMESPACE" '
        .roleRef == {"apiGroup":"rbac.authorization.k8s.io","kind":"Role","name":"agent-os-firstmate-runtime"} and
        .subjects == [{"kind":"ServiceAccount","name":"agent-os-firstmate","namespace":$namespace}]' >/dev/null; then
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

delete_rendered_kind() {
  local desired_kind=$1 file kind
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    kind=$(rendered_resource_field "$file" kind)
    if [ "$kind" = "$desired_kind" ]; then
      "$KUBECTL" --context "$CONTEXT" delete --ignore-not-found --wait=true -f "$file"
    fi
  done < <(find "$OUT" -type f -name '*.yaml' -print)
}

delete_rendered_namespaced_resources() {
  local kind
  delete_rendered_kind StatefulSet
  "$KUBECTL" --context "$CONTEXT" -n "$NAMESPACE" wait --for=delete pod/agent-os-firstmate-0 --timeout=180s
  for kind in Service RoleBinding Role ServiceAccount; do
    delete_rendered_kind "$kind"
  done
  delete_rendered_kind PersistentVolumeClaim
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
      events|events.events.k8s.io) continue ;;
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
  local binding identity workload mode cleanup_marker
  binding="agent-os-firstmate-$NAMESPACE"
  identity=$("$KUBECTL" --context "$CONTEXT" get clusterrolebinding "$binding" --ignore-not-found \
    -o 'jsonpath={.metadata.name}{"\t"}{.metadata.labels.app\.kubernetes\.io/managed-by}{"\t"}{.metadata.annotations.agent-os\.dev/installation-id}')
  if [ -n "$identity" ] && [ "$identity" != "$binding"$'\t'"agent-os"$'\t'"$INSTALLATION_ID" ]; then
    echo "error: clusterrolebinding '$binding' does not have the exact Agent OS installation identity" >&2
    exit 2
  fi
  if [ -n "$identity" ]; then
    workload=
    if [ -n "$(namespace_name)" ]; then
      workload=$(workload_state)
      require_workload_owned "$workload" optional
    fi
    if [ -n "$workload" ]; then
      mode=$(printf '%s' "$workload" | cut -f2)
      cleanup_marker=$(printf '%s' "$workload" | cut -f3)
      if [ "$mode" = cluster-admin ] || [ "$cleanup_marker" != required ]; then
        echo "error: ClusterRoleBinding '$binding' is not proven stale by the workload cleanup marker" >&2
        exit 2
      fi
    fi
    "$KUBECTL" --context "$CONTEXT" delete clusterrolebinding "$binding"
    "$KUBECTL" --context "$CONTEXT" wait --for=delete "clusterrolebinding/$binding" --timeout=60s
  fi
  if [ -n "$(namespace_name)" ]; then
    workload=$(workload_state)
    require_workload_owned "$workload" optional
    if [ -n "$workload" ] && [ "$(printf '%s' "$workload" | cut -f3)" = required ]; then
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
    preflight_rendered_resources 1
    previous=$(workload_state)
    require_workload_owned "$previous" optional
    if [ -n "$previous" ]; then
      echo "error: agent-os-firstmate already exists; use upgrade" >&2
      exit 2
    fi
    apply_rendered
    ;;
  upgrade)
    [ "$CONFIRMED" -eq 0 ] && [ "$DELETE_NAMESPACE" -eq 0 ] || usage
    render
    require_namespace_contract
    preflight_rendered_resources 1
    previous=$(workload_state)
    if [ -z "$previous" ]; then
      echo "error: agent-os-firstmate does not exist; use install" >&2
      exit 2
    fi
    require_workload_owned "$previous"
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
    render
    require_namespace_contract
    previous=$(workload_state)
    require_workload_owned "$previous"
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
    preflight_rendered_resources
    previous=$(workload_state)
    require_workload_owned "$previous" optional
    previous_mode=$(printf '%s' "$previous" | cut -f2)
    previous_cleanup=$(printf '%s' "$previous" | cut -f3)
    delete_rendered_namespaced_resources
    delete_namespace_rbac
    if [ "$DELETE_NAMESPACE" -eq 1 ]; then
      delete_owned_empty_namespace
    fi
    if [ "$DESIRED_RBAC" = cluster-admin ] || [ "$previous_mode" = cluster-admin ] || \
      [ "$previous_cleanup" = required ] || [ -z "$previous" ] || \
      { [ -n "$previous" ] && [ -z "$previous_mode" ]; }; then
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
