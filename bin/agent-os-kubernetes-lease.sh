#!/usr/bin/env bash

yaml_string() {
  local value=$1
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  value=${value//$'\t'/\\t}
  printf '"%s"' "$value"
}

rfc3339_epoch() {
  local value=${1%%.*}
  value=${value%Z}Z
  date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$value" '+%s' 2>/dev/null || \
    date -u -d "$value" '+%s' 2>/dev/null
}

lease_is_expired() {
  local record=$1 renewed duration renewed_epoch now_epoch
  renewed=$(printf '%s' "$record" | cut -f7)
  duration=$(printf '%s' "$record" | cut -f8)
  case "$duration" in ''|*[!0-9]*) return 1 ;; esac
  renewed_epoch=$(rfc3339_epoch "$renewed") || return 1
  now_epoch=$(date -u '+%s')
  [ "$now_epoch" -gt "$((renewed_epoch + duration + LOCK_CLOCK_SKEW_SECONDS))" ]
}

verify_lock_record() {
  local record=$1 identity holder uid
  identity=$(printf '%s' "$record" | cut -f1-4)
  holder=$(printf '%s' "$record" | cut -f5)
  uid=$(printf '%s' "$record" | cut -f9)
  [ "$identity" = "$EXPECTED_LOCK" ] && [ "$holder" = "$OPERATION_ID" ] && [ -n "$uid" ]
}

renew_lock_once() {
  local record acquired uid rv now current
  record=$(lock_record) || return 1
  verify_lock_record "$record" || return 1
  acquired=$(printf '%s' "$record" | cut -f6)
  uid=$(printf '%s' "$record" | cut -f9)
  rv=$(printf '%s' "$record" | cut -f10)
  [ -n "$acquired" ] && [ -n "$rv" ] || return 1
  now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  render_lock "$acquired" "$now" "$uid" "$rv" | kube replace -f - >/dev/null || return 1
  current=$(lock_record) || return 1
  verify_lock_record "$current" || return 1
  [ "$(printf '%s' "$current" | cut -f9)" = "$uid" ] || return 1
  LOCK_RV=$(printf '%s' "$current" | cut -f10)
}

start_lock_renewal() {
  local parent=$$ interval=$((LOCK_DURATION_SECONDS / 3))
  (
    trap - EXIT
    sleep_pid=
    trap '[ -z "$sleep_pid" ] || kill "$sleep_pid" 2>/dev/null; exit 0' TERM INT
    while :; do
      sleep "$interval" &
      sleep_pid=$!
      wait "$sleep_pid" || exit 0
      sleep_pid=
      renew_lock_once || { kill -TERM "$parent"; exit 1; }
    done
  ) &
  LOCK_RENEW_PID=$!
}

stop_lock_renewal() {
  [ -n "$LOCK_RENEW_PID" ] || return 0
  kill "$LOCK_RENEW_PID" 2>/dev/null || true
  wait "$LOCK_RENEW_PID" 2>/dev/null || true
  LOCK_RENEW_PID=
}

release_lock() {
  local record identity holder uid rv after after_holder after_uid
  stop_lock_renewal
  [ -n "$LOCK_UID" ] || return 0
  if ! record=$(lock_record); then
    echo "error: lifecycle Lease '$LOCK' could not be verified for release" >&2
    return 1
  fi
  [ -n "$record" ] || { LOCK_UID=; LOCK_RV=; return 0; }
  identity=$(printf '%s' "$record" | cut -f1-4)
  holder=$(printf '%s' "$record" | cut -f5)
  uid=$(printf '%s' "$record" | cut -f9)
  rv=$(printf '%s' "$record" | cut -f10)
  if [ "$identity" != "$EXPECTED_LOCK" ] || [ "$holder" != "$OPERATION_ID" ] || \
    [ "$uid" != "$LOCK_UID" ] || [ -z "$rv" ]; then
    echo "error: lifecycle Lease '$LOCK' changed ownership before release; retained" >&2
    return 1
  fi
  if ! printf '{"apiVersion":"v1","kind":"DeleteOptions","preconditions":{"uid":"%s","resourceVersion":"%s"}}\n' "$uid" "$rv" | \
    kube delete --raw "/apis/coordination.k8s.io/v1/namespaces/$LOCK_NAMESPACE/leases/$LOCK" -f - >/dev/null; then
    echo "error: lifecycle Lease '$LOCK' release precondition failed; retained" >&2
    return 1
  fi
  after=$(lock_record) || return 1
  if [ -n "$after" ]; then
    after_holder=$(printf '%s' "$after" | cut -f5)
    after_uid=$(printf '%s' "$after" | cut -f9)
    if [ "$after_uid" = "$uid" ] && [ "$after_holder" = "$OPERATION_ID" ]; then
      echo "error: lifecycle Lease '$LOCK' still exists after release" >&2
      return 1
    fi
  fi
  LOCK_UID=
  LOCK_RV=
}

acquire_lock() {
  local record identity holder now deadline acquired uid rv current
  now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  deadline=$(($(date -u '+%s') + LOCK_ACQUIRE_SECONDS))
  while ! render_lock "$now" "$now" | kube create -f - >/dev/null; do
    record=$(lock_record)
    identity=$(printf '%s' "$record" | cut -f1-4)
    holder=$(printf '%s' "$record" | cut -f5)
    if [ -z "$record" ] || [ "$identity" != "$EXPECTED_LOCK" ]; then
      echo "error: lifecycle Lease '$LOCK' is absent or has foreign ownership after create conflict" >&2
      exit 2
    fi
    if lease_is_expired "$record"; then
      uid=$(printf '%s' "$record" | cut -f9)
      rv=$(printf '%s' "$record" | cut -f10)
      if [ -z "$uid" ] || [ -z "$rv" ]; then
        echo "error: expired lifecycle Lease '$LOCK' lacks CAS identity" >&2
        exit 2
      fi
      now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
      if render_lock "$now" "$now" "$uid" "$rv" | kube replace -f - >/dev/null; then
        break
      fi
    fi
    if [ "$(date -u '+%s')" -ge "$deadline" ]; then
      echo "error: lifecycle operation '$holder' still holds Lease '$LOCK' after ${LOCK_ACQUIRE_SECONDS}s" >&2
      exit 3
    fi
    sleep 1
    now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  done
  record=$(lock_record)
  if ! verify_lock_record "$record"; then
    LOCK_UID=
    echo "error: lifecycle Lease '$LOCK' did not verify after acquisition" >&2
    exit 2
  fi
  acquired=$(printf '%s' "$record" | cut -f6)
  LOCK_UID=$(printf '%s' "$record" | cut -f9)
  LOCK_RV=$(printf '%s' "$record" | cut -f10)
  if [ -z "$acquired" ] || [ -z "$LOCK_RV" ]; then
    LOCK_UID=
    echo "error: lifecycle Lease '$LOCK' lacks complete renewal evidence" >&2
    exit 2
  fi
  current=$(lock_record)
  if [ "$current" != "$record" ]; then
    LOCK_UID=
    echo "error: lifecycle Lease '$LOCK' changed after acquisition" >&2
    exit 3
  fi
  start_lock_renewal
}

lock_renewal_failed() {
  echo "error: lifecycle Lease '$LOCK' renewal failed; operation stopped" >&2
  exit 3
}
