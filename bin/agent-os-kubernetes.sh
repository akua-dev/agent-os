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
RENDER_INPUTS=$(mktemp)
CONFIRMED=0
DELETE_NAMESPACE=0
MANAGES_NAMESPACE=0
DESIRED_RBAC=none
INSTALLATION_ID=
OPERATION_ID=${AGENT_OS_OPERATION_ID:-"$(date -u '+%Y%m%d%H%M%S')-$$-$RANDOM"}
LOCK=
LOCK_NAMESPACE=
EXPECTED_LOCK=
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

. "$ROOT/bin/agent-os-kubernetes-lease.sh"

cleanup() {
  local status=$?
  trap - EXIT
  if ! release_lock && [ "$status" -eq 0 ]; then
    status=3
  fi
  rm -rf "$OUT" "$RENDER_INPUTS"
  exit "$status"
}
trap cleanup EXIT
trap lock_renewal_failed TERM

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
case "$OPERATION_ID" in
  ''|*[!a-z0-9.-]*|[.-]*|*[-.]) echo "error: invalid operation id" >&2; exit 2 ;;
esac
[ "${#OPERATION_ID}" -le 63 ] || { echo "error: invalid operation id" >&2; exit 2; }

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
  if grep -Eq '^[[:space:]]*operationId:' "$INPUTS"; then
    echo "error: operationId is reserved for the lifecycle helper" >&2
    exit 2
  fi
  cp "$INPUTS" "$RENDER_INPUTS"
  printf '\noperationId: %s\n' "$OPERATION_ID" >> "$RENDER_INPUTS"
  "$AKUA" render --no-agent-mode --package "$PACKAGE" --inputs "$RENDER_INPUTS" --out "$OUT"
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

rendered_file_for_kind() {
  local desired=$1 file
  while IFS= read -r file; do
    [ "$(rendered_resource_field "$file" kind)" = "$desired" ] && { printf '%s' "$file"; return; }
  done < <(find "$OUT" -type f -name '*.yaml' -print)
}

create_managed_namespace_if_absent() {
  local file identity
  [ "$MANAGES_NAMESPACE" -eq 1 ] || return 0
  [ -z "$(namespace_name)" ] || return 0
  file=$(rendered_file_for_kind Namespace)
  [ -n "$file" ] || { echo "error: managed namespace render is missing" >&2; exit 2; }
  if ! "$KUBECTL" --context "$CONTEXT" create -f "$file" >/dev/null; then
    identity=$(namespace_identity 2>/dev/null || true)
    if [ "$identity" != "agent-os"$'\t'"$INSTALLATION_ID" ]; then
      echo "error: namespace '$NAMESPACE' create conflicted without exact installation ownership" >&2
      exit 2
    fi
  fi
  identity=$(namespace_identity)
  if [ "$identity" != "agent-os"$'\t'"$INSTALLATION_ID" ]; then
    echo "error: namespace '$NAMESPACE' did not retain exact installation ownership" >&2
    exit 2
  fi
}

kube() {
  "$KUBECTL" --context "$CONTEXT" -n "$LOCK_NAMESPACE" "$@"
}

lock_record() {
  kube get lease "$LOCK" --ignore-not-found \
    -o 'jsonpath={.metadata.name}{"\t"}{.metadata.labels.app\.kubernetes\.io/managed-by}{"\t"}{.metadata.labels.agent-os\.dev/lifecycle}{"\t"}{.metadata.annotations.agent-os\.dev/installation-id}{"\t"}{.spec.holderIdentity}{"\t"}{.spec.acquireTime}{"\t"}{.spec.renewTime}{"\t"}{.spec.leaseDurationSeconds}{"\t"}{.metadata.uid}{"\t"}{.metadata.resourceVersion}'
}

render_lock() {
  local acquired_at=$1 renewed_at=$2 uid=${3:-} rv=${4:-} uid_value='' rv_value=''
  [ -z "$uid" ] || uid_value=$(yaml_string "$uid")
  [ -z "$rv" ] || rv_value=$(yaml_string "$rv")
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
    agent-os.dev/installation-id: $INSTALLATION_ID
spec:
  holderIdentity: $OPERATION_ID
  acquireTime: $acquired_at
  renewTime: $renewed_at
  leaseDurationSeconds: $LOCK_DURATION_SECONDS
YAML
}

