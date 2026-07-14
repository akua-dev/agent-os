#!/usr/bin/env bash
set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
COMMAND=${1:-}
SECRET=${2:-}
CONTEXT=${AGENT_OS_CONTEXT:-}
NAMESPACE=${AGENT_OS_NAMESPACE:-}
KUBECTL=${AGENT_OS_KUBECTL:-kubectl}
INSTALLATION_ID="agent-os-firstmate:$NAMESPACE"
OPERATION_ID=${AGENT_OS_OPERATION_ID:-"$(date -u '+%Y%m%d%H%M%S')-$$-$RANDOM"}
LOCK_NONCE=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
LOCK_HOLDER_ID="$OPERATION_ID.$LOCK_NONCE"
LOCK=agent-os-firstmate-lifecycle
LOCK_NAMESPACE=$NAMESPACE
EXPECTED_LOCK="$LOCK"$'\t'"agent-os"$'\t'"primary"$'\t'"$INSTALLATION_ID"
LOCK_UID=
LOCK_RV=
LOCK_RENEW_PID=
LOCK_DURATION_SECONDS=${AGENT_OS_LOCK_DURATION_SECONDS:-300}
LOCK_CLOCK_SKEW_SECONDS=${AGENT_OS_LOCK_CLOCK_SKEW_SECONDS:-5}
LOCK_ACQUIRE_SECONDS=${AGENT_OS_LOCK_ACQUIRE_SECONDS:-30}
LOCK_REQUEST_CEILING_SECONDS=${AGENT_OS_LOCK_REQUEST_CEILING_SECONDS:-5}
RESOURCE_REQUEST_CEILING_SECONDS=${AGENT_OS_RESOURCE_REQUEST_CEILING_SECONDS:-5}

case "$COMMAND" in grant|revoke) ;; *) echo "usage: $0 grant|revoke <secret-name>" >&2; exit 2 ;; esac
[ -n "$CONTEXT" ] && [ -n "$NAMESPACE" ] || { echo "error: set AGENT_OS_CONTEXT and AGENT_OS_NAMESPACE" >&2; exit 2; }
case "$SECRET" in ''|*[!a-z0-9.-]*|[.-]*|*[-.]) echo "error: invalid Akua authorization Secret name" >&2; exit 2 ;; esac
[ "${#SECRET}" -le 253 ] || { echo "error: invalid Akua authorization Secret name" >&2; exit 2; }
case "$NAMESPACE" in ''|*[!a-z0-9-]*|-*|*-) echo "error: invalid Kubernetes namespace" >&2; exit 2 ;; esac
[ "${#NAMESPACE}" -le 63 ] && [ "${#LOCK_HOLDER_ID}" -le 255 ] || { echo "error: derived Kubernetes identity is too long" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 2; }

kube() {
  "$KUBECTL" --context "$CONTEXT" -n "$NAMESPACE" "$@"
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
  namespace: $NAMESPACE
${uid:+  uid: $uid_value}
${rv:+  resourceVersion: $rv_value}
  labels:
    app.kubernetes.io/managed-by: agent-os
    agent-os.dev/lifecycle: primary
  annotations:
    agent-os.dev/installation-id: $INSTALLATION_ID
spec:
  holderIdentity: $LOCK_HOLDER_ID
  acquireTime: $acquired_at
  renewTime: $renewed_at
  leaseDurationSeconds: $LOCK_DURATION_SECONDS
YAML
}

. "$ROOT/bin/agent-os-kubernetes-lease.sh"

cleanup() {
  local status=$?
  trap - EXIT
  if ! release_lock && [ "$status" -eq 0 ]; then
    status=3
  fi
  [ -z "${PATCH_FILE:-}" ] || rm -f "$PATCH_FILE"
  exit "$status"
}
trap cleanup EXIT
trap lock_renewal_failed TERM

secret_record() {
  kube --request-timeout="${RESOURCE_REQUEST_CEILING_SECONDS}s" get secret "$SECRET" --ignore-not-found \
    -o 'jsonpath={.metadata.name}{"\t"}{.metadata.uid}{"\t"}{.metadata.resourceVersion}{"\t"}{range $key,$value := .data}{$key}{"\n"}{end}'
}

statefulset_json() {
  kube --request-timeout="${RESOURCE_REQUEST_CEILING_SECONDS}s" get statefulset agent-os-firstmate -o json
}

