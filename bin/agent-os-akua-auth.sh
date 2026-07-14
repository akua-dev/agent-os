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
LOCK=
LOCK_NAMESPACE=
LOCK_INSTALLATION_ID=
EXPECTED_LOCK=
LOCK_UID=
LOCK_RV=
LOCK_RENEW_PID=
LOCK_PERSISTENT=0
CONTROL_LOCK_UID=
CONTROL_LOCK_RV=
CONTROL_LOCK_RENEW_PID=
CONTROL_LOCK_VALID_UNTIL=
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
  "$KUBECTL" --context "$CONTEXT" -n "$LOCK_NAMESPACE" "$@"
}

target_kube() {
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
  namespace: $LOCK_NAMESPACE
${uid:+  uid: $uid_value}
${rv:+  resourceVersion: $rv_value}
  labels:
    app.kubernetes.io/managed-by: agent-os
    agent-os.dev/lifecycle: primary
  annotations:
    agent-os.dev/installation-id: $LOCK_INSTALLATION_ID
spec:
  holderIdentity: $LOCK_HOLDER_ID
  acquireTime: $acquired_at
  renewTime: $renewed_at
  leaseDurationSeconds: $LOCK_DURATION_SECONDS
YAML
}

. "$ROOT/bin/agent-os-kubernetes-control.sh"
. "$ROOT/bin/agent-os-kubernetes-lease.sh"

cleanup() {
  local status=$?
  trap - EXIT
  if ! release_lock && [ "$status" -eq 0 ]; then
    status=3
  fi
  if [ -n "$CONTROL_LOCK_UID" ]; then
    LOCK=$CONTROL_LOCK
    LOCK_NAMESPACE=$CONTROL_NAMESPACE
    LOCK_INSTALLATION_ID=$CONTROL_LOCK_INSTALLATION_ID
    EXPECTED_LOCK="$LOCK"$'\t'"agent-os"$'\t'"primary"$'\t'"$LOCK_INSTALLATION_ID"
    LOCK_UID=$CONTROL_LOCK_UID
    LOCK_RV=$CONTROL_LOCK_RV
    LOCK_RENEW_PID=$CONTROL_LOCK_RENEW_PID
    LOCK_VALID_UNTIL=$CONTROL_LOCK_VALID_UNTIL
    LOCK_PERSISTENT=1
    release_lock || [ "$status" -ne 0 ] || status=3
  fi
  [ -z "${PATCH_FILE:-}" ] || rm -f "$PATCH_FILE"
  exit "$status"
}
trap cleanup EXIT
trap lock_renewal_failed TERM

secret_record() {
  target_kube --request-timeout="${RESOURCE_REQUEST_CEILING_SECONDS}s" get secret "$SECRET" --ignore-not-found \
    -o 'jsonpath={.metadata.name}{"\t"}{.metadata.uid}{"\t"}{.metadata.resourceVersion}{"\t"}{range $key,$value := .data}{$key}{"\n"}{end}'
}

statefulset_json() {
  target_kube --request-timeout="${RESOURCE_REQUEST_CEILING_SECONDS}s" get statefulset agent-os-firstmate -o json
}