acquire_primary_lock() {
  if [ -n "$(namespace_name)" ]; then
    LOCK_NAMESPACE=$NAMESPACE
    LOCK=agent-os-firstmate-lifecycle
  elif [ "$COMMAND" = cleanup-cluster-rbac ]; then
    LOCK_NAMESPACE=${AGENT_OS_CLUSTER_LOCK_NAMESPACE:-kube-system}
    LOCK="agent-os-firstmate-lifecycle-$NAMESPACE"
  elif [ "$COMMAND" = uninstall ]; then
    return 0
  else
    echo "error: namespace '$NAMESPACE' is absent after namespace preparation" >&2
    exit 2
  fi
  EXPECTED_LOCK="$LOCK"$'\t'"agent-os"$'\t'"primary"$'\t'"$INSTALLATION_ID"
  acquire_lock
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

live_resource_record() {
  local scope=$1 kind=$2 name=$3
  if [ "$scope" = cluster ]; then
    "$KUBECTL" --context "$CONTEXT" get "$kind" "$name" --ignore-not-found \
      -o 'jsonpath={.metadata.name}{"\t"}{.metadata.labels.app\.kubernetes\.io/managed-by}{"\t"}{.metadata.annotations.agent-os\.dev/installation-id}{"\t"}{.metadata.uid}{"\t"}{.metadata.resourceVersion}{"\t"}{.metadata.labels.agent-os\.dev/operation-id}'
  else
    "$KUBECTL" --context "$CONTEXT" -n "$NAMESPACE" get "$kind" "$name" --ignore-not-found \
      -o 'jsonpath={.metadata.name}{"\t"}{.metadata.labels.app\.kubernetes\.io/managed-by}{"\t"}{.metadata.annotations.agent-os\.dev/installation-id}{"\t"}{.metadata.uid}{"\t"}{.metadata.resourceVersion}{"\t"}{.metadata.labels.agent-os\.dev/operation-id}'
  fi
}

resource_api_path() {
  local scope=$1 kind=$2 name=$3
  case "$kind" in
    Namespace) printf '/api/v1/namespaces/%s' "$name" ;;
    Pod) printf '/api/v1/namespaces/%s/pods/%s' "$NAMESPACE" "$name" ;;
    PersistentVolumeClaim) printf '/api/v1/namespaces/%s/persistentvolumeclaims/%s' "$NAMESPACE" "$name" ;;
    Service) printf '/api/v1/namespaces/%s/services/%s' "$NAMESPACE" "$name" ;;
    ServiceAccount) printf '/api/v1/namespaces/%s/serviceaccounts/%s' "$NAMESPACE" "$name" ;;
    StatefulSet) printf '/apis/apps/v1/namespaces/%s/statefulsets/%s' "$NAMESPACE" "$name" ;;
    Role) printf '/apis/rbac.authorization.k8s.io/v1/namespaces/%s/roles/%s' "$NAMESPACE" "$name" ;;
    RoleBinding) printf '/apis/rbac.authorization.k8s.io/v1/namespaces/%s/rolebindings/%s' "$NAMESPACE" "$name" ;;
    ClusterRoleBinding) printf '/apis/rbac.authorization.k8s.io/v1/clusterrolebindings/%s' "$name" ;;
    *) echo "error: unsupported atomic deletion target $scope $kind/$name" >&2; return 2 ;;
  esac
}

delete_owned_resource() {
  local scope=$1 kind=$2 name=$3 timeout=$4 record expected uid rv path output started elapsed class
  record=$(live_resource_record "$scope" "$kind" "$name")
  [ -n "$record" ] || return 0
  expected="$name"$'\t'"agent-os"$'\t'"$INSTALLATION_ID"
  if [ "$(printf '%s' "$record" | cut -f1-3)" != "$expected" ]; then
    echo "error: $kind '$name' changed ownership before deletion" >&2
    exit 2
  fi
  uid=$(printf '%s' "$record" | cut -f4)
  rv=$(printf '%s' "$record" | cut -f5)
  [ -n "$uid" ] && [ -n "$rv" ] || { echo "error: $kind '$name' lacks deletion preconditions" >&2; exit 2; }
  path=$(resource_api_path "$scope" "$kind" "$name")
  started=$(date -u '+%s')
  if ! output=$(printf '{"apiVersion":"v1","kind":"DeleteOptions","preconditions":{"uid":"%s","resourceVersion":"%s"}}\n' "$uid" "$rv" | \
    "$KUBECTL" --context "$CONTEXT" delete --raw "$path" -f - 2>&1 >/dev/null); then
    elapsed=$(($(date -u '+%s') - started))
    class=$(delete_failure_class "$output")
    bounded_delete_failure "$kind/$name" request "$class" "$timeout" "$elapsed" "$uid"
    return $?
  fi
  if [ "$scope" = cluster ]; then
    if ! output=$("$KUBECTL" --context "$CONTEXT" wait --for=delete "$kind/$name" --timeout="${timeout}s" 2>&1 >/dev/null); then
      elapsed=$(($(date -u '+%s') - started))
      class=$(delete_failure_class "$output")
      bounded_delete_failure "$kind/$name" wait "$class" "$timeout" "$elapsed" "$uid"
    fi
  else
    if ! output=$("$KUBECTL" --context "$CONTEXT" -n "$NAMESPACE" wait --for=delete "$kind/$name" --timeout="${timeout}s" 2>&1 >/dev/null); then
      elapsed=$(($(date -u '+%s') - started))
      class=$(delete_failure_class "$output")
      bounded_delete_failure "$kind/$name" wait "$class" "$timeout" "$elapsed" "$uid"
    fi
  fi
}

