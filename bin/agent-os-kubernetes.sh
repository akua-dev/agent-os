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
LEGACY_CLUSTER_BINDING_PRESENT=0
PRESERVED_AKUA_SECRET_RECORD=
AKUA_OVERLAY_VERIFIED=0
OPERATION_ID=${AGENT_OS_OPERATION_ID:-"$(date -u '+%Y%m%d%H%M%S')-$$-$RANDOM"}
LOCK_NONCE=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
LOCK_HOLDER_ID="$OPERATION_ID.$LOCK_NONCE"
SERVICE_ACCOUNT_NAME="agent-os-firstmate-${LOCK_NONCE:0:12}"
LOCK=
LOCK_NAMESPACE=
EXPECTED_LOCK=
LOCK_UID=
LOCK_RV=
LOCK_RENEW_PID=
LOCK_PERSISTENT=0
CONTROL_LOCK_UID=
CONTROL_LOCK_RV=
CONTROL_LOCK_RENEW_PID=
CONTROL_LOCK_VALID_UNTIL=
REMOVE_CONTROL_ACCESS=0
STATEFULSET_CAS_ATTEMPTED=0
LOCK_DURATION_SECONDS=${AGENT_OS_LOCK_DURATION_SECONDS:-300}
LOCK_CLOCK_SKEW_SECONDS=${AGENT_OS_LOCK_CLOCK_SKEW_SECONDS:-5}
LOCK_ACQUIRE_SECONDS=${AGENT_OS_LOCK_ACQUIRE_SECONDS:-30}
LOCK_REQUEST_CEILING_SECONDS=${AGENT_OS_LOCK_REQUEST_CEILING_SECONDS:-5}
RESOURCE_REQUEST_CEILING_SECONDS=${AGENT_OS_RESOURCE_REQUEST_CEILING_SECONDS:-5}

for seconds in "$LOCK_DURATION_SECONDS" "$LOCK_CLOCK_SKEW_SECONDS" "$LOCK_ACQUIRE_SECONDS" "$LOCK_REQUEST_CEILING_SECONDS" "$RESOURCE_REQUEST_CEILING_SECONDS"; do
  case "$seconds" in ''|*[!0-9]*) echo "error: lifecycle Lease timing must use whole seconds" >&2; exit 2 ;; esac
done
[ "$LOCK_DURATION_SECONDS" -ge 3 ] || { echo "error: lifecycle Lease duration must be at least 3 seconds" >&2; exit 2; }
[ "$LOCK_ACQUIRE_SECONDS" -ge 1 ] || { echo "error: lifecycle Lease acquisition must allow at least 1 second" >&2; exit 2; }
[ "$LOCK_REQUEST_CEILING_SECONDS" -ge 1 ] || { echo "error: lifecycle Lease request ceiling must be at least 1 second" >&2; exit 2; }
[ "$RESOURCE_REQUEST_CEILING_SECONDS" -ge 1 ] || { echo "error: resource request ceiling must be at least 1 second" >&2; exit 2; }

. "$ROOT/bin/agent-os-kubernetes-control.sh"
. "$ROOT/bin/agent-os-kubernetes-lease.sh"

cleanup() {
  local status=$?
  trap - EXIT
  if ! release_primary_locks && [ "$status" -eq 0 ]; then
    status=3
  fi
  if [ "$REMOVE_CONTROL_ACCESS" -eq 1 ] && ! delete_control_lock_access && [ "$status" -eq 0 ]; then
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
  if grep -Eq '^[[:space:]]*(operationId|serviceAccountName):' "$INPUTS"; then
    echo "error: operationId and serviceAccountName are reserved for the lifecycle helper" >&2
    exit 2
  fi
  cp "$INPUTS" "$RENDER_INPUTS"
  printf '\noperationId: %s\nserviceAccountName: %s\n' "$OPERATION_ID" "$SERVICE_ACCOUNT_NAME" >> "$RENDER_INPUTS"
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
  case "$NAMESPACE" in ''|*[!a-z0-9-]*|-*|*-) echo "error: rendered namespace is not a valid Kubernetes DNS label" >&2; exit 2 ;; esac
  [ "${#NAMESPACE}" -le 63 ] || { echo "error: rendered namespace is too long" >&2; exit 2; }
  [ "${#SERVICE_ACCOUNT_NAME}" -le 63 ] || { echo "error: generated ServiceAccount name is too long" >&2; exit 2; }
  [ "${#LOCK_HOLDER_ID}" -le 255 ] || { echo "error: generated lifecycle Lease holder identity is too long" >&2; exit 2; }
  [ "${#NAMESPACE}" -le 231 ] || { echo "error: namespace makes the ClusterRoleBinding name too long" >&2; exit 2; }
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
  local deadline=${1:-}
  [ -n "$deadline" ] || deadline=$(lock_default_deadline)
  lock_kube "$deadline" get lease "$LOCK" --ignore-not-found \
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
    agent-os.dev/installation-id: ${LOCK_INSTALLATION_ID:-$INSTALLATION_ID}
spec:
  holderIdentity: $LOCK_HOLDER_ID
  acquireTime: $acquired_at
  renewTime: $renewed_at
  leaseDurationSeconds: $LOCK_DURATION_SECONDS
YAML
}

acquire_primary_lock() {
  configure_control_lock
  LOCK_NAMESPACE=$CONTROL_NAMESPACE
  LOCK=$CONTROL_LOCK
  LOCK_INSTALLATION_ID=$CONTROL_LOCK_INSTALLATION_ID
  LOCK_PERSISTENT=1
  EXPECTED_LOCK="$LOCK"$'\t'"agent-os"$'\t'"primary"$'\t'"$LOCK_INSTALLATION_ID"
  acquire_lock
  CONTROL_LOCK_UID=$LOCK_UID
  CONTROL_LOCK_RV=$LOCK_RV
  CONTROL_LOCK_RENEW_PID=$LOCK_RENEW_PID
  CONTROL_LOCK_VALID_UNTIL=$LOCK_VALID_UNTIL
  if [ -n "$(namespace_name)" ]; then
    acquire_namespace_lock
  fi
}

acquire_namespace_lock() {
  [ -z "${NAMESPACE_LOCK_UID:-}" ] || return 0
  LOCK_NAMESPACE=$NAMESPACE
  LOCK=agent-os-firstmate-lifecycle
  LOCK_INSTALLATION_ID=$INSTALLATION_ID
  EXPECTED_LOCK="$LOCK"$'\t'"agent-os"$'\t'"primary"$'\t'"$INSTALLATION_ID"
  LOCK_UID=
  LOCK_RV=
  LOCK_RENEW_PID=
  LOCK_VALID_UNTIL=
  LOCK_PERSISTENT=0
  acquire_lock
  NAMESPACE_LOCK_UID=$LOCK_UID
}

release_primary_locks() {
  local status=0
  if [ -n "${NAMESPACE_LOCK_UID:-}" ]; then
    release_lock || status=$?
    NAMESPACE_LOCK_UID=
  fi
  if [ -n "$CONTROL_LOCK_UID" ]; then
    LOCK_NAMESPACE=$CONTROL_NAMESPACE
    LOCK=$CONTROL_LOCK
    LOCK_INSTALLATION_ID=$CONTROL_LOCK_INSTALLATION_ID
    EXPECTED_LOCK="$LOCK"$'\t'"agent-os"$'\t'"primary"$'\t'"$LOCK_INSTALLATION_ID"
    LOCK_UID=$CONTROL_LOCK_UID
    LOCK_RV=$CONTROL_LOCK_RV
    LOCK_RENEW_PID=$CONTROL_LOCK_RENEW_PID
    LOCK_VALID_UNTIL=$CONTROL_LOCK_VALID_UNTIL
    LOCK_PERSISTENT=1
    release_lock || status=$?
    CONTROL_LOCK_UID=
  fi
  return "$status"
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

workload_service_account() {
  local state account identity
  state=$("$KUBECTL" --context "$CONTEXT" -n "$NAMESPACE" \
    --request-timeout="${RESOURCE_REQUEST_CEILING_SECONDS}s" get statefulset agent-os-firstmate -o json)
  identity=$(printf '%s' "$state" | jq -er --arg installation "$INSTALLATION_ID" '
    select(.metadata.name == "agent-os-firstmate")
    | select(.metadata.labels["app.kubernetes.io/managed-by"] == "agent-os")
    | select(.metadata.annotations["agent-os.dev/installation-id"] == $installation)
    | .spec.template.spec.serviceAccountName') || {
    echo "error: StatefulSet ServiceAccount identity is unverifiable" >&2
    exit 3
  }
  case "$identity" in agent-os-firstmate|agent-os-firstmate-[a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9]) ;; *) echo "error: StatefulSet ServiceAccount identity is invalid" >&2; exit 3 ;; esac
  printf '%s' "$identity"
}

preflight_legacy_cluster_binding() {
  local allow_owned=${1:-0} binding identity expected
  binding="agent-os-firstmate-$NAMESPACE"
  if ! identity=$("$KUBECTL" --context "$CONTEXT" get clusterrolebinding "$binding" --ignore-not-found \
    -o 'jsonpath={.metadata.name}{"\t"}{.metadata.labels.app\.kubernetes\.io/managed-by}{"\t"}{.metadata.annotations.agent-os\.dev/installation-id}'); then
    echo "error: exact legacy ClusterRoleBinding preflight requires separately authorized cluster-scoped read access" >&2
    exit 2
  fi
  expected="$binding"$'\t'"agent-os"$'\t'"$INSTALLATION_ID"
  if [ -n "$identity" ] && [ "$identity" != "$expected" ]; then
    echo "error: ClusterRoleBinding '$binding' does not have the exact Agent OS installation identity" >&2
    exit 2
  fi
  [ -z "$identity" ] || LEGACY_CLUSTER_BINDING_PRESENT=1
  if [ -n "$identity" ] && [ "$allow_owned" -ne 1 ] && [ "$DESIRED_RBAC" != cluster-admin ]; then
    echo "error: stale ClusterRoleBinding '$binding' must be removed through separately authorized cleanup before installation" >&2
    exit 3
  fi
}

verify_revision_service_account() {
  local revision=$1 account identity expected record
  account=$(printf '%s' "$revision" | jq -er '.data.spec.template.spec.serviceAccountName') || {
    echo "error: rollback target ServiceAccount dependency is unavailable" >&2
    exit 3
  }
  case "$account" in agent-os-firstmate|agent-os-firstmate-[a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9]) ;; *) echo "error: rollback target ServiceAccount dependency is invalid" >&2; exit 3 ;; esac
  identity=$(live_resource_identity ServiceAccount "$account")
  expected="$account"$'\t'"agent-os"$'\t'"$INSTALLATION_ID"
  [ "$identity" = "$expected" ] || {
    echo "error: rollback target ServiceAccount dependency is missing or changed" >&2
    exit 3
  }
  record=$(live_resource_record namespaced ServiceAccount "$account")
  [ "$(printf '%s' "$record" | cut -f1-3)" = "$expected" ] && \
    [ -n "$(printf '%s' "$record" | cut -f4)" ] && [ -n "$(printf '%s' "$record" | cut -f5)" ] || {
    echo "error: rollback target ServiceAccount dependency metadata is unavailable" >&2
    exit 3
  }
}