require_no_active_rollback_checkpoint() {
  local checkpoint
  checkpoint=$(printf '%s' "$STATE" | jq -er '
    [(.metadata.annotations["agent-os.dev/rollback-operation"] // ""),
     (.metadata.annotations["agent-os.dev/rollback-target-name"] // ""),
     (.metadata.annotations["agent-os.dev/rollback-target-uid"] // ""),
     (.metadata.annotations["agent-os.dev/rollback-target-digest"] // ""),
     (.metadata.annotations["agent-os.dev/rollback-source-name"] // ""),
     (.metadata.annotations["agent-os.dev/rollback-source-uid"] // ""),
     (.metadata.annotations["agent-os.dev/rollback-source-digest"] // "")]
    | @tsv') || { echo "error: StatefulSet rollback checkpoint state is unverifiable" >&2; exit 3; }
  [ -z "${checkpoint//$'\t'/}" ] || {
    echo "error: active rollback checkpoint blocks authorization mutation" >&2
    exit 3
  }
}

sha256_text() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}

verify_overlay() {
  local expected=$1 state_uid=$2 verify_secret=${3:-1} state pod secret_record_after
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
      end)' >/dev/null || { echo "error: Akua authorization overlay verification failed" >&2; return 3; }
  if [ "$verify_secret" -eq 1 ]; then
    secret_record_after=$(secret_record)
    [ "$secret_record_after" = "$SECRET_RECORD" ] || {
    echo "incomplete: Akua authorization Secret identity changed after rollout" >&2
      return 4
    }
  fi
  pod=$(target_kube --request-timeout="${RESOURCE_REQUEST_CEILING_SECONDS}s" get pod agent-os-firstmate-0 -o json)
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
    end)' >/dev/null || { echo "error: Firstmate Pod authorization overlay verification failed" >&2; return 3; }
}

reconcile_failed_grant() {
  local state uid rv revoke_patch observed rejected patch
  state=$(statefulset_json) || return 3
  uid=$(printf '%s' "$state" | jq -er --arg installation "$INSTALLATION_ID" --arg uid "$STATE_UID" '
    select(.metadata.name == "agent-os-firstmate" and .metadata.uid == $uid)
    | select(.metadata.labels["app.kubernetes.io/managed-by"] == "agent-os")
    | select(.metadata.annotations["agent-os.dev/installation-id"] == $installation)
    | .metadata.uid') || return 3
  rv=$(printf '%s' "$state" | jq -er '.metadata.resourceVersion') || return 3
  revoke_patch=$(mktemp)
  sed "s/__AKUA_AUTH_SECRET__/$SECRET/g" "$ROOT/deploy/akua/firstmate-auth-revoke.yaml" | \
    awk -v uid="$(yaml_string "$uid")" -v rv="$(yaml_string "$rv")" '
      $1 == "metadata:" && !inserted { print; print "  uid: " uid; print "  resourceVersion: " rv; inserted=1; next }
      { print }
    ' > "$revoke_patch"
  if ! target_kube patch statefulset agent-os-firstmate --type=strategic --patch-file "$revoke_patch" >/dev/null; then
    rm -f "$revoke_patch"
    return 3
  fi
  rm -f "$revoke_patch"
  target_kube rollout status statefulset/agent-os-firstmate --timeout=180s || return 3
  verify_overlay absent "$STATE_UID" 0 || return 3
  observed=$(secret_record 2>/dev/null || true)
  rejected=$(printf '%s' "$SECRET_RECORD" | sha256_text)
  state=$(statefulset_json) || return 3
  rv=$(printf '%s' "$state" | jq -er --arg uid "$STATE_UID" 'select(.metadata.uid == $uid) | .metadata.resourceVersion') || return 3
  patch=$(jq -cn --arg uid "$STATE_UID" --arg rv "$rv" --arg rejected "$rejected" \
    '{metadata:{uid:$uid,resourceVersion:$rv,annotations:{"agent-os.dev/akua-auth-rejected-record":$rejected}}}')
  target_kube patch statefulset agent-os-firstmate --type=merge -p "$patch" >/dev/null || return 3
  printf 'incomplete: grant failed closed expected-secret-uid=%s expected-secret-rv=%s observed-secret-uid=%s observed-secret-rv=%s\n' \
    "$(printf '%s' "$SECRET_RECORD" | cut -f2)" "$(printf '%s' "$SECRET_RECORD" | cut -f3)" \
    "$(printf '%s' "$observed" | cut -f2)" "$(printf '%s' "$observed" | cut -f3)" >&2
}

fail_grant_closed() {
  local reason=$1
  reconcile_failed_grant || {
    echo "incomplete: $reason and fail-closed reconciliation is unverified" >&2
    exit 3
  }
  echo "incomplete: $reason; authorization overlay removed and rejected identity retained" >&2
  echo "safe recovery: inspect the named Secret metadata, then run revoke before a new grant" >&2
  exit 3
}

configure_control_lock
LOCK=$CONTROL_LOCK
LOCK_NAMESPACE=$CONTROL_NAMESPACE
LOCK_INSTALLATION_ID=$CONTROL_LOCK_INSTALLATION_ID
LOCK_PERSISTENT=1
EXPECTED_LOCK="$LOCK"$'\t'"agent-os"$'\t'"primary"$'\t'"$LOCK_INSTALLATION_ID"
acquire_lock
CONTROL_LOCK_UID=$LOCK_UID
CONTROL_LOCK_RV=$LOCK_RV
CONTROL_LOCK_RENEW_PID=$LOCK_RENEW_PID
CONTROL_LOCK_VALID_UNTIL=$LOCK_VALID_UNTIL
LOCK=agent-os-firstmate-lifecycle
LOCK_NAMESPACE=$NAMESPACE
LOCK_INSTALLATION_ID=$INSTALLATION_ID
EXPECTED_LOCK="$LOCK"$'\t'"agent-os"$'\t'"primary"$'\t'"$LOCK_INSTALLATION_ID"
LOCK_UID=
LOCK_RV=
LOCK_RENEW_PID=
LOCK_VALID_UNTIL=
LOCK_PERSISTENT=0
acquire_lock

SECRET_RECORD=
if [ "$COMMAND" = grant ]; then
  SECRET_RECORD=$(secret_record)
  [ "$(printf '%s' "$SECRET_RECORD" | cut -f1)" = "$SECRET" ] && \
    [ -n "$(printf '%s' "$SECRET_RECORD" | cut -f2)" ] && [ -n "$(printf '%s' "$SECRET_RECORD" | cut -f3)" ] && \
    [ "$(printf '%s' "$SECRET_RECORD" | cut -f4-)" = authorization ] || {
    echo "error: Akua authorization Secret reference is missing or unverifiable" >&2
    exit 2
  }
fi

STATE=$(statefulset_json)
STATE_UID=$(printf '%s' "$STATE" | jq -er --arg installation "$INSTALLATION_ID" '
  select(.metadata.name == "agent-os-firstmate")
  | select(.metadata.labels["app.kubernetes.io/managed-by"] == "agent-os")
  | select(.metadata.annotations["agent-os.dev/installation-id"] == $installation)
  | .metadata.uid') || { echo "error: StatefulSet ownership is unverifiable" >&2; exit 2; }
STATE_RV=$(printf '%s' "$STATE" | jq -er '.metadata.resourceVersion') || { echo "error: StatefulSet resourceVersion is unavailable" >&2; exit 2; }
require_no_active_rollback_checkpoint
if [ "$COMMAND" = grant ] && [ -n "$(printf '%s' "$STATE" | jq -r '.metadata.annotations["agent-os.dev/akua-auth-rejected-record"] // empty')" ]; then
  echo "error: a rejected Secret identity is recorded; run revoke before approving a new grant" >&2
  exit 3
fi

PATCH_FILE=$(mktemp)
TEMPLATE="$ROOT/deploy/akua/firstmate-auth-$COMMAND.yaml"
uid_value=$(yaml_string "$STATE_UID")
rv_value=$(yaml_string "$STATE_RV")
sed "s/__AKUA_AUTH_SECRET__/$SECRET/g" "$TEMPLATE" | awk -v uid="$uid_value" -v rv="$rv_value" '
  $1 == "metadata:" && !inserted { print; print "  uid: " uid; print "  resourceVersion: " rv; inserted=1; next }
  { print }
' > "$PATCH_FILE"
if [ "$COMMAND" = grant ]; then
  [ "$(secret_record)" = "$SECRET_RECORD" ] || {
    echo "error: Akua authorization Secret identity changed before StatefulSet CAS" >&2
    exit 3
  }
fi
if ! target_kube patch statefulset agent-os-firstmate --type=strategic --patch-file "$PATCH_FILE" >/dev/null; then
  [ "$COMMAND" != grant ] || fail_grant_closed "grant CAS failed ambiguously"
  echo "error: revoke CAS failed" >&2
  exit 3
fi
if ! target_kube rollout status statefulset/agent-os-firstmate --timeout=180s; then
  [ "$COMMAND" != grant ] || fail_grant_closed "grant rollout failed"
  echo "incomplete: revoke rollout failed" >&2
  exit 3
fi
if [ "$COMMAND" = grant ]; then
  if ! verify_overlay present "$STATE_UID"; then
    fail_grant_closed "grant verification failed"
  fi
else
  verify_overlay absent "$STATE_UID"
fi