patch_workload_annotations() {
  local annotations=$1 record expected uid rv patch current
  record=$(live_resource_record namespaced StatefulSet agent-os-firstmate)
  expected="agent-os-firstmate"$'\t'"agent-os"$'\t'"$INSTALLATION_ID"
  if [ "$(printf '%s' "$record" | cut -f1-3)" != "$expected" ]; then
    echo "error: StatefulSet ownership changed before annotation mutation" >&2
    exit 2
  fi
  uid=$(printf '%s' "$record" | cut -f4)
  rv=$(printf '%s' "$record" | cut -f5)
  [ -n "$uid" ] && [ -n "$rv" ] || { echo "error: StatefulSet lacks annotation CAS identity" >&2; exit 2; }
  patch=$(printf '{"metadata":{"uid":"%s","resourceVersion":"%s","annotations":%s}}' "$uid" "$rv" "$annotations")
  "$KUBECTL" --context "$CONTEXT" -n "$NAMESPACE" patch StatefulSet agent-os-firstmate --type=merge -p "$patch" >/dev/null
  current=$(live_resource_record namespaced StatefulSet agent-os-firstmate)
  if [ "$(printf '%s' "$current" | cut -f1-4)" != "$(printf '%s' "$record" | cut -f1-4)" ]; then
    echo "error: StatefulSet UID or ownership changed during annotation mutation" >&2
    exit 3
  fi
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
  require_namespaced_resource_owned_or_absent Role agent-os-firstmate-runtime
  require_namespaced_resource_owned_or_absent RoleBinding agent-os-firstmate-runtime
}

delete_namespace_rbac() {
  delete_owned_resource namespaced RoleBinding agent-os-firstmate-runtime 180
  delete_owned_resource namespaced Role agent-os-firstmate-runtime 180
}

resource_observation() {
  local scope=$1 kind=$2 name=$3
  if [ "$kind" = StatefulSet ]; then
    "$KUBECTL" --context "$CONTEXT" -n "$NAMESPACE" get "$kind" "$name" --ignore-not-found \
      -o 'jsonpath={.metadata.name}{"\t"}{.metadata.labels.app\.kubernetes\.io/managed-by}{"\t"}{.metadata.annotations.agent-os\.dev/installation-id}{"\t"}{.metadata.uid}{"\t"}{.metadata.labels.agent-os\.dev/operation-id}{"\t"}{"\t"}{.metadata.finalizers}{"\t"}{.spec.replicas}{"\t"}{.status.currentReplicas}{"\t"}{.status.readyReplicas}{"\t"}{.status.updatedReplicas}{"\t"}{.status.availableReplicas}{"\t"}{.status.currentRevision}{"\t"}{.status.updateRevision}{"\t"}{.metadata.generation}{"\t"}{.status.observedGeneration}'
    return
  fi
  if [ "$kind" = Pod ]; then
    "$KUBECTL" --context "$CONTEXT" -n "$NAMESPACE" get "$kind" "$name" --ignore-not-found \
      -o 'jsonpath={.metadata.name}{"\t"}{.metadata.labels.app\.kubernetes\.io/managed-by}{"\t"}{.metadata.annotations.agent-os\.dev/installation-id}{"\t"}{.metadata.uid}{"\t"}{.metadata.labels.agent-os\.dev/operation-id}{"\t"}{range .status.conditions[?(@.type=="Ready")]}{.status}{end}{"\t"}{.metadata.finalizers}{"\t"}{range .status.containerStatuses[*]}{.name}{"="}{.state.waiting.reason}{.state.terminated.reason}{","}{end}'
    return
  fi
  if [ "$scope" = cluster ]; then
    "$KUBECTL" --context "$CONTEXT" get "$kind" "$name" --ignore-not-found \
      -o 'jsonpath={.metadata.name}{"\t"}{.metadata.labels.app\.kubernetes\.io/managed-by}{"\t"}{.metadata.annotations.agent-os\.dev/installation-id}{"\t"}{.metadata.uid}{"\t"}{.metadata.labels.agent-os\.dev/operation-id}{"\t"}{range .status.conditions[?(@.type=="Ready")]}{.status}{end}{"\t"}{.metadata.finalizers}'
  else
    "$KUBECTL" --context "$CONTEXT" -n "$NAMESPACE" get "$kind" "$name" --ignore-not-found \
      -o 'jsonpath={.metadata.name}{"\t"}{.metadata.labels.app\.kubernetes\.io/managed-by}{"\t"}{.metadata.annotations.agent-os\.dev/installation-id}{"\t"}{.metadata.uid}{"\t"}{.metadata.labels.agent-os\.dev/operation-id}{"\t"}{range .status.conditions[?(@.type=="Ready")]}{.status}{end}{"\t"}{.metadata.finalizers}'
  fi
}