verify_overlay() {
  local expected=$1 state_uid=$2 state pod secret_record_after
  state=$(statefulset_json)
  printf '%s' "$state" | jq -e --arg installation "$INSTALLATION_ID" --arg secret "$SECRET" \
    --arg uid "$state_uid" --arg expected "$expected" '
      .metadata.name == "agent-os-firstmate" and .metadata.uid == $uid and
      .metadata.labels["app.kubernetes.io/managed-by"] == "agent-os" and
      .metadata.annotations["agent-os.dev/installation-id"] == $installation and
      (if $expected == "present" then
        .metadata.annotations["agent-os.dev/akua-auth-secret"] == $secret and
        ([.spec.template.spec.containers[] | select(.name == "firstmate") | .env[] | select(.name == "AKUA_AUTH_HEADER_FILE" and .value == "/var/run/secrets/agent-os/akua/authorization")] | length) == 1 and
        ([.spec.template.spec.containers[] | select(.name == "firstmate") | .volumeMounts[] | select(.name == "akua-auth" and .mountPath == "/var/run/secrets/agent-os/akua" and .readOnly == true)] | length) == 1 and
        ([.spec.template.spec.volumes[] | select(.name == "akua-auth" and .secret.secretName == $secret and .secret.defaultMode == 256)] | length) == 1
      else
        (.metadata.annotations["agent-os.dev/akua-auth-secret"] // "") == "" and
        ([.spec.template.spec.containers[] | select(.name == "firstmate") | .env[]? | select(.name == "AKUA_AUTH_HEADER_FILE")] | length) == 0 and
        ([.spec.template.spec.containers[] | select(.name == "firstmate") | .volumeMounts[]? | select(.name == "akua-auth")] | length) == 0 and
        ([.spec.template.spec.volumes[]? | select(.name == "akua-auth")] | length) == 0
      end)' >/dev/null || { echo "error: Akua authorization overlay verification failed" >&2; exit 3; }
  secret_record_after=$(secret_record)
  [ "$secret_record_after" = "$SECRET_RECORD" ] || { echo "error: Akua authorization Secret reference changed during mutation" >&2; exit 3; }
  pod=$(kube --request-timeout="${RESOURCE_REQUEST_CEILING_SECONDS}s" get pod agent-os-firstmate-0 -o json)
  printf '%s' "$pod" | jq -e --arg uid "$state_uid" --arg secret "$SECRET" --arg expected "$expected" '
    any(.metadata.ownerReferences[]?; .apiVersion == "apps/v1" and .kind == "StatefulSet" and .name == "agent-os-firstmate" and .uid == $uid and .controller == true) and
    (if $expected == "present" then
      ([.spec.containers[] | select(.name == "firstmate") | .env[] | select(.name == "AKUA_AUTH_HEADER_FILE" and .value == "/var/run/secrets/agent-os/akua/authorization")] | length) == 1 and
      ([.spec.containers[] | select(.name == "firstmate") | .volumeMounts[] | select(.name == "akua-auth" and .mountPath == "/var/run/secrets/agent-os/akua" and .readOnly == true)] | length) == 1 and
      ([.spec.volumes[] | select(.name == "akua-auth" and .secret.secretName == $secret and .secret.defaultMode == 256)] | length) == 1
    else
      ([.spec.containers[] | select(.name == "firstmate") | .env[]? | select(.name == "AKUA_AUTH_HEADER_FILE")] | length) == 0 and
      ([.spec.containers[] | select(.name == "firstmate") | .volumeMounts[]? | select(.name == "akua-auth")] | length) == 0 and
      ([.spec.volumes[]? | select(.name == "akua-auth")] | length) == 0
    end)' >/dev/null || { echo "error: Firstmate Pod authorization overlay verification failed" >&2; exit 3; }
}

SECRET_RECORD=$(secret_record)
[ "$(printf '%s' "$SECRET_RECORD" | cut -f1)" = "$SECRET" ] && \
  [ -n "$(printf '%s' "$SECRET_RECORD" | cut -f2)" ] && [ -n "$(printf '%s' "$SECRET_RECORD" | cut -f3)" ] && \
  [ "$(printf '%s' "$SECRET_RECORD" | cut -f4-)" = authorization ] || {
  echo "error: Akua authorization Secret reference is missing or unverifiable" >&2
  exit 2
}

acquire_lock
STATE=$(statefulset_json)
STATE_UID=$(printf '%s' "$STATE" | jq -er --arg installation "$INSTALLATION_ID" '
  select(.metadata.name == "agent-os-firstmate")
  | select(.metadata.labels["app.kubernetes.io/managed-by"] == "agent-os")
  | select(.metadata.annotations["agent-os.dev/installation-id"] == $installation)
  | .metadata.uid') || { echo "error: StatefulSet ownership is unverifiable" >&2; exit 2; }
STATE_RV=$(printf '%s' "$STATE" | jq -er '.metadata.resourceVersion') || { echo "error: StatefulSet resourceVersion is unavailable" >&2; exit 2; }

PATCH_FILE=$(mktemp)
TEMPLATE="$ROOT/deploy/akua/firstmate-auth-$COMMAND.yaml"
uid_value=$(yaml_string "$STATE_UID")
rv_value=$(yaml_string "$STATE_RV")
sed "s/__AKUA_AUTH_SECRET__/$SECRET/g" "$TEMPLATE" | awk -v uid="$uid_value" -v rv="$rv_value" '
  $1 == "metadata:" && !inserted { print; print "  uid: " uid; print "  resourceVersion: " rv; inserted=1; next }
  { print }
' > "$PATCH_FILE"
kube patch statefulset agent-os-firstmate --type=strategic --patch-file "$PATCH_FILE" >/dev/null
kube rollout status statefulset/agent-os-firstmate --timeout=180s
if [ "$COMMAND" = grant ]; then
  verify_overlay present "$STATE_UID"
else
  verify_overlay absent "$STATE_UID"
fi