runtime_binding_json() {
  local mode=$1
  case "$mode" in
    namespace) "$KUBECTL" --context "$CONTEXT" -n "$NAMESPACE" get rolebinding agent-os-firstmate-runtime -o json ;;
    cluster-admin) "$KUBECTL" --context "$CONTEXT" get clusterrolebinding "agent-os-firstmate-$NAMESPACE" -o json ;;
    none) printf '{}' ;;
    *) echo "error: rollback runtime authority mode is invalid" >&2; return 3 ;;
  esac
}

verify_runtime_role_rules() {
  local json
  json=$("$KUBECTL" --context "$CONTEXT" -n "$NAMESPACE" get role agent-os-firstmate-runtime -o json) || return 3
  printf '%s' "$json" | jq -e --arg installation "$INSTALLATION_ID" '
    .metadata.name == "agent-os-firstmate-runtime" and
    .metadata.labels["app.kubernetes.io/managed-by"] == "agent-os" and
    .metadata.annotations["agent-os.dev/installation-id"] == $installation and
    .rules == [
      {"apiGroups":[""],"resources":["pods","persistentvolumeclaims"],"verbs":["get","list","watch","create","delete","patch"]},
      {"apiGroups":[""],"resources":["pods/log","pods/exec"],"verbs":["get","list","watch","create","delete"]},
      {"apiGroups":["apps"],"resources":["statefulsets"],"verbs":["get","list","watch"]},
      {"apiGroups":["coordination.k8s.io"],"resources":["leases"],"verbs":["get","create","update","delete"]}
    ]' >/dev/null
}

verify_control_role_rules() {
  local json
  json=$("$KUBECTL" --context "$CONTEXT" -n "$CONTROL_NAMESPACE" get role "$CONTROL_LOCK" -o json) || return 3
  printf '%s' "$json" | jq -e --arg installation "$INSTALLATION_ID" --arg name "$CONTROL_LOCK" '
    .metadata.name == $name and
    .metadata.labels["app.kubernetes.io/managed-by"] == "agent-os" and
    .metadata.annotations["agent-os.dev/installation-id"] == $installation and
    .rules == [{apiGroups:["coordination.k8s.io"],resources:["leases"],resourceNames:[$name],verbs:["get","update"]}]' >/dev/null
}

verify_control_authority() {
  local account=$1 json
  verify_control_role_rules || return 3
  json=$(control_binding_json) || return 3
  printf '%s' "$json" | jq -e --arg installation "$INSTALLATION_ID" --arg namespace "$NAMESPACE" \
    --arg name "$CONTROL_LOCK" --arg account "$account" '
    .metadata.name == $name and .metadata.labels["app.kubernetes.io/managed-by"] == "agent-os" and
    .metadata.annotations["agent-os.dev/installation-id"] == $installation and
    .roleRef == {apiGroup:"rbac.authorization.k8s.io",kind:"Role",name:$name} and
    .subjects == [{kind:"ServiceAccount",name:$account,namespace:$namespace}]' >/dev/null
}

verify_no_runtime_authority() {
  local resource
  resource=$("$KUBECTL" --context "$CONTEXT" -n "$NAMESPACE" get rolebinding agent-os-firstmate-runtime --ignore-not-found -o name) || return 3
  [ -z "$resource" ] || return 3
  resource=$("$KUBECTL" --context "$CONTEXT" get clusterrolebinding "agent-os-firstmate-$NAMESPACE" --ignore-not-found -o name) || return 3
  [ -z "$resource" ] || return 3
  resource=$("$KUBECTL" --context "$CONTEXT" -n "$CONTROL_NAMESPACE" get rolebinding "$CONTROL_LOCK" --ignore-not-found -o name) || return 3
  [ -z "$resource" ] || return 3
  resource=$("$KUBECTL" --context "$CONTEXT" -n "$CONTROL_NAMESPACE" get role "$CONTROL_LOCK" --ignore-not-found -o name) || return 3
  [ -z "$resource" ]
}

transfer_runtime_authority() {
  local mode=$1 from=$2 to=$3 binding kind scope json uid rv current patch verified
  if [ "$mode" = none ]; then
    verify_no_runtime_authority || { echo "error: rollback none-mode authority is not absent" >&2; return 3; }
    return 0
  fi
  if [ "$mode" = namespace ]; then
    binding=agent-os-firstmate-runtime
    kind=rolebinding
    scope=(-n "$NAMESPACE")
    verify_runtime_role_rules || { echo "error: rollback runtime Role rules are unverifiable" >&2; return 3; }
    verify_control_role_rules || { echo "error: rollback control Role rules are unverifiable" >&2; return 3; }
  else
    binding="agent-os-firstmate-$NAMESPACE"
    kind=clusterrolebinding
    scope=()
  fi
  json=$(runtime_binding_json "$mode") || return 3
  if [ "$mode" = namespace ]; then
    printf '%s' "$json" | jq -e '.roleRef == {apiGroup:"rbac.authorization.k8s.io",kind:"Role",name:"agent-os-firstmate-runtime"}' >/dev/null || return 3
  else
    printf '%s' "$json" | jq -e '.roleRef == {apiGroup:"rbac.authorization.k8s.io",kind:"ClusterRole",name:"cluster-admin"}' >/dev/null || return 3
  fi
  current=$(printf '%s' "$json" | jq -er --arg installation "$INSTALLATION_ID" --arg namespace "$NAMESPACE" --arg binding "$binding" '
    select(.metadata.name == $binding)
    | select(.metadata.labels["app.kubernetes.io/managed-by"] == "agent-os")
    | select(.metadata.annotations["agent-os.dev/installation-id"] == $installation)
    | select(.subjects | type == "array" and length == 1)
    | select(.subjects[0].kind == "ServiceAccount" and .subjects[0].namespace == $namespace)
    | .subjects[0].name') || { echo "error: rollback runtime authority ownership is unverifiable" >&2; return 3; }
  if [ "$current" = "$to" ]; then
    if [ "$mode" = namespace ]; then
      transfer_control_authority "$from" "$to" || return 3
      verify_runtime_role_rules || return 3
      verify_control_authority "$to" || return 3
    fi
    return 0
  fi
  [ "$current" = "$from" ] || { echo "error: rollback runtime authority is assigned to an unexpected ServiceAccount" >&2; return 3; }
  uid=$(printf '%s' "$json" | jq -er '.metadata.uid') || return 3
  rv=$(printf '%s' "$json" | jq -er '.metadata.resourceVersion') || return 3
  patch=$(jq -cn --arg uid "$uid" --arg rv "$rv" --arg namespace "$NAMESPACE" --arg account "$to" \
    '{metadata:{uid:$uid,resourceVersion:$rv},subjects:[{kind:"ServiceAccount",name:$account,namespace:$namespace}]}')
  "$KUBECTL" --context "$CONTEXT" "${scope[@]}" patch "$kind" "$binding" --type=merge -p "$patch" >/dev/null || return 3
  verified=$(runtime_binding_json "$mode") || return 3
  printf '%s' "$verified" | jq -e --arg uid "$uid" --arg namespace "$NAMESPACE" --arg account "$to" '
    .metadata.uid == $uid and .subjects == [{kind:"ServiceAccount",name:$account,namespace:$namespace}]' >/dev/null || {
    echo "error: rollback runtime authority transfer did not verify exactly" >&2
    return 3
  }
  if [ "$mode" = namespace ]; then
    transfer_control_authority "$from" "$to" || return 3
    verify_runtime_role_rules || return 3
    verify_control_authority "$to"
  fi
}

control_binding_json() {
  "$KUBECTL" --context "$CONTEXT" -n "$CONTROL_NAMESPACE" get rolebinding "$CONTROL_LOCK" -o json
}