lifecycle_command() {
  local action=${1:-$COMMAND}
  printf 'AGENT_OS_CONTEXT=%q AGENT_OS_NAMESPACE=%q AGENT_OS_PACKAGE=%q AGENT_OS_INPUTS=%q AGENT_OS_AKUA=%q AGENT_OS_KUBECTL=%q %q %q' \
    "$CONTEXT" "$NAMESPACE" "$PACKAGE" "$INPUTS" "$AKUA" "$KUBECTL" "$0" "$action"
}

report_partial_observation() {
  local kind=$1 name=$2 scope=$3 record managed installation uid operation ready finalizers prefix details
  if ! record=$(resource_observation "$scope" "$kind" "$name"); then
    echo "partial apply: $kind/$name observation=unavailable expected-operation=$OPERATION_ID" >&2
    return
  fi
  if [ -z "$record" ]; then
    echo "partial apply: $kind/$name observed=absent expected-operation=$OPERATION_ID" >&2
    return
  fi
  managed=$(printf '%s' "$record" | cut -f2)
  installation=$(printf '%s' "$record" | cut -f3)
  uid=$(printf '%s' "$record" | cut -f4)
  operation=$(printf '%s' "$record" | cut -f5)
  ready=$(printf '%s' "$record" | cut -f6)
  finalizers=$(printf '%s' "$record" | cut -f7)
  [ -n "$ready" ] || ready=unknown
  [ -n "$finalizers" ] || finalizers='[]'
  prefix='partial apply'
  [ "$kind" != ClusterRoleBinding ] || prefix='residual-authority'
  details="ready=$ready"
  if [ "$kind" = StatefulSet ]; then
    details="desired=$(printf '%s' "$record" | cut -f8) current=$(printf '%s' "$record" | cut -f9) ready=$(printf '%s' "$record" | cut -f10) updated=$(printf '%s' "$record" | cut -f11) available=$(printf '%s' "$record" | cut -f12) current-revision=$(printf '%s' "$record" | cut -f13) update-revision=$(printf '%s' "$record" | cut -f14) generation=$(printf '%s' "$record" | cut -f15) observed-generation=$(printf '%s' "$record" | cut -f16)"
  elif [ "$kind" = Pod ]; then
    details="ready=$ready reasons=$(printf '%s' "$record" | cut -f8-)"
  fi
  echo "$prefix: $kind/$name uid=$uid operation=$operation $details ownership=$managed installation=$installation finalizers=$finalizers" >&2
}

partial_install_is_applicable() {
  local file kind name identity expected namespace
  if ! namespace=$(namespace_name 2>/dev/null); then
    return 1
  fi
  if [ "$MANAGES_NAMESPACE" -eq 1 ]; then
    if [ -n "$namespace" ]; then
      if ! identity=$(namespace_identity 2>/dev/null); then
        return 1
      fi
      [ "$identity" = "agent-os"$'\t'"$INSTALLATION_ID" ] || return 1
    fi
  else
    [ -n "$namespace" ] || return 1
    if ! identity=$(namespace_identity 2>/dev/null); then
      return 1
    fi
    [ "$identity" = $'\t' ] || return 1
  fi
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    kind=$(rendered_resource_field "$file" kind)
    name=$(rendered_resource_field "$file" name)
    case "$kind" in
      Namespace) continue ;;
      ClusterRoleBinding)
        if ! identity=$("$KUBECTL" --context "$CONTEXT" get clusterrolebinding "$name" --ignore-not-found \
          -o 'jsonpath={.metadata.name}{"\t"}{.metadata.labels.app\.kubernetes\.io/managed-by}{"\t"}{.metadata.annotations.agent-os\.dev/installation-id}' 2>/dev/null); then
          return 1
        fi
        ;;
      *)
        if ! identity=$(live_resource_identity "$kind" "$name" 2>/dev/null); then
          return 1
        fi
        ;;
    esac
    expected="$name"$'\t'"agent-os"$'\t'"$INSTALLATION_ID"
    [ -z "$identity" ] || [ "$identity" = "$expected" ] || return 1
  done < <(find "$OUT" -type f -name '*.yaml' -print)
  for kind in Role RoleBinding; do
    if ! identity=$(live_resource_identity "$kind" agent-os-firstmate-runtime 2>/dev/null); then
      return 1
    fi
    expected="agent-os-firstmate-runtime"$'\t'"agent-os"$'\t'"$INSTALLATION_ID"
    [ -z "$identity" ] || [ "$identity" = "$expected" ] || return 1
  done
  return 0
}

partial_recovery_action() {
  local state identity namespace
  if ! namespace=$(namespace_name 2>/dev/null); then
    return 1
  fi
  state=
  if [ -n "$namespace" ] && ! state=$(workload_state 2>/dev/null); then
    return 1
  fi
  if [ -n "$state" ]; then
    identity=$(printf '%s' "$state" | cut -f1,4,5)
    if [ "$identity" = "agent-os-firstmate"$'\t'"agent-os"$'\t'"$INSTALLATION_ID" ]; then
      if partial_install_is_applicable; then
        printf upgrade
        return
      fi
    fi
    return 1
  fi
  if partial_install_is_applicable; then
    printf install
    return
  fi
  return 1
}

partial_cleanup_is_applicable() {
  local binding workload mode marker identity namespace
  if ! binding=$(resource_observation cluster ClusterRoleBinding "agent-os-firstmate-$NAMESPACE" 2>/dev/null); then
    return 1
  fi
  [ -n "$binding" ] || return 1
  identity=$(printf '%s' "$binding" | cut -f2,3)
  [ "$identity" = "agent-os"$'\t'"$INSTALLATION_ID" ] || return 1
  if ! namespace=$(namespace_name 2>/dev/null); then
    return 1
  fi
  [ -n "$namespace" ] || return 0
  if ! workload=$(workload_state 2>/dev/null); then
    return 1
  fi
  [ -n "$workload" ] || return 0
  identity=$(printf '%s' "$workload" | cut -f1,4,5)
  [ "$identity" = "agent-os-firstmate"$'\t'"agent-os"$'\t'"$INSTALLATION_ID" ] || return 1
  mode=$(printf '%s' "$workload" | cut -f2)
  marker=$(printf '%s' "$workload" | cut -f3)
  [ "$mode" != cluster-admin ] && [ "$marker" = required ]
}

report_partial_apply() {
  local phase=$1 file kind name scope recovery
  echo "incomplete: primary $phase failed; automatic cleanup withheld pending exact recovery" >&2
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    kind=$(rendered_resource_field "$file" kind)
    name=$(rendered_resource_field "$file" name)
    scope=namespaced
    case "$kind" in
      ClusterRoleBinding) continue ;;
      Namespace) scope=cluster ;;
    esac
    report_partial_observation "$kind" "$name" "$scope"
  done < <(find "$OUT" -type f -name '*.yaml' -print)
  report_partial_observation Pod agent-os-firstmate-0 namespaced
  report_partial_observation ClusterRoleBinding "agent-os-firstmate-$NAMESPACE" cluster
  if recovery=$(partial_recovery_action); then
    echo "safe recovery: $(lifecycle_command "$recovery")" >&2
  else
    echo "safe recovery unavailable: workload ownership changed; inspect retained resources" >&2
  fi
  if partial_cleanup_is_applicable; then
    echo "privileged cleanup with proven predicates: $(cleanup_command)" >&2
  else
    echo "privileged cleanup unavailable: stale-grant predicates are not proven" >&2
  fi
  return 3
}

cas_patch_file() {
  local file=$1 uid=$2 rv=$3 patch_file uid_value rv_value
  patch_file=$(mktemp "$OUT/cas.XXXXXX")
  uid_value=$(yaml_string "$uid")
  rv_value=$(yaml_string "$rv")
  awk -v uid="$uid_value" -v rv="$rv_value" '
    !inserted && $1 == "metadata:" {
      print
      print "  uid: " uid
      print "  resourceVersion: " rv
      inserted=1
      next
    }
    { print }
  ' "$file" > "$patch_file"
  printf '%s' "$patch_file"
}

mutate_rendered_resource() {
  local file=$1 kind name scope record expected uid rv operation current patch_file
  kind=$(rendered_resource_field "$file" kind)
  name=$(rendered_resource_field "$file" name)
  [ "$kind" != Namespace ] || return 0
  scope=namespaced
  [ "$kind" != ClusterRoleBinding ] || scope=cluster
  record=$(live_resource_record "$scope" "$kind" "$name")
  expected="$name"$'\t'"agent-os"$'\t'"$INSTALLATION_ID"
  if [ -z "$record" ]; then
    if ! "$KUBECTL" --context "$CONTEXT" create -f "$file" >/dev/null; then
      current=$(live_resource_record "$scope" "$kind" "$name" 2>/dev/null || true)
      if [ "$(printf '%s' "$current" | cut -f1-3)" != "$expected" ] || \
        [ "$(printf '%s' "$current" | cut -f6)" != "$OPERATION_ID" ]; then
        report_partial_apply create
        return $?
      fi
    fi
  else
    if [ "$(printf '%s' "$record" | cut -f1-3)" != "$expected" ]; then
      echo "error: $kind '$name' changed ownership before mutation" >&2
      exit 2
    fi
    uid=$(printf '%s' "$record" | cut -f4)
    rv=$(printf '%s' "$record" | cut -f5)
    [ -n "$uid" ] && [ -n "$rv" ] || { echo "error: $kind '$name' lacks CAS identity" >&2; exit 2; }
    patch_file=$(cas_patch_file "$file" "$uid" "$rv")
    if [ "$scope" = cluster ]; then
      if ! "$KUBECTL" --context "$CONTEXT" patch "$kind" "$name" --type=merge --patch-file "$patch_file" >/dev/null; then
        report_partial_apply patch
        return $?
      fi
    else
      if ! "$KUBECTL" --context "$CONTEXT" -n "$NAMESPACE" patch "$kind" "$name" --type=merge --patch-file "$patch_file" >/dev/null; then
        report_partial_apply patch
        return $?
      fi
    fi
  fi
  current=$(live_resource_record "$scope" "$kind" "$name")
  operation=$(printf '%s' "$current" | cut -f6)
  if [ "$(printf '%s' "$current" | cut -f1-3)" != "$expected" ] || [ -z "$(printf '%s' "$current" | cut -f4)" ] || \
    [ "$operation" != "$OPERATION_ID" ]; then
    report_partial_apply verify
    return $?
  fi
  if [ -n "$record" ] && [ "$(printf '%s' "$current" | cut -f4)" != "$(printf '%s' "$record" | cut -f4)" ]; then
    echo "error: $kind '$name' UID changed during mutation" >&2
    exit 3
  fi
}