transfer_control_authority() {
  local from=$1 to=$2 json current uid rv patch verified
  verify_control_role_rules || return 3
  json=$(control_binding_json) || return 3
  printf '%s' "$json" | jq -e --arg name "$CONTROL_LOCK" \
    '.roleRef == {apiGroup:"rbac.authorization.k8s.io",kind:"Role",name:$name}' >/dev/null || return 3
  current=$(printf '%s' "$json" | jq -er --arg installation "$INSTALLATION_ID" --arg namespace "$NAMESPACE" --arg name "$CONTROL_LOCK" '
    select(.metadata.name == $name)
    | select(.metadata.labels["app.kubernetes.io/managed-by"] == "agent-os")
    | select(.metadata.annotations["agent-os.dev/installation-id"] == $installation)
    | select(.subjects | type == "array" and length == 1)
    | select(.subjects[0].kind == "ServiceAccount" and .subjects[0].namespace == $namespace)
    | .subjects[0].name') || return 3
  [ "$current" != "$to" ] || { verify_control_authority "$to"; return $?; }
  [ "$current" = "$from" ] || return 3
  uid=$(printf '%s' "$json" | jq -er '.metadata.uid') || return 3
  rv=$(printf '%s' "$json" | jq -er '.metadata.resourceVersion') || return 3
  patch=$(jq -cn --arg uid "$uid" --arg rv "$rv" --arg namespace "$NAMESPACE" --arg account "$to" \
    '{metadata:{uid:$uid,resourceVersion:$rv},subjects:[{kind:"ServiceAccount",name:$account,namespace:$namespace}]}')
  "$KUBECTL" --context "$CONTEXT" -n "$CONTROL_NAMESPACE" patch rolebinding "$CONTROL_LOCK" --type=merge -p "$patch" >/dev/null || return 3
  verified=$(control_binding_json) || return 3
  printf '%s' "$verified" | jq -e --arg uid "$uid" --arg namespace "$NAMESPACE" --arg account "$to" '
    .metadata.uid == $uid and .subjects == [{kind:"ServiceAccount",name:$account,namespace:$namespace}]' >/dev/null
}

ensure_control_lock_access() {
  local role binding live uid rv desired kind
  [ "$DESIRED_RBAC" = namespace ] || return 0
  configure_control_lock
  role=$(jq -cn --arg name "$CONTROL_LOCK" --arg namespace "$CONTROL_NAMESPACE" --arg installation "$INSTALLATION_ID" '
    {apiVersion:"rbac.authorization.k8s.io/v1",kind:"Role",metadata:{name:$name,namespace:$namespace,labels:{"app.kubernetes.io/managed-by":"agent-os"},annotations:{"agent-os.dev/installation-id":$installation}},rules:[{apiGroups:["coordination.k8s.io"],resources:["leases"],resourceNames:[$name],verbs:["get","update"]}]}')
  binding=$(jq -cn --arg name "$CONTROL_LOCK" --arg controlNamespace "$CONTROL_NAMESPACE" --arg installation "$INSTALLATION_ID" --arg namespace "$NAMESPACE" --arg account "$SERVICE_ACCOUNT_NAME" '
    {apiVersion:"rbac.authorization.k8s.io/v1",kind:"RoleBinding",metadata:{name:$name,namespace:$controlNamespace,labels:{"app.kubernetes.io/managed-by":"agent-os"},annotations:{"agent-os.dev/installation-id":$installation}},roleRef:{apiGroup:"rbac.authorization.k8s.io",kind:"Role",name:$name},subjects:[{kind:"ServiceAccount",name:$account,namespace:$namespace}]}')
  for desired in "$role" "$binding"; do
    kind=$(printf '%s' "$desired" | jq -r '.kind')
    live=$("$KUBECTL" --context "$CONTEXT" -n "$CONTROL_NAMESPACE" get "$kind" "$CONTROL_LOCK" --ignore-not-found -o json)
    if [ -z "$live" ]; then
      printf '%s' "$desired" | "$KUBECTL" --context "$CONTEXT" create -f - >/dev/null || return 3
    else
      printf '%s' "$live" | jq -e --arg installation "$INSTALLATION_ID" --arg name "$CONTROL_LOCK" '
        .metadata.name == $name and .metadata.labels["app.kubernetes.io/managed-by"] == "agent-os" and .metadata.annotations["agent-os.dev/installation-id"] == $installation' >/dev/null || return 3
      uid=$(printf '%s' "$live" | jq -er '.metadata.uid') || return 3
      rv=$(printf '%s' "$live" | jq -er '.metadata.resourceVersion') || return 3
      desired=$(printf '%s' "$desired" | jq -c --arg uid "$uid" --arg rv "$rv" '.metadata.uid=$uid | .metadata.resourceVersion=$rv')
      printf '%s' "$desired" | "$KUBECTL" --context "$CONTEXT" replace -f - >/dev/null || return 3
    fi
  done
  live=$(control_binding_json) || return 3
  printf '%s' "$live" | jq -e --arg namespace "$NAMESPACE" --arg account "$SERVICE_ACCOUNT_NAME" --arg name "$CONTROL_LOCK" '
    .roleRef == {apiGroup:"rbac.authorization.k8s.io",kind:"Role",name:$name} and .subjects == [{kind:"ServiceAccount",name:$account,namespace:$namespace}]' >/dev/null
}

delete_control_lock_access() {
  local kind resource plural live uid rv after
  [ -n "${CONTROL_LOCK:-}" ] || configure_control_lock
  for kind in RoleBinding Role; do
    resource=$(printf '%s' "$kind" | tr '[:upper:]' '[:lower:]')
    plural="${resource}s"
    live=$("$KUBECTL" --context "$CONTEXT" -n "$CONTROL_NAMESPACE" get "$kind" "$CONTROL_LOCK" --ignore-not-found -o json) || return 3
    [ -n "$live" ] || continue
    printf '%s' "$live" | jq -e --arg name "$CONTROL_LOCK" --arg installation "$INSTALLATION_ID" '
      .metadata.name == $name and .metadata.labels["app.kubernetes.io/managed-by"] == "agent-os" and .metadata.annotations["agent-os.dev/installation-id"] == $installation' >/dev/null || return 3
    uid=$(printf '%s' "$live" | jq -er '.metadata.uid') || return 3
    rv=$(printf '%s' "$live" | jq -er '.metadata.resourceVersion') || return 3
    printf '{"apiVersion":"v1","kind":"DeleteOptions","preconditions":{"uid":"%s","resourceVersion":"%s"}}\n' "$uid" "$rv" | \
      "$KUBECTL" --context "$CONTEXT" delete --raw "/apis/rbac.authorization.k8s.io/v1/namespaces/$CONTROL_NAMESPACE/$plural/$CONTROL_LOCK" -f - >/dev/null || return 3
    after=$("$KUBECTL" --context "$CONTEXT" -n "$CONTROL_NAMESPACE" get "$kind" "$CONTROL_LOCK" --ignore-not-found -o json) || return 3
    [ -z "$after" ] || return 3
  done
}

compensate_rollback() {
  local source_template=$1 current_account=$2 target_account=$3 mode=$4 state uid rv patch refs revisions name revision digest clear
  transfer_runtime_authority "$mode" "$target_account" "$current_account" || return 3
  state=$("$KUBECTL" --context "$CONTEXT" -n "$NAMESPACE" \
    --request-timeout="${RESOURCE_REQUEST_CEILING_SECONDS}s" get statefulset agent-os-firstmate -o json) || return 3
  uid=$(printf '%s' "$state" | jq -er --arg expected "$rollback_uid" 'select(.metadata.uid == $expected) | .metadata.uid') || return 3
  rv=$(printf '%s' "$state" | jq -er '.metadata.resourceVersion') || return 3
  patch=$(jq -cn --arg uid "$uid" --arg rv "$rv" --argjson template "$source_template" \
    '{metadata:{uid:$uid,resourceVersion:$rv},spec:{template:$template}}')
  "$KUBECTL" --context "$CONTEXT" -n "$NAMESPACE" patch statefulset agent-os-firstmate --type=strategic -p "$patch" >/dev/null || return 3
  "$KUBECTL" --context "$CONTEXT" -n "$NAMESPACE" rollout status statefulset/agent-os-firstmate --timeout=180s || return 3
  [ "$(workload_service_account)" = "$current_account" ] || return 3
  state=$("$KUBECTL" --context "$CONTEXT" -n "$NAMESPACE" --request-timeout="${RESOURCE_REQUEST_CEILING_SECONDS}s" \
    get statefulset agent-os-firstmate -o json) || return 3
  refs=$(printf '%s' "$state" | jq -er --arg uid "$rollback_uid" \
    'select(.metadata.uid == $uid) | [.status.currentRevision,.status.updateRevision,.metadata.resourceVersion] | @tsv') || return 3
  revisions=$("$KUBECTL" --context "$CONTEXT" -n "$NAMESPACE" --request-timeout="${RESOURCE_REQUEST_CEILING_SECONDS}s" \
    get controllerrevisions.apps -o json) || return 3
  for name in "$(printf '%s' "$refs" | cut -f1)" "$(printf '%s' "$refs" | cut -f2)"; do
    revision=$(printf '%s' "$revisions" | jq -ce --arg name "$name" --arg uid "$rollback_uid" '
      [.items[] | select(.metadata.name == $name) | select(any(.metadata.ownerReferences[]?;
        .controller == true and .kind == "StatefulSet" and .name == "agent-os-firstmate" and .uid == $uid))]
      | select(length == 1) | .[0]') || return 3
    digest=$(printf '%s' "$revision" | jq -cS '.data.spec.template' | template_digest)
    [ "$digest" = "$rollback_source_digest" ] || return 3
  done
  transfer_runtime_authority "$mode" "$target_account" "$current_account" || return 3
  clear=$(jq -cn --arg uid "$rollback_uid" --arg rv "$(printf '%s' "$refs" | cut -f3)" \
    '{metadata:{uid:$uid,resourceVersion:$rv,annotations:{"agent-os.dev/rollback-operation":null,"agent-os.dev/rollback-target-name":null,"agent-os.dev/rollback-target-uid":null,"agent-os.dev/rollback-target-digest":null,"agent-os.dev/rollback-source-name":null,"agent-os.dev/rollback-source-uid":null,"agent-os.dev/rollback-source-digest":null}}}')
  "$KUBECTL" --context "$CONTEXT" -n "$NAMESPACE" patch statefulset agent-os-firstmate --type=merge -p "$clear" >/dev/null
}

wait_for_revision_history_absence() {
  local workload_uid=$1 deadline revisions count
  deadline=$(($(date -u '+%s') + 180))
  while :; do
    revisions=$("$KUBECTL" --context "$CONTEXT" -n "$NAMESPACE" \
      --request-timeout="${RESOURCE_REQUEST_CEILING_SECONDS}s" get controllerrevisions.apps -o json) || return 3
    count=$(printf '%s' "$revisions" | jq -er --arg uid "$workload_uid" \
      '[.items[] | select(any(.metadata.ownerReferences[]?; .controller == true and .kind == "StatefulSet" and .name == "agent-os-firstmate" and ($uid == "" or .uid == $uid)))] | length') || return 3
    [ "$count" -eq 0 ] && return 0
    [ "$(date -u '+%s')" -lt "$deadline" ] || {
      echo "incomplete: retained ControllerRevision history still references the removed StatefulSet" >&2
      return 3
    }
    sleep 1
  done
}

inventory_revision_service_accounts() {
  local workload_uid=$1 revisions accounts account identity record
  revisions=$("$KUBECTL" --context "$CONTEXT" -n "$NAMESPACE" \
    --request-timeout="${RESOURCE_REQUEST_CEILING_SECONDS}s" get controllerrevisions.apps -o json) || return 3
  accounts=$(printf '%s' "$revisions" | jq -er --arg uid "$workload_uid" '
    [.items[] | select(any(.metadata.ownerReferences[]?;
      .controller == true and .kind == "StatefulSet" and .name == "agent-os-firstmate" and .uid == $uid))
      | .data.spec.template.spec.serviceAccountName]
    | select(all(.[]; type == "string" and test("^agent-os-firstmate(-[a-z0-9]{12})?$")))
    | unique | join("\n")') || return 3
  while IFS= read -r account; do
    [ -n "$account" ] || continue
    identity=$(live_resource_identity ServiceAccount "$account") || return 3
    [ "$identity" = "$account"$'\t'"agent-os"$'\t'"$INSTALLATION_ID" ] || {
      echo "error: historical ServiceAccount '$account' is missing or foreign" >&2
      return 3
    }
    record=$(live_resource_record namespaced ServiceAccount "$account") || return 3
    [ -n "$(printf '%s' "$record" | cut -f4)" ] && [ -n "$(printf '%s' "$record" | cut -f5)" ] || return 3
  done <<< "$accounts"
  printf '%s' "$accounts"
}

inventory_owned_service_accounts() {
  local resources accounts
  resources=$("$KUBECTL" --context "$CONTEXT" -n "$NAMESPACE" \
    --request-timeout="${RESOURCE_REQUEST_CEILING_SECONDS}s" get serviceaccounts -o json) || return 3
  accounts=$(printf '%s' "$resources" | jq -er --arg installation "$INSTALLATION_ID" '
    [.items[]
      | select(.metadata.name | test("^agent-os-firstmate(-[a-z0-9]{12})?$"))
      | select(.metadata.labels["app.kubernetes.io/managed-by"] == "agent-os")
      | select(.metadata.annotations["agent-os.dev/installation-id"] == $installation)] as $owned
    | select(all($owned[]; (.metadata.uid | type == "string" and length > 0) and
                           (.metadata.resourceVersion | type == "string" and length > 0)))
    | [$owned[].metadata.name] | unique | join("\n")') || return 3
  printf '%s' "$accounts"
}

require_no_active_rollback_checkpoint() {
  local state checkpoint
  if ! command -v jq >/dev/null 2>&1; then
    echo "error: jq is required to verify rollback checkpoint state before upgrade" >&2
    exit 2
  fi
  state=$("$KUBECTL" --context "$CONTEXT" -n "$NAMESPACE" \
    --request-timeout="${RESOURCE_REQUEST_CEILING_SECONDS}s" get statefulset agent-os-firstmate -o json)
  checkpoint=$(printf '%s' "$state" | jq -er --arg installation "$INSTALLATION_ID" '
    select(.metadata.name == "agent-os-firstmate")
    | select(.metadata.labels["app.kubernetes.io/managed-by"] == "agent-os")
    | select(.metadata.annotations["agent-os.dev/installation-id"] == $installation)
    | [(.metadata.annotations["agent-os.dev/rollback-operation"] // ""),
       (.metadata.annotations["agent-os.dev/rollback-target-name"] // ""),
       (.metadata.annotations["agent-os.dev/rollback-target-uid"] // ""),
       (.metadata.annotations["agent-os.dev/rollback-target-digest"] // ""),
       (.metadata.annotations["agent-os.dev/rollback-source-name"] // ""),
       (.metadata.annotations["agent-os.dev/rollback-source-uid"] // ""),
       (.metadata.annotations["agent-os.dev/rollback-source-digest"] // "")]
    | @tsv') || { echo "error: StatefulSet rollback checkpoint state is unverifiable" >&2; exit 3; }
  if [ -n "${checkpoint//$'\t'/}" ]; then
    echo "error: active rollback checkpoint blocks upgrade; resume rollback until exact recovery and checkpoint finalization" >&2
    exit 3
  fi
}

verified_akua_overlay_secret() {
  local expected_supplied=0 expected_record='' state secret record current
  if [ "$#" -gt 0 ]; then
    expected_supplied=1
    expected_record=$1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "error: jq is required to verify the Akua authorization overlay" >&2
    return 2
  fi
  state=$("$KUBECTL" --context "$CONTEXT" -n "$NAMESPACE" \
    --request-timeout="${RESOURCE_REQUEST_CEILING_SECONDS}s" get statefulset agent-os-firstmate -o json) || return 3
  secret=$(printf '%s' "$state" | jq -er --arg installation "$INSTALLATION_ID" '
    select(.metadata.name == "agent-os-firstmate")
    | select(.metadata.labels["app.kubernetes.io/managed-by"] == "agent-os")
    | select(.metadata.annotations["agent-os.dev/installation-id"] == $installation)
    | (.metadata.annotations["agent-os.dev/akua-auth-secret"] // "") as $declared
    | ([.spec.template.spec.containers[]? | select(.name == "firstmate") | .env[]? | select(.name == "AKUA_AUTH_HEADER_FILE")] // []) as $env
    | ([.spec.template.spec.containers[]? | select(.name == "firstmate") | .volumeMounts[]? | select(.name == "akua-auth")] // []) as $mount
    | ([.spec.template.spec.volumes[]? | select(.name == "akua-auth")] // []) as $volume
    | if ($declared == "" and ($env|length) == 0 and ($mount|length) == 0 and ($volume|length) == 0) then ""
      elif ($declared | test("^[a-z0-9]([a-z0-9.-]{0,251}[a-z0-9])?$")) and
           ($env|length) == 1 and $env[0].value == "/var/run/secrets/agent-os/akua/authorization" and
           ($mount|length) == 1 and $mount[0].mountPath == "/var/run/secrets/agent-os/akua" and $mount[0].readOnly == true and
           ($volume|length) == 1 and $volume[0].secret.secretName == $declared and $volume[0].secret.defaultMode == 256
      then $declared else error("unverifiable Akua authorization overlay") end') || {
    echo "error: Akua authorization overlay is missing, changed, or unverifiable; upgrade blocked" >&2
    return 3
  }
  if [ -n "$secret" ]; then
    record=$("$KUBECTL" --context "$CONTEXT" -n "$NAMESPACE" \
      --request-timeout="${RESOURCE_REQUEST_CEILING_SECONDS}s" get secret "$secret" --ignore-not-found \
      -o 'jsonpath={.metadata.name}{"\t"}{.metadata.uid}{"\t"}{.metadata.resourceVersion}{"\t"}{range $key,$value := .data}{$key}{"\n"}{end}') || return 3
    if [ "$(printf '%s' "$record" | cut -f1)" != "$secret" ] || \
      [ -z "$(printf '%s' "$record" | cut -f2)" ] || [ -z "$(printf '%s' "$record" | cut -f3)" ] || \
      [ "$(printf '%s' "$record" | cut -f4-)" != authorization ]; then
      echo "error: Akua authorization Secret reference is missing or unverifiable; upgrade blocked" >&2
      return 3
    fi
    current="present"$'\t'"$record"
  else
    current=absent
  fi
  if [ "$expected_supplied" -eq 1 ] && [ "$current" != "$expected_record" ]; then
    echo "error: Akua authorization overlay presence or Secret identity changed during upgrade; upgrade blocked" >&2
    return 3
  fi
  printf '%s' "$current"
}

reconcile_failed_akua_upgrade() {
  local expected=$1 state uid rv rejected patch
  state=$("$KUBECTL" --context "$CONTEXT" -n "$NAMESPACE" \
    --request-timeout="${RESOURCE_REQUEST_CEILING_SECONDS}s" get statefulset agent-os-firstmate -o json) || return 3
  uid=$(printf '%s' "$state" | jq -er --arg installation "$INSTALLATION_ID" '
    select(.metadata.name == "agent-os-firstmate")
    | select(.metadata.labels["app.kubernetes.io/managed-by"] == "agent-os")
    | select(.metadata.annotations["agent-os.dev/installation-id"] == $installation)
    | .metadata.uid') || return 3
  rv=$(printf '%s' "$state" | jq -er '.metadata.resourceVersion') || return 3
  rejected=$(printf '%s' "$expected" | sha256_text)
  patch=$(jq -cn --arg uid "$uid" --arg rv "$rv" --arg rejected "$rejected" '
    {metadata:{uid:$uid,resourceVersion:$rv,annotations:{"agent-os.dev/akua-auth-secret":null,"agent-os.dev/akua-auth-rejected-record":$rejected}},
     spec:{template:{spec:{containers:[{name:"firstmate",env:[{name:"AKUA_AUTH_HEADER_FILE","$patch":"delete"}],volumeMounts:[{mountPath:"/var/run/secrets/agent-os/akua","$patch":"delete"}]}],volumes:[{name:"akua-auth","$patch":"delete"}]}}}}')
  "$KUBECTL" --context "$CONTEXT" -n "$NAMESPACE" patch statefulset agent-os-firstmate --type=strategic -p "$patch" >/dev/null || return 3
  "$KUBECTL" --context "$CONTEXT" -n "$NAMESPACE" rollout status statefulset/agent-os-firstmate --timeout=180s || return 3
  verified_akua_overlay_secret absent >/dev/null || return 3
  printf 'incomplete: upgrade authorization failed closed expected-secret-uid=%s expected-secret-rv=%s\n' \
    "$(printf '%s' "$expected" | cut -f3)" "$(printf '%s' "$expected" | cut -f4)" >&2
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
  local scope=$1 kind=$2 name=$3 request_timeout=${4:-}
  local request_args=()
  [ -z "$request_timeout" ] || request_args=(--request-timeout="$request_timeout")
  if [ "$scope" = cluster ]; then
    "$KUBECTL" --context "$CONTEXT" "${request_args[@]}" get "$kind" "$name" --ignore-not-found \
      -o 'jsonpath={.metadata.name}{"\t"}{.metadata.labels.app\.kubernetes\.io/managed-by}{"\t"}{.metadata.annotations.agent-os\.dev/installation-id}{"\t"}{.metadata.uid}{"\t"}{.metadata.resourceVersion}{"\t"}{.metadata.labels.agent-os\.dev/operation-id}'
  else
    "$KUBECTL" --context "$CONTEXT" -n "$NAMESPACE" "${request_args[@]}" get "$kind" "$name" --ignore-not-found \
      -o 'jsonpath={.metadata.name}{"\t"}{.metadata.labels.app\.kubernetes\.io/managed-by}{"\t"}{.metadata.annotations.agent-os\.dev/installation-id}{"\t"}{.metadata.uid}{"\t"}{.metadata.resourceVersion}{"\t"}{.metadata.labels.agent-os\.dev/operation-id}'
  fi
}

operation_remaining_seconds() {
  local deadline=$1 remaining
  remaining=$((deadline - $(date -u '+%s')))
  [ "$remaining" -gt 0 ] || return 1
  printf '%s' "$remaining"
}

operation_request_seconds() {
  local deadline=$1 remaining seconds
  remaining=$(operation_remaining_seconds "$deadline") || return 1
  seconds=$RESOURCE_REQUEST_CEILING_SECONDS
  [ "$seconds" -le "$remaining" ] || seconds=$remaining
  [ "$seconds" -gt 0 ] || return 1
  printf '%s' "$seconds"
}

reconcile_deleted_resource() {
  local scope=$1 kind=$2 name=$3 uid=$4 rv=$5 timeout=$6 started=$7 phase=$8 class=$9
  local deadline=${10} request_seconds current current_uid current_rv elapsed
  request_seconds=$(operation_request_seconds "$deadline") || {
    elapsed=$(($(date -u '+%s') - started))
    bounded_delete_failure "$kind/$name" "$phase" "$class" "$timeout" "$elapsed" "$uid" "$deadline"
    return $?
  }
  if ! current=$(live_resource_record "$scope" "$kind" "$name" "${request_seconds}s"); then
    elapsed=$(($(date -u '+%s') - started))
    bounded_delete_failure "$kind/$name" reconcile transport "$timeout" "$elapsed" "$uid" "$deadline"
    return $?
  fi
  if [ -z "$current" ]; then
    echo "confirmed absent: $kind/$name captured uid=$uid after delete-$phase failure=$class" >&2
    return 0
  fi
  current_uid=$(printf '%s' "$current" | cut -f4)
  current_rv=$(printf '%s' "$current" | cut -f5)
  elapsed=$(($(date -u '+%s') - started))
  if [ "$current_uid" != "$uid" ]; then
    echo "error: $kind/$name replacement uid=${current_uid:-unknown} retained after ambiguous delete of captured uid=$uid resourceVersion=$rv" >&2
    bounded_delete_failure "$kind/$name" reconcile replacement "$timeout" "$elapsed" "$uid" "$deadline"
    return $?
  fi
  echo "error: $kind/$name captured uid=$uid remains at resourceVersion=${current_rv:-unknown} after delete-$phase failure=$class" >&2
  bounded_delete_failure "$kind/$name" "$phase" "$class" "$timeout" "$elapsed" "$uid" "$deadline"
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
  local scope=$1 kind=$2 name=$3 timeout=$4 record expected uid rv path output started deadline class request_seconds remaining reserve wait_budget
  started=$(date -u '+%s')
  deadline=$((started + timeout))
  request_seconds=$(operation_request_seconds "$deadline") || {
    bounded_delete_failure "$kind/$name" observe timeout "$timeout" 0 unknown "$deadline"
    return $?
  }
  if ! record=$(live_resource_record "$scope" "$kind" "$name" "${request_seconds}s"); then
    bounded_delete_failure "$kind/$name" observe transport "$timeout" 0 unknown "$deadline"
    return $?
  fi
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
  request_seconds=$(operation_request_seconds "$deadline") || {
    bounded_delete_failure "$kind/$name" request timeout "$timeout" 0 "$uid" "$deadline"
    return $?
  }
  if ! output=$(printf '{"apiVersion":"v1","kind":"DeleteOptions","preconditions":{"uid":"%s","resourceVersion":"%s"}}\n' "$uid" "$rv" | \
    "$KUBECTL" --context "$CONTEXT" --request-timeout="${request_seconds}s" delete --raw "$path" -f - 2>&1 >/dev/null); then
    class=$(delete_failure_class "$output")
    reconcile_deleted_resource "$scope" "$kind" "$name" "$uid" "$rv" "$timeout" "$started" request "$class" "$deadline"
    return $?
  fi
  remaining=$(operation_remaining_seconds "$deadline") || remaining=0
  if [ "$remaining" -lt 2 ]; then
    reconcile_deleted_resource "$scope" "$kind" "$name" "$uid" "$rv" "$timeout" "$started" wait timeout "$deadline"
    return $?
  fi
  reserve=$RESOURCE_REQUEST_CEILING_SECONDS
  [ "$reserve" -lt "$remaining" ] || reserve=$((remaining - 1))
  wait_budget=$((remaining - reserve))
  if [ "$scope" = cluster ]; then
    if ! output=$("$KUBECTL" --context "$CONTEXT" --request-timeout="${wait_budget}s" wait --for=delete "$kind/$name" --timeout="${wait_budget}s" 2>&1 >/dev/null); then
      class=$(delete_failure_class "$output")
      reconcile_deleted_resource "$scope" "$kind" "$name" "$uid" "$rv" "$timeout" "$started" wait "$class" "$deadline"
    fi
  else
    if ! output=$("$KUBECTL" --context "$CONTEXT" -n "$NAMESPACE" --request-timeout="${wait_budget}s" wait --for=delete "$kind/$name" --timeout="${wait_budget}s" 2>&1 >/dev/null); then
      class=$(delete_failure_class "$output")
      reconcile_deleted_resource "$scope" "$kind" "$name" "$uid" "$rv" "$timeout" "$started" wait "$class" "$deadline"
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
  local scope=$1 kind=$2 name=$3 request_timeout=${4:-} request_args=()
  [ -z "$request_timeout" ] || request_args=(--request-timeout="$request_timeout")
  if [ "$kind" = StatefulSet ]; then
    "$KUBECTL" --context "$CONTEXT" -n "$NAMESPACE" "${request_args[@]}" get "$kind" "$name" --ignore-not-found \
      -o 'jsonpath={.metadata.name}{"\t"}{.metadata.labels.app\.kubernetes\.io/managed-by}{"\t"}{.metadata.annotations.agent-os\.dev/installation-id}{"\t"}{.metadata.uid}{"\t"}{.metadata.labels.agent-os\.dev/operation-id}{"\t"}{"\t"}{.metadata.finalizers}{"\t"}{.spec.replicas}{"\t"}{.status.currentReplicas}{"\t"}{.status.readyReplicas}{"\t"}{.status.updatedReplicas}{"\t"}{.status.availableReplicas}{"\t"}{.status.currentRevision}{"\t"}{.status.updateRevision}{"\t"}{.metadata.generation}{"\t"}{.status.observedGeneration}'
    return
  fi
  if [ "$kind" = Pod ]; then
    "$KUBECTL" --context "$CONTEXT" -n "$NAMESPACE" "${request_args[@]}" get "$kind" "$name" --ignore-not-found \
      -o 'jsonpath={.metadata.name}{"\t"}{.metadata.labels.app\.kubernetes\.io/managed-by}{"\t"}{.metadata.annotations.agent-os\.dev/installation-id}{"\t"}{.metadata.uid}{"\t"}{.metadata.labels.agent-os\.dev/operation-id}{"\t"}{range .status.conditions[?(@.type=="Ready")]}{.status}{end}{"\t"}{.metadata.finalizers}{"\t"}{range .status.containerStatuses[*]}{.name}{"="}{.state.waiting.reason}{.state.terminated.reason}{","}{end}'
    return
  fi
  if [ "$scope" = cluster ]; then
    "$KUBECTL" --context "$CONTEXT" "${request_args[@]}" get "$kind" "$name" --ignore-not-found \
      -o 'jsonpath={.metadata.name}{"\t"}{.metadata.labels.app\.kubernetes\.io/managed-by}{"\t"}{.metadata.annotations.agent-os\.dev/installation-id}{"\t"}{.metadata.uid}{"\t"}{.metadata.labels.agent-os\.dev/operation-id}{"\t"}{range .status.conditions[?(@.type=="Ready")]}{.status}{end}{"\t"}{.metadata.finalizers}'
  else
    "$KUBECTL" --context "$CONTEXT" -n "$NAMESPACE" "${request_args[@]}" get "$kind" "$name" --ignore-not-found \
      -o 'jsonpath={.metadata.name}{"\t"}{.metadata.labels.app\.kubernetes\.io/managed-by}{"\t"}{.metadata.annotations.agent-os\.dev/installation-id}{"\t"}{.metadata.uid}{"\t"}{.metadata.labels.agent-os\.dev/operation-id}{"\t"}{range .status.conditions[?(@.type=="Ready")]}{.status}{end}{"\t"}{.metadata.finalizers}'
  fi
}

lifecycle_command() {
  local action=${1:-$COMMAND}
  printf 'AGENT_OS_CONTEXT=%q AGENT_OS_NAMESPACE=%q AGENT_OS_CONTROL_NAMESPACE=%q AGENT_OS_PACKAGE=%q AGENT_OS_INPUTS=%q AGENT_OS_AKUA=%q AGENT_OS_KUBECTL=%q %q %q' \
    "$CONTEXT" "$NAMESPACE" "${CONTROL_NAMESPACE:-${AGENT_OS_CONTROL_NAMESPACE:-kube-system}}" "$PACKAGE" "$INPUTS" "$AKUA" "$KUBECTL" "$0" "$action"
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

report_rollback_failure() {
  local target_name=$1 target_revision=$2 target_uid=$3 target_digest=$4 checkpoint_operation=$5 checkpoint_name=$6 checkpoint_uid=$7
  local state references lease deadline record
  echo "incomplete: rollback target=$target_name revision=$target_revision target-uid=$target_uid target-digest=$target_digest checkpoint-operation=$checkpoint_operation checkpoint-target=$checkpoint_name checkpoint-uid=$checkpoint_uid did not complete" >&2
  deadline=$(lock_default_deadline)
  if state=$("$KUBECTL" --context "$CONTEXT" -n "$NAMESPACE" --request-timeout="${RESOURCE_REQUEST_CEILING_SECONDS}s" get statefulset agent-os-firstmate -o json 2>/dev/null) && \
    references=$(printf '%s' "$state" | jq -er '[.status.currentRevision, .status.updateRevision] | select(all(.[]; type == "string" and length > 0)) | @tsv' 2>/dev/null); then
    echo "rollback observed: current-revision=$(printf '%s' "$references" | cut -f1) update-revision=$(printf '%s' "$references" | cut -f2)" >&2
  else
    echo "rollback observed: StatefulSet revision evidence unavailable" >&2
  fi
  if ! record=$(resource_observation namespaced Pod agent-os-firstmate-0 "${RESOURCE_REQUEST_CEILING_SECONDS}s" 2>/dev/null); then
    echo "partial apply: Pod/agent-os-firstmate-0 observation=unavailable expected-operation=$OPERATION_ID" >&2
  elif [ -n "$record" ]; then
    echo "partial apply: Pod/agent-os-firstmate-0 uid=$(printf '%s' "$record" | cut -f4) operation=$(printf '%s' "$record" | cut -f5) ready=$(printf '%s' "$record" | cut -f6) ownership=$(printf '%s' "$record" | cut -f2) installation=$(printf '%s' "$record" | cut -f3) finalizers=$(printf '%s' "$record" | cut -f7)" >&2
  else
    echo "partial apply: Pod/agent-os-firstmate-0 observed=absent expected-operation=$OPERATION_ID" >&2
  fi
  if lease=$(lock_record "$deadline" 2>/dev/null) && [ -n "$lease" ]; then
    echo "rollback retained: lifecycle-lease=$LOCK uid=$(printf '%s' "$lease" | cut -f9) holder=$(printf '%s' "$lease" | cut -f5)" >&2
  else
    echo "rollback retained: lifecycle-lease=$LOCK evidence=unavailable" >&2
  fi
  printf 'safe recovery: %q --context %q -n %q rollout status statefulset/agent-os-firstmate --timeout=180s\n' \
    "$KUBECTL" "$CONTEXT" "$NAMESPACE" >&2
  echo "safe recovery condition: rerun rollback only while the persisted target digest remains '$target_digest'" >&2
  return 3
}

sha256_text() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}

template_digest() {
  jq -cS . | sha256_text
}

owned_revision_by_digest() {
  local revisions=$1 workload_uid=$2 digest=$3 preferred_uid=${4:-} item item_digest candidate='' candidate_revision=-1 item_revision item_uid
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    item_digest=$(printf '%s' "$item" | jq -cS '.data.spec.template' | template_digest)
    [ "$item_digest" = "$digest" ] || continue
    item_uid=$(printf '%s' "$item" | jq -r '.metadata.uid // empty')
    if [ -n "$preferred_uid" ] && [ "$item_uid" = "$preferred_uid" ]; then
      printf '%s' "$item"
      return 0
    fi
    item_revision=$(printf '%s' "$item" | jq -r '.revision // -1')
    if [ "$item_revision" -gt "$candidate_revision" ] 2>/dev/null; then
      candidate=$item
      candidate_revision=$item_revision
    fi
  done < <(printf '%s' "$revisions" | jq -c --arg uid "$workload_uid" '
    .items[]
    | select(any(.metadata.ownerReferences[]?;
        .apiVersion == "apps/v1" and .kind == "StatefulSet" and
        .name == "agent-os-firstmate" and .uid == $uid and .controller == true))
    ')
  [ -n "$candidate" ] || return 1
  printf '%s' "$candidate"
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
  local file=$1 kind name scope record expected uid rv operation current patch_file patch_type
  kind=$(rendered_resource_field "$file" kind)
  name=$(rendered_resource_field "$file" name)
  [ "$kind" != Namespace ] || return 0
  scope=namespaced
  [ "$kind" != ClusterRoleBinding ] || scope=cluster
  record=$(live_resource_record "$scope" "$kind" "$name")
  expected="$name"$'\t'"agent-os"$'\t'"$INSTALLATION_ID"
  if [ -z "$record" ]; then
    [ "$kind" != StatefulSet ] || STATEFULSET_CAS_ATTEMPTED=1
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
    if [ "$kind" = StatefulSet ] && [ "$AKUA_OVERLAY_VERIFIED" -eq 1 ]; then
      verified_akua_overlay_secret "$PRESERVED_AKUA_SECRET_RECORD" >/dev/null || {
        echo "incomplete: Akua authorization changed before StatefulSet CAS; no template mutation attempted" >&2
        return 3
      }
    fi
    patch_file=$(cas_patch_file "$file" "$uid" "$rv")
    [ "$kind" != StatefulSet ] || STATEFULSET_CAS_ATTEMPTED=1
    if [ "$scope" = cluster ]; then
      if ! "$KUBECTL" --context "$CONTEXT" patch "$kind" "$name" --type=merge --patch-file "$patch_file" >/dev/null; then
        report_partial_apply patch
        return $?
      fi
    else
      patch_type=merge
      [ "$kind" != StatefulSet ] || patch_type=strategic
      if ! "$KUBECTL" --context "$CONTEXT" -n "$NAMESPACE" patch "$kind" "$name" --type="$patch_type" --patch-file "$patch_file" >/dev/null; then
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
  local binding_json
  if [ "$DESIRED_RBAC" = namespace ]; then
    if ! command -v jq >/dev/null 2>&1; then
      echo "error: jq is required to verify namespace RBAC exactly" >&2
      exit 2
    fi
    binding_json=$("$KUBECTL" --context "$CONTEXT" -n "$NAMESPACE" get rolebinding agent-os-firstmate-runtime -o json)
    if ! verify_runtime_role_rules ||
      ! printf '%s' "$binding_json" | jq -e --arg namespace "$NAMESPACE" --arg serviceAccount "$SERVICE_ACCOUNT_NAME" '
        .roleRef == {"apiGroup":"rbac.authorization.k8s.io","kind":"Role","name":"agent-os-firstmate-runtime"} and
        .subjects == [{"kind":"ServiceAccount","name":$serviceAccount,"namespace":$namespace}]' >/dev/null; then
      echo "error: desired namespace RBAC did not verify after apply" >&2
      exit 2
    fi
  fi
}

cleanup_command() {
  printf 'AGENT_OS_CONTEXT=%q AGENT_OS_NAMESPACE=%q AGENT_OS_CONTROL_NAMESPACE=%q AGENT_OS_PACKAGE=%q AGENT_OS_INPUTS=%q AGENT_OS_AKUA=%q AGENT_OS_KUBECTL=%q %q cleanup-cluster-rbac --yes' \
    "$CONTEXT" "$NAMESPACE" "${CONTROL_NAMESPACE:-${AGENT_OS_CONTROL_NAMESPACE:-kube-system}}" "$PACKAGE" "$INPUTS" "$AKUA" "$KUBECTL" "$0"
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
  local kind=$1 name=$2 scope=$3 deadline=${4:-} record managed installation uid operation ready finalizers identity expected details request_seconds
  if [ -n "$deadline" ]; then
    request_seconds=$(operation_request_seconds "$deadline") || {
      echo "retained-unverified: $kind/$name evidence deadline exhausted; no further deletion attempted" >&2
      return 0
    }
  else
    request_seconds=$RESOURCE_REQUEST_CEILING_SECONDS
  fi
  if ! record=$(resource_observation "$scope" "$kind" "$name" "${request_seconds}s"); then
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
  local failed_target=$1 phase=$2 class=$3 timeout=$4 elapsed=$5 uid=$6 deadline=${7:-} file kind name scope
  echo "failed-target: $failed_target uid=$uid delete-${phase}-failure=$class timeout=${timeout}s elapsed=${elapsed}s" >&2
  kind=${failed_target%%/*}
  name=${failed_target#*/}
  scope=namespaced
  [ "$kind" != Namespace ] || scope=cluster
  report_retained_observation "$kind" "$name" "$scope" "$deadline"
  report_retained_observation Pod agent-os-firstmate-0 namespaced "$deadline"
  report_retained_observation Role agent-os-firstmate-runtime namespaced "$deadline"
  report_retained_observation RoleBinding agent-os-firstmate-runtime namespaced "$deadline"
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
    report_retained_observation "$kind" "$name" "$scope" "$deadline"
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
  local elapsed=${5:-$timeout} uid=${6:-unknown} deadline=${7:-} prefix kind name scope
  [ "$COMMAND" = uninstall ] && prefix=incomplete || prefix=error
  echo "$prefix: delete-${phase}-failure=$class target=$target uid=$uid timeout=${timeout}s elapsed=${elapsed}s" >&2
  if [ "$COMMAND" = uninstall ]; then
    report_retained_resources "$target" "$phase" "$class" "$timeout" "$elapsed" "$uid" "$deadline"
    return 3
  fi
  kind=${target%%/*}
  name=${target#*/}
  scope=namespaced
  case "$kind" in
    ClusterRoleBinding|Namespace) scope=cluster ;;
  esac
  report_retained_observation "$kind" "$name" "$scope" "$deadline"
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
    acquire_primary_lock
    require_namespace_contract
    create_managed_namespace_if_absent
    acquire_namespace_lock
    require_namespace_contract
    preflight_rendered_resources 1
    previous=$(workload_state)
    require_workload_owned "$previous" optional
    if [ -n "$previous" ]; then
      echo "error: agent-os-firstmate already exists; use upgrade" >&2
      exit 2
    fi
    preflight_legacy_cluster_binding 0
    ensure_control_lock_access
    apply_rendered
    verify_desired_rbac
    if [ "$DESIRED_RBAC" != namespace ]; then
      delete_namespace_rbac
    fi
    if [ "$DESIRED_RBAC" = none ]; then
      delete_control_lock_access
      verify_no_runtime_authority || { echo "error: authority-free install retained RBAC" >&2; exit 3; }
    fi
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
    previous_service_account=$(workload_service_account)
    case "$previous_service_account" in
      agent-os-firstmate-[a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9])
        SERVICE_ACCOUNT_NAME=$previous_service_account
        render
        require_namespaced_resource_owned_or_absent ServiceAccount "$SERVICE_ACCOUNT_NAME"
        ;;
      agent-os-firstmate)
        [ "$(live_resource_identity ServiceAccount agent-os-firstmate)" = \
          "agent-os-firstmate"$'\t'"agent-os"$'\t'"$INSTALLATION_ID" ] || {
          echo "error: retained legacy ServiceAccount dependency is missing or foreign" >&2
          exit 3
        }
        legacy_service_account_record=$(live_resource_record namespaced ServiceAccount agent-os-firstmate)
        [ -n "$(printf '%s' "$legacy_service_account_record" | cut -f4)" ] && \
          [ -n "$(printf '%s' "$legacy_service_account_record" | cut -f5)" ] || {
          echo "error: retained legacy ServiceAccount dependency lacks exact metadata" >&2
          exit 3
        }
        ;;
    esac
    preflight_legacy_cluster_binding 1
    require_no_active_rollback_checkpoint
    PRESERVED_AKUA_SECRET_RECORD=$(verified_akua_overlay_secret)
    AKUA_OVERLAY_VERIFIED=1
    previous_mode=$(printf '%s' "$previous" | cut -f2)
    previous_cleanup=$(printf '%s' "$previous" | cut -f3)
    if [ "$DESIRED_RBAC" != cluster-admin ] && [ "$LEGACY_CLUSTER_BINDING_PRESENT" -eq 1 ]; then
      patch_workload_annotations '{"agent-os.dev/cluster-rbac-cleanup":"required"}'
      report_cluster_cleanup
      exit 3
    fi
    cleanup_required=0
    if [ "$DESIRED_RBAC" != cluster-admin ] && \
      { [ "$previous_mode" = cluster-admin ] || [ -z "$previous_mode" ] || [ "$previous_cleanup" = required ]; }; then
      cleanup_required=1
      patch_workload_annotations '{"agent-os.dev/cluster-rbac-cleanup":"required"}'
    fi
    ensure_control_lock_access
    if ! apply_rendered; then
      if [ "$STATEFULSET_CAS_ATTEMPTED" -eq 1 ]; then
        reconcile_failed_akua_upgrade "$PRESERVED_AKUA_SECRET_RECORD" || {
          echo "incomplete: post-CAS upgrade failure and fail-closed authorization reconciliation is unverified" >&2
          report_partial_observation StatefulSet agent-os-firstmate namespaced
          report_partial_observation Pod agent-os-firstmate-0 namespaced
          exit 3
        }
        echo "safe recovery: run the serialized authorization revoke before retrying upgrade" >&2
      fi
      exit 3
    fi
    if ! verified_akua_overlay_secret "$PRESERVED_AKUA_SECRET_RECORD" >/dev/null; then
      reconcile_failed_akua_upgrade "$PRESERVED_AKUA_SECRET_RECORD" || {
        echo "incomplete: upgrade authorization changed and fail-closed reconciliation is unverified" >&2
        report_partial_observation StatefulSet agent-os-firstmate namespaced
        report_partial_observation Pod agent-os-firstmate-0 namespaced
        exit 3
      }
      echo "safe recovery: run the serialized authorization revoke before retrying upgrade" >&2
      exit 3
    fi
    verify_desired_rbac
    if [ "$DESIRED_RBAC" != namespace ]; then
      delete_namespace_rbac
    fi
    if [ "$DESIRED_RBAC" = none ]; then
      delete_control_lock_access
      verify_no_runtime_authority || { echo "error: authority-free upgrade retained RBAC" >&2; exit 3; }
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
    rollback_state=$("$KUBECTL" --context "$CONTEXT" -n "$NAMESPACE" \
      --request-timeout="${RESOURCE_REQUEST_CEILING_SECONDS}s" get statefulset agent-os-firstmate -o json)
    rollback_revisions=$("$KUBECTL" --context "$CONTEXT" -n "$NAMESPACE" \
      --request-timeout="${RESOURCE_REQUEST_CEILING_SECONDS}s" get controllerrevisions.apps -o json)
    rollback_references=$(printf '%s' "$rollback_state" | jq -er \
      --arg uid "$rollback_uid" --arg rv "$rollback_rv" --arg installation "$INSTALLATION_ID" '
        select(.metadata.name == "agent-os-firstmate")
        | select(.metadata.uid == $uid and .metadata.resourceVersion == $rv)
        | select(.metadata.labels["app.kubernetes.io/managed-by"] == "agent-os")
        | select(.metadata.annotations["agent-os.dev/installation-id"] == $installation)
        | [.status.currentRevision, .status.updateRevision,
           (.metadata.annotations["agent-os.dev/rollback-operation"] // ""),
           (.metadata.annotations["agent-os.dev/rollback-target-name"] // ""),
           (.metadata.annotations["agent-os.dev/rollback-target-uid"] // ""),
           (.metadata.annotations["agent-os.dev/rollback-target-digest"] // ""),
           (.metadata.annotations["agent-os.dev/rollback-source-name"] // ""),
           (.metadata.annotations["agent-os.dev/rollback-source-uid"] // ""),
           (.metadata.annotations["agent-os.dev/rollback-source-digest"] // "")]
        | select((.[0:2]) | all(.[]; type == "string" and length > 0))
        | @tsv
      ') || { echo "error: StatefulSet changed before rollback revision resolution" >&2; exit 3; }
    rollback_current_revision=$(printf '%s' "$rollback_references" | cut -f1)
    rollback_update_revision=$(printf '%s' "$rollback_references" | cut -f2)
    rollback_checkpoint_operation=$(printf '%s' "$rollback_references" | cut -f3)
    rollback_checkpoint_name=$(printf '%s' "$rollback_references" | cut -f4)
    rollback_checkpoint_uid=$(printf '%s' "$rollback_references" | cut -f5)
    rollback_checkpoint_digest=$(printf '%s' "$rollback_references" | cut -f6)
    rollback_source_name=$(printf '%s' "$rollback_references" | cut -f7)
    rollback_source_uid=$(printf '%s' "$rollback_references" | cut -f8)
    rollback_source_digest=$(printf '%s' "$rollback_references" | cut -f9)
    if [ -n "$rollback_checkpoint_operation$rollback_checkpoint_name$rollback_checkpoint_uid$rollback_checkpoint_digest$rollback_source_name$rollback_source_uid$rollback_source_digest" ]; then
      if [ -z "$rollback_checkpoint_operation" ] || [ -z "$rollback_checkpoint_name" ] || \
        [ -z "$rollback_checkpoint_uid" ] || ! [[ "$rollback_checkpoint_digest" =~ ^[0-9a-f]{64}$ ]] || \
        [ -z "$rollback_source_name" ] || [ -z "$rollback_source_uid" ] || ! [[ "$rollback_source_digest" =~ ^[0-9a-f]{64}$ ]]; then
        echo "error: rollback checkpoint is incomplete or malformed; retained" >&2
        exit 3
      fi
      rollback_source=$(owned_revision_by_digest "$rollback_revisions" "$rollback_uid" \
        "$rollback_source_digest" "$rollback_source_uid") || {
        echo "error: rollback checkpoint source content is unavailable; retained" >&2
        exit 3
      }
      rollback_target=$(printf '%s' "$rollback_revisions" | jq -ce --arg name "$rollback_update_revision" --arg uid "$rollback_uid" '
        [.items[] | select(.metadata.name == $name) | select(any(.metadata.ownerReferences[]?;
          .apiVersion == "apps/v1" and .kind == "StatefulSet" and .name == "agent-os-firstmate" and .uid == $uid and .controller == true))]
        | select(length == 1) | .[0]' 2>/dev/null) || rollback_target=''
      if [ -n "$rollback_target" ]; then
        rollback_update_digest=$(printf '%s' "$rollback_target" | jq -cS '.data.spec.template' | template_digest)
        [ "$rollback_update_digest" = "$rollback_checkpoint_digest" ] || rollback_target=''
      fi
      if [ -z "$rollback_target" ]; then
        rollback_target=$(owned_revision_by_digest "$rollback_revisions" "$rollback_uid" \
          "$rollback_checkpoint_digest" "$rollback_checkpoint_uid") || {
          echo "error: rollback checkpoint target content is unavailable; retained" >&2
          exit 3
        }
      fi
      rollback_target_name=$(printf '%s' "$rollback_target" | jq -r '.metadata.name')
      rollback_target_uid=$(printf '%s' "$rollback_target" | jq -r '.metadata.uid')
      rollback_target_revision=$(printf '%s' "$rollback_target" | jq -r '.revision')
      rollback_target_digest=$rollback_checkpoint_digest
      verify_revision_service_account "$rollback_target"
      rollback_mode='patch'
      if [ "$rollback_update_revision" = "$rollback_target_name" ]; then
        rollback_mode=resume
      fi
    else
      rollback_source=$(printf '%s' "$rollback_revisions" | jq -ce --arg name "$rollback_update_revision" --arg uid "$rollback_uid" '
        [.items[] | select(.metadata.name == $name) | select(any(.metadata.ownerReferences[]?;
          .apiVersion == "apps/v1" and .kind == "StatefulSet" and .name == "agent-os-firstmate" and .uid == $uid and .controller == true))]
        | select(length == 1) | .[0]') || { echo "error: current rollback source revision is unavailable" >&2; exit 3; }
      rollback_source_name=$(printf '%s' "$rollback_source" | jq -r '.metadata.name')
      rollback_source_uid=$(printf '%s' "$rollback_source" | jq -r '.metadata.uid')
      rollback_source_digest=$(printf '%s' "$rollback_source" | jq -cS '.data.spec.template' | template_digest)
      rollback_selection=$(printf '%s' "$rollback_revisions" | jq -ce \
        --arg current "$rollback_current_revision" --arg update "$rollback_update_revision" \
        --arg uid "$rollback_uid" '
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
        | select($current_revision.revision | type == "number")
        | select($update_revision.revision | type == "number")
        | (if $current != $update then
             {target:$current_revision}
           else
             {target:($owned | map(select((.revision | type) == "number" and .revision < $update_revision.revision)) | sort_by(.revision) | last)}
           end) as $selection
        | select($selection.target != null and ($selection.target.data.spec.template | type) == "object")
        | $selection.target
      ') || { echo "error: no exact-owned previous ControllerRevision is available for rollback" >&2; exit 2; }
      rollback_target_name=$(printf '%s' "$rollback_selection" | jq -r '.metadata.name')
      rollback_target_uid=$(printf '%s' "$rollback_selection" | jq -r '.metadata.uid')
      rollback_target_revision=$(printf '%s' "$rollback_selection" | jq -r '.revision')
      rollback_target_digest=$(printf '%s' "$rollback_selection" | jq -cS '.data.spec.template' | template_digest)
      rollback_target=$rollback_selection
      verify_revision_service_account "$rollback_target"
      rollback_checkpoint_operation=$OPERATION_ID
      rollback_checkpoint_name=$rollback_target_name
      rollback_checkpoint_uid=$rollback_target_uid
      rollback_checkpoint_patch=$(jq -cn \
        --arg uid "$rollback_uid" --arg rv "$rollback_rv" --arg operation "$rollback_checkpoint_operation" \
        --arg name "$rollback_target_name" --arg targetUid "$rollback_target_uid" --arg digest "$rollback_target_digest" \
        --arg sourceName "$rollback_source_name" --arg sourceUid "$rollback_source_uid" --arg sourceDigest "$rollback_source_digest" \
        '{metadata:{uid:$uid,resourceVersion:$rv,annotations:{"agent-os.dev/rollback-operation":$operation,"agent-os.dev/rollback-target-name":$name,"agent-os.dev/rollback-target-uid":$targetUid,"agent-os.dev/rollback-target-digest":$digest,"agent-os.dev/rollback-source-name":$sourceName,"agent-os.dev/rollback-source-uid":$sourceUid,"agent-os.dev/rollback-source-digest":$sourceDigest}}}')
      if ! "$KUBECTL" --context "$CONTEXT" -n "$NAMESPACE" patch StatefulSet agent-os-firstmate \
        --type=merge -p "$rollback_checkpoint_patch" >/dev/null; then
        echo "error: rollback checkpoint CAS conflicted; no template mutation attempted" >&2
        exit 3
      fi
      rollback_mode='patch'
      rollback_state=$("$KUBECTL" --context "$CONTEXT" -n "$NAMESPACE" \
        --request-timeout="${RESOURCE_REQUEST_CEILING_SECONDS}s" get statefulset agent-os-firstmate -o json)
      rollback_rv=$(printf '%s' "$rollback_state" | jq -er \
        --arg uid "$rollback_uid" --arg operation "$rollback_checkpoint_operation" \
        --arg name "$rollback_checkpoint_name" --arg targetUid "$rollback_checkpoint_uid" \
        --arg digest "$rollback_target_digest" --arg sourceName "$rollback_source_name" \
        --arg sourceUid "$rollback_source_uid" --arg sourceDigest "$rollback_source_digest" '
        select(.metadata.uid == $uid)
        | select(.metadata.annotations["agent-os.dev/rollback-operation"] == $operation)
        | select(.metadata.annotations["agent-os.dev/rollback-target-name"] == $name)
        | select(.metadata.annotations["agent-os.dev/rollback-target-uid"] == $targetUid)
        | select(.metadata.annotations["agent-os.dev/rollback-target-digest"] == $digest)
        | select(.metadata.annotations["agent-os.dev/rollback-source-name"] == $sourceName)
        | select(.metadata.annotations["agent-os.dev/rollback-source-uid"] == $sourceUid)
        | select(.metadata.annotations["agent-os.dev/rollback-source-digest"] == $sourceDigest)
        | .metadata.resourceVersion') || { echo "error: rollback checkpoint did not persist exactly" >&2; exit 3; }
    fi
    verify_revision_service_account "$rollback_source"
    rollback_source_template=$(printf '%s' "$rollback_source" | jq -c '.data.spec.template')
    rollback_source_account=$(printf '%s' "$rollback_source" | jq -er '.data.spec.template.spec.serviceAccountName') || {
      echo "error: rollback source ServiceAccount dependency is unavailable" >&2
      exit 3
    }
    rollback_target_account=$(printf '%s' "$rollback_target" | jq -er '.data.spec.template.spec.serviceAccountName') || {
      echo "error: rollback target ServiceAccount dependency is unavailable" >&2
      exit 3
    }
    rollback_authority_mode=$(printf '%s' "$previous" | cut -f2)
    case "$rollback_authority_mode" in namespace|cluster-admin|none) ;; *) echo "error: rollback RBAC mode is unavailable" >&2; exit 3 ;; esac
    if ! transfer_runtime_authority "$rollback_authority_mode" "$rollback_source_account" "$rollback_target_account"; then
      transfer_runtime_authority "$rollback_authority_mode" "$rollback_target_account" "$rollback_source_account" || {
        echo "incomplete: rollback authority transfer failed and compensation is unverified" >&2
        exit 3
      }
      echo "error: rollback authority transfer failed before revision activation; current authority restored" >&2
      exit 3
    fi
    if [ "$rollback_mode" = patch ]; then
      rollback_patch=$(printf '%s' "$rollback_target" | jq -c --arg uid "$rollback_uid" --arg rv "$rollback_rv" \
        '.data * {metadata:{uid:$uid,resourceVersion:$rv}}')
      if ! "$KUBECTL" --context "$CONTEXT" -n "$NAMESPACE" patch StatefulSet agent-os-firstmate \
        --type=strategic -p "$rollback_patch" >/dev/null; then
        compensate_rollback "$rollback_source_template" "$rollback_source_account" "$rollback_target_account" "$rollback_authority_mode" || {
          echo "incomplete: StatefulSet rollback CAS conflicted and compensation is unverified" >&2
          exit 3
        }
        echo "error: StatefulSet rollback CAS conflicted; current revision and authority restored" >&2
        exit 3
      fi
      rollback_current=$(live_resource_record namespaced StatefulSet agent-os-firstmate)
      if [ "$(printf '%s' "$rollback_current" | cut -f1-4)" != \
        "$(printf '%s' "$rollback_record" | cut -f1-4)" ]; then
        compensate_rollback "$rollback_source_template" "$rollback_source_account" "$rollback_target_account" "$rollback_authority_mode" || {
          echo "incomplete: StatefulSet identity changed and rollback compensation is unverified" >&2
          exit 3
        }
        echo "error: StatefulSet UID or ownership changed during rollback; source revision and authority restored" >&2
        exit 3
      fi
    fi
    if ! "$KUBECTL" --context "$CONTEXT" -n "$NAMESPACE" rollout status statefulset/agent-os-firstmate --timeout=180s; then
      if compensate_rollback "$rollback_source_template" "$rollback_source_account" "$rollback_target_account" "$rollback_authority_mode"; then
        echo "incomplete: rollback readiness failed; current revision and authority restored" >&2
        exit 3
      fi
      report_rollback_failure "$rollback_target_name" "$rollback_target_revision" "$rollback_target_uid" "$rollback_target_digest" \
        "$rollback_checkpoint_operation" "$rollback_checkpoint_name" "$rollback_checkpoint_uid"
      exit 3
    fi
    rollback_verify_state=$("$KUBECTL" --context "$CONTEXT" -n "$NAMESPACE" \
      --request-timeout="${RESOURCE_REQUEST_CEILING_SECONDS}s" get statefulset agent-os-firstmate -o json) || {
      compensate_rollback "$rollback_source_template" "$rollback_source_account" "$rollback_target_account" "$rollback_authority_mode" || {
        echo "error: rollback verification evidence and compensation are unavailable; checkpoint retained target-digest=$rollback_target_digest" >&2
        exit 3
      }
      echo "incomplete: rollback verification evidence was unavailable; current revision and authority restored" >&2
      exit 3
    }
    rollback_verify_refs=$(printf '%s' "$rollback_verify_state" | jq -er \
      --arg uid "$rollback_uid" --arg installation "$INSTALLATION_ID" \
      --arg operation "$rollback_checkpoint_operation" --arg name "$rollback_checkpoint_name" \
      --arg targetUid "$rollback_checkpoint_uid" --arg digest "$rollback_target_digest" \
      --arg sourceName "$rollback_source_name" --arg sourceUid "$rollback_source_uid" --arg sourceDigest "$rollback_source_digest" '
      select(.metadata.uid == $uid)
      | select(.metadata.labels["app.kubernetes.io/managed-by"] == "agent-os")
      | select(.metadata.annotations["agent-os.dev/installation-id"] == $installation)
      | select(.metadata.annotations["agent-os.dev/rollback-operation"] == $operation)
      | select(.metadata.annotations["agent-os.dev/rollback-target-name"] == $name)
      | select(.metadata.annotations["agent-os.dev/rollback-target-uid"] == $targetUid)
      | select(.metadata.annotations["agent-os.dev/rollback-target-digest"] == $digest)
      | select(.metadata.annotations["agent-os.dev/rollback-source-name"] == $sourceName)
      | select(.metadata.annotations["agent-os.dev/rollback-source-uid"] == $sourceUid)
      | select(.metadata.annotations["agent-os.dev/rollback-source-digest"] == $sourceDigest)
      | [.status.currentRevision,.status.updateRevision,.metadata.resourceVersion] | @tsv') || {
      compensate_rollback "$rollback_source_template" "$rollback_source_account" "$rollback_target_account" "$rollback_authority_mode" || {
        echo "error: rollback verification mismatch and compensation failed; retained target-digest=$rollback_target_digest" >&2
        exit 3
      }
      echo "incomplete: rollback verification mismatch; current revision and authority restored" >&2
      exit 3
    }
    rollback_revisions=$("$KUBECTL" --context "$CONTEXT" -n "$NAMESPACE" \
      --request-timeout="${RESOURCE_REQUEST_CEILING_SECONDS}s" get controllerrevisions.apps -o json) || {
      compensate_rollback "$rollback_source_template" "$rollback_source_account" "$rollback_target_account" "$rollback_authority_mode" || {
        echo "error: rollback revision evidence and compensation are unavailable; checkpoint retained target-digest=$rollback_target_digest" >&2
        exit 3
      }
      echo "incomplete: rollback revision evidence was unavailable; current revision and authority restored" >&2
      exit 3
    }
    for rollback_verify_name in "$(printf '%s' "$rollback_verify_refs" | cut -f1)" "$(printf '%s' "$rollback_verify_refs" | cut -f2)"; do
      rollback_verify_revision=$(printf '%s' "$rollback_revisions" | jq -ce --arg name "$rollback_verify_name" --arg uid "$rollback_uid" '
        [.items[] | select(.metadata.name == $name) | select(any(.metadata.ownerReferences[]?;
          .apiVersion == "apps/v1" and .kind == "StatefulSet" and .name == "agent-os-firstmate" and .uid == $uid and .controller == true))]
        | select(length == 1) | .[0]') || {
        compensate_rollback "$rollback_source_template" "$rollback_source_account" "$rollback_target_account" "$rollback_authority_mode" || {
          echo "error: rollback revision '$rollback_verify_name' is unavailable and compensation failed" >&2
          exit 3
        }
        echo "incomplete: rollback revision '$rollback_verify_name' is unavailable; current revision and authority restored" >&2
        exit 3
      }
      rollback_verify_digest=$(printf '%s' "$rollback_verify_revision" | jq -cS '.data.spec.template' | template_digest)
      if [ "$rollback_verify_digest" != "$rollback_target_digest" ]; then
        compensate_rollback "$rollback_source_template" "$rollback_source_account" "$rollback_target_account" "$rollback_authority_mode" || {
          echo "error: rollback revision '$rollback_verify_name' content differs and compensation failed" >&2
          exit 3
        }
        echo "incomplete: rollback revision '$rollback_verify_name' content differs; current revision and authority restored" >&2
        exit 3
      fi
    done
    transfer_runtime_authority "$rollback_authority_mode" "$rollback_source_account" "$rollback_target_account" || {
      echo "error: rollback completed but runtime authority postcondition changed" >&2
      exit 3
    }
    rollback_clear_patch=$(jq -cn --arg uid "$rollback_uid" --arg rv "$(printf '%s' "$rollback_verify_refs" | cut -f3)" \
      '{metadata:{uid:$uid,resourceVersion:$rv,annotations:{"agent-os.dev/rollback-operation":null,"agent-os.dev/rollback-target-name":null,"agent-os.dev/rollback-target-uid":null,"agent-os.dev/rollback-target-digest":null,"agent-os.dev/rollback-source-name":null,"agent-os.dev/rollback-source-uid":null,"agent-os.dev/rollback-source-digest":null}}}')
    if ! "$KUBECTL" --context "$CONTEXT" -n "$NAMESPACE" patch StatefulSet agent-os-firstmate \
      --type=merge -p "$rollback_clear_patch" >/dev/null; then
      echo "error: rollback completed but checkpoint clear CAS conflicted; retained target-digest=$rollback_target_digest" >&2
      exit 3
    fi
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
    previous_service_account=
    previous_workload_uid=
    historical_service_accounts=$(inventory_owned_service_accounts) || {
      echo "error: uninstall could not recover exact-owned ServiceAccount dependencies" >&2
      exit 3
    }
    retained_legacy_service_account=
    if [ -n "$previous" ]; then
      previous_service_account=$(workload_service_account)
      previous_workload_record=$(live_resource_record namespaced StatefulSet agent-os-firstmate)
      previous_workload_uid=$(printf '%s' "$previous_workload_record" | cut -f4)
      [ -n "$previous_workload_uid" ] || { echo "error: uninstall requires exact StatefulSet UID evidence" >&2; exit 3; }
      revision_service_accounts=$(inventory_revision_service_accounts "$previous_workload_uid") || {
        echo "error: uninstall could not inventory exact historical ServiceAccount dependencies" >&2
        exit 3
      }
      historical_service_accounts=$(printf '%s\n%s\n' "$historical_service_accounts" "$revision_service_accounts" | awk 'NF && !seen[$0]++')
    fi
    legacy_identity=$(live_resource_identity ServiceAccount agent-os-firstmate)
    if [ -n "$legacy_identity" ]; then
      [ "$legacy_identity" = "agent-os-firstmate"$'\t'"agent-os"$'\t'"$INSTALLATION_ID" ] || {
        echo "error: retained legacy ServiceAccount is foreign" >&2
        exit 3
      }
      retained_legacy_service_account=agent-os-firstmate
    fi
    previous_mode=$(printf '%s' "$previous" | cut -f2)
    previous_cleanup=$(printf '%s' "$previous" | cut -f3)
    REMOVE_CONTROL_ACCESS=1
    delete_rendered_namespaced_resources
    if [ -n "$previous_workload_uid" ] || [ -n "$retained_legacy_service_account" ]; then
      wait_for_revision_history_absence "$previous_workload_uid"
    fi
    if [ -n "$previous_service_account" ] && [ "$previous_service_account" != "$SERVICE_ACCOUNT_NAME" ]; then
      delete_owned_resource namespaced ServiceAccount "$previous_service_account" 180
    fi
    if [ -n "$retained_legacy_service_account" ] && \
      [ "$retained_legacy_service_account" != "$previous_service_account" ] && \
      [ "$retained_legacy_service_account" != "$SERVICE_ACCOUNT_NAME" ]; then
      delete_owned_resource namespaced ServiceAccount "$retained_legacy_service_account" 180
    fi
    while IFS= read -r historical_service_account; do
      [ -n "$historical_service_account" ] || continue
      delete_owned_resource namespaced ServiceAccount "$historical_service_account" 180
    done <<< "$historical_service_accounts"
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