apply_rendered() {
  local file
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    mutate_rendered_resource "$file" || return $?
  done < <(find "$OUT" -type f -name '*.yaml' -print)
  if ! "$KUBECTL" --context "$CONTEXT" -n "$NAMESPACE" rollout status \
    statefulset/agent-os-firstmate --timeout=180s; then
    report_partial_apply rollout
  fi
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
        {"apiGroups":["apps"],"resources":["statefulsets"],"verbs":["get","list","watch"]},
        {"apiGroups":["coordination.k8s.io"],"resources":["leases"],"verbs":["get","create","update","delete"]}
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

uninstall_command() {
  printf 'AGENT_OS_CONTEXT=%q AGENT_OS_NAMESPACE=%q AGENT_OS_PACKAGE=%q AGENT_OS_INPUTS=%q AGENT_OS_AKUA=%q AGENT_OS_KUBECTL=%q %q uninstall --yes' \
    "$CONTEXT" "$NAMESPACE" "$PACKAGE" "$INPUTS" "$AKUA" "$KUBECTL" "$0"
  [ "$DELETE_NAMESPACE" -eq 0 ] || printf ' --delete-namespace'
}

report_retained_observation() {
  local kind=$1 name=$2 scope=$3 record managed installation uid operation ready finalizers identity expected details
  if ! record=$(resource_observation "$scope" "$kind" "$name"); then
    echo "retained-unverified: $kind/$name could not be inspected; no further deletion attempted" >&2
    return 0
  fi
  [ -n "$record" ] || return 0
  managed=$(printf '%s' "$record" | cut -f2)
  installation=$(printf '%s' "$record" | cut -f3)
  uid=$(printf '%s' "$record" | cut -f4)
  operation=$(printf '%s' "$record" | cut -f5)
  ready=$(printf '%s' "$record" | cut -f6)
  finalizers=$(printf '%s' "$record" | cut -f7)
  identity="$managed"$'\t'"$installation"
  expected="agent-os"$'\t'"$INSTALLATION_ID"
  [ -n "$ready" ] || ready=unknown
  [ -n "$finalizers" ] || finalizers='[]'
  details="ready=$ready"
  if [ "$kind" = StatefulSet ]; then
    details="desired=$(printf '%s' "$record" | cut -f8) current=$(printf '%s' "$record" | cut -f9) ready=$(printf '%s' "$record" | cut -f10) updated=$(printf '%s' "$record" | cut -f11) available=$(printf '%s' "$record" | cut -f12) current-revision=$(printf '%s' "$record" | cut -f13) update-revision=$(printf '%s' "$record" | cut -f14) generation=$(printf '%s' "$record" | cut -f15) observed-generation=$(printf '%s' "$record" | cut -f16)"
  elif [ "$kind" = Pod ]; then
    details="ready=$ready reasons=$(printf '%s' "$record" | cut -f8-)"
  fi
  if [ "$identity" = "$expected" ]; then
    echo "retained: $kind/$name uid=$uid operation=$operation $details ownership=$managed installation=$installation finalizers=$finalizers" >&2
  else
    echo "retained-unverified: $kind/$name uid=$uid operation=$operation ownership=$managed installation=$installation; no further deletion attempted" >&2
  fi
}

report_retained_resources() {
  local failed_target=$1 phase=$2 class=$3 timeout=$4 elapsed=$5 uid=$6 file kind name scope
  echo "failed-target: $failed_target uid=$uid delete-${phase}-failure=$class timeout=${timeout}s elapsed=${elapsed}s" >&2
  kind=${failed_target%%/*}
  name=${failed_target#*/}
  scope=namespaced
  [ "$kind" != Namespace ] || scope=cluster
  report_retained_observation "$kind" "$name" "$scope"
  report_retained_observation Pod agent-os-firstmate-0 namespaced
  report_retained_observation Role agent-os-firstmate-runtime namespaced
  report_retained_observation RoleBinding agent-os-firstmate-runtime namespaced
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    kind=$(rendered_resource_field "$file" kind)
    name=$(rendered_resource_field "$file" name)
    case "$kind" in
      ClusterRoleBinding) continue ;;
      Namespace)
        [ "$DELETE_NAMESPACE" -eq 1 ] || continue
        scope=cluster
        ;;
      *) scope=namespaced ;;
    esac
    report_retained_observation "$kind" "$name" "$scope"
  done < <(find "$OUT" -type f -name '*.yaml' -print)
  echo "safe retry: $(uninstall_command)" >&2
  echo "cluster cleanup if required: $(cleanup_command)" >&2
}

delete_failure_class() {
  local output
  output=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$output" in
    *forbidden*) printf 'Forbidden' ;;
    *conflict*) printf 'Conflict' ;;
    *notfound*|*'not found'*) printf 'NotFound' ;;
    *'timed out'*|*timeout*) printf 'timeout' ;;
    *) printf 'transport' ;;
  esac
}

bounded_delete_failure() {
  local target=$1 phase=${2:-wait} class=${3:-timeout} timeout=${4:-180}
  local elapsed=${5:-$timeout} uid=${6:-unknown} prefix kind name scope
  [ "$COMMAND" = uninstall ] && prefix=incomplete || prefix=error
  echo "$prefix: delete-${phase}-failure=$class target=$target uid=$uid timeout=${timeout}s elapsed=${elapsed}s" >&2
  if [ "$COMMAND" = uninstall ]; then
    report_retained_resources "$target" "$phase" "$class" "$timeout" "$elapsed" "$uid"
    return 3
  fi
  kind=${target%%/*}
  name=${target#*/}
  scope=namespaced
  case "$kind" in
    ClusterRoleBinding|Namespace) scope=cluster ;;
  esac
  report_retained_observation "$kind" "$name" "$scope"
  if [ "$COMMAND" = cleanup-cluster-rbac ]; then
    echo "safe retry: $(cleanup_command)" >&2
  fi
  return 1
}

delete_rendered_kind() {
  local desired_kind=$1 file kind name
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    kind=$(rendered_resource_field "$file" kind)
    if [ "$kind" = "$desired_kind" ]; then
      name=$(rendered_resource_field "$file" name)
      delete_owned_resource namespaced "$kind" "$name" 180
    fi
  done < <(find "$OUT" -type f -name '*.yaml' -print)
}

delete_rendered_namespaced_resources() {
  local kind output started elapsed class
  delete_rendered_kind StatefulSet
  started=$(date -u '+%s')
  if ! output=$("$KUBECTL" --context "$CONTEXT" -n "$NAMESPACE" wait \
    --for=delete pod/agent-os-firstmate-0 --timeout=180s 2>&1 >/dev/null); then
    elapsed=$(($(date -u '+%s') - started))
    class=$(delete_failure_class "$output")
    bounded_delete_failure Pod/agent-os-firstmate-0 wait "$class" 180 "$elapsed" unknown
  fi
  for kind in Service RoleBinding Role ServiceAccount; do
    delete_rendered_kind "$kind"
  done
  delete_rendered_kind PersistentVolumeClaim
}

namespace_is_empty() {
  local resources resource objects object lock
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
        lease/agent-os-firstmate-lifecycle|lease.coordination.k8s.io/agent-os-firstmate-lifecycle)
          lock=$(lock_record 2>/dev/null || true)
          if ! verify_lock_record "$lock" || [ "$(printf '%s' "$lock" | cut -f9)" != "$LOCK_UID" ]; then
            echo "error: namespace '$NAMESPACE' contains an unverified lifecycle Lease" >&2
            return 1
          fi
          ;;
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
  stop_lock_renewal
  delete_owned_resource cluster Namespace "$NAMESPACE" 180
  LOCK_UID=
  LOCK_RV=
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
    delete_owned_resource cluster ClusterRoleBinding "$binding" 60
  fi
  if [ -n "$(namespace_name)" ]; then
    workload=$(workload_state)
    require_workload_owned "$workload" optional
    if [ -n "$workload" ] && [ "$(printf '%s' "$workload" | cut -f3)" = required ]; then
      patch_workload_annotations '{"agent-os.dev/cluster-rbac-cleanup":null}'
    fi
  fi
  echo "evidence: clusterrolebinding/$binding absent"
}

case "$COMMAND" in
  install)
    [ "$CONFIRMED" -eq 0 ] && [ "$DELETE_NAMESPACE" -eq 0 ] || usage
    render
    require_namespace_contract
    create_managed_namespace_if_absent
    acquire_primary_lock
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
    acquire_primary_lock
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
      patch_workload_annotations '{"agent-os.dev/cluster-rbac-cleanup":"required"}'
    fi
    apply_rendered
    verify_desired_rbac
    if [ "$DESIRED_RBAC" != namespace ]; then
      delete_namespace_rbac
    fi
    if [ "$DESIRED_RBAC" = cluster-admin ] && [ "$previous_cleanup" = required ]; then
      patch_workload_annotations '{"agent-os.dev/cluster-rbac-cleanup":null}'
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
    acquire_primary_lock
    require_namespace_contract
    preflight_rendered_resources 1
    previous=$(workload_state)
    require_workload_owned "$previous"
    if ! command -v jq >/dev/null 2>&1; then
      echo "error: jq is required to resolve StatefulSet revision history safely" >&2
      exit 2
    fi
    rollback_record=$(live_resource_record namespaced StatefulSet agent-os-firstmate)
    rollback_uid=$(printf '%s' "$rollback_record" | cut -f4)
    rollback_rv=$(printf '%s' "$rollback_record" | cut -f5)
    if [ "$(printf '%s' "$rollback_record" | cut -f1-3)" != \
      "agent-os-firstmate"$'\t'"agent-os"$'\t'"$INSTALLATION_ID" ] || \
      [ -z "$rollback_uid" ] || [ -z "$rollback_rv" ]; then
      echo "error: rollback requires exact StatefulSet UID and resourceVersion evidence" >&2
      exit 2
    fi
    rollback_state=$("$KUBECTL" --context "$CONTEXT" -n "$NAMESPACE" get statefulset agent-os-firstmate -o json)
    rollback_revisions=$("$KUBECTL" --context "$CONTEXT" -n "$NAMESPACE" get controllerrevisions.apps -o json)
    rollback_references=$(printf '%s' "$rollback_state" | jq -er \
      --arg uid "$rollback_uid" --arg rv "$rollback_rv" --arg installation "$INSTALLATION_ID" '
        select(.metadata.name == "agent-os-firstmate")
        | select(.metadata.uid == $uid and .metadata.resourceVersion == $rv)
        | select(.metadata.labels["app.kubernetes.io/managed-by"] == "agent-os")
        | select(.metadata.annotations["agent-os.dev/installation-id"] == $installation)
        | [.status.currentRevision, .status.updateRevision]
        | select(all(.[]; type == "string" and length > 0))
        | @tsv
      ') || { echo "error: StatefulSet changed before rollback revision resolution" >&2; exit 3; }
    rollback_current_revision=$(printf '%s' "$rollback_references" | cut -f1)
    rollback_update_revision=$(printf '%s' "$rollback_references" | cut -f2)
    rollback_patch=$(printf '%s' "$rollback_revisions" | jq -ce \
      --arg current "$rollback_current_revision" --arg update "$rollback_update_revision" \
      --arg uid "$rollback_uid" --arg rv "$rollback_rv" '
        def owned:
          any(.metadata.ownerReferences[]?;
            .apiVersion == "apps/v1" and .kind == "StatefulSet" and
            .name == "agent-os-firstmate" and .uid == $uid and .controller == true);
        [.items[] | select(owned)] as $owned
        | ($owned | map(select(.metadata.name == $current))) as $current_items
        | ($owned | map(select(.metadata.name == $update))) as $update_items
        | select($current_items | length == 1)
        | select($update_items | length == 1)
        | $current_items[0] as $current_revision
        | $update_items[0] as $update_revision
        | select($update_revision.revision | type == "number")
        | (if $current != $update then
             $current_revision
           else
             ($owned | map(select((.revision | type) == "number" and .revision < $update_revision.revision)) | sort_by(.revision) | last)
           end) as $target
        | select($target != null and ($target.data | type) == "object")
        | $target.data * {metadata:{uid:$uid,resourceVersion:$rv}}
      ') || { echo "error: no exact-owned previous ControllerRevision is available for rollback" >&2; exit 2; }
    if ! "$KUBECTL" --context "$CONTEXT" -n "$NAMESPACE" patch StatefulSet agent-os-firstmate \
      --type=strategic -p "$rollback_patch" >/dev/null; then
      echo "error: StatefulSet rollback CAS conflicted; no rollout-undo fallback attempted" >&2
      exit 3
    fi
    rollback_current=$(live_resource_record namespaced StatefulSet agent-os-firstmate)
    if [ "$(printf '%s' "$rollback_current" | cut -f1-4)" != \
      "$(printf '%s' "$rollback_record" | cut -f1-4)" ]; then
      echo "error: StatefulSet UID or ownership changed during rollback" >&2
      exit 3
    fi
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
    acquire_primary_lock
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
    acquire_primary_lock
    preflight_rendered_resources 1
    cleanup_cluster_rbac
    ;;
  *) usage ;;
esac
