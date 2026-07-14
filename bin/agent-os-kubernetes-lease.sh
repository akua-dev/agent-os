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

lock_default_deadline() {
  printf '%s' "$(($(date -u '+%s') + LOCK_REQUEST_CEILING_SECONDS))"
}

lock_request_seconds() {
  local deadline=$1 now remaining validity seconds
  now=$(date -u '+%s')
  remaining=$((deadline - now))
  [ "$remaining" -gt 0 ] || return 1
  validity=$((LOCK_DURATION_SECONDS / 3))
  [ "$validity" -gt 0 ] || validity=1
  seconds=$LOCK_REQUEST_CEILING_SECONDS
  [ "$seconds" -le "$validity" ] || seconds=$validity
  [ "$seconds" -le "$remaining" ] || seconds=$remaining
  [ "$seconds" -gt 0 ] || return 1
  printf '%s' "$seconds"
}

lock_kube() {
  local deadline=$1 seconds
  shift
  seconds=$(lock_request_seconds "$deadline") || return 124
  kube --request-timeout="${seconds}s" "$@"
}

lock_mutation_seconds() {
  local deadline=$1 now remaining validity seconds
  now=$(date -u '+%s')
  remaining=$((deadline - now - 1))
  [ "$remaining" -gt 0 ] || return 1
  validity=$((LOCK_DURATION_SECONDS / 3))
  [ "$validity" -gt 0 ] || validity=1
  seconds=$LOCK_REQUEST_CEILING_SECONDS
  [ "$seconds" -le "$validity" ] || seconds=$validity
  [ "$seconds" -le "$remaining" ] || seconds=$remaining
  [ "$seconds" -gt 0 ] || return 1
  printf '%s' "$seconds"
}

lock_kube_mutation() {
  local deadline=$1 seconds
  shift
  seconds=$(lock_mutation_seconds "$deadline") || return 124
  kube --request-timeout="${seconds}s" "$@"
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

lock_record_valid_until() {
  local record=$1 renewed duration renewed_epoch margin
  renewed=$(printf '%s' "$record" | cut -f7)
  duration=$(printf '%s' "$record" | cut -f8)
  case "$duration" in ''|*[!0-9]*) return 1 ;; esac
  renewed_epoch=$(rfc3339_epoch "$renewed") || return 1
  margin=$LOCK_CLOCK_SKEW_SECONDS
  [ "$margin" -le "$((duration / 3))" ] || margin=$((duration / 3))
  [ "$margin" -gt 0 ] || margin=1
  printf '%s' "$((renewed_epoch + duration - margin))"
}

renew_lock_once() {
  local record acquired uid rv now current initial_deadline deadline
  initial_deadline=$(lock_default_deadline)
  if [ -n "${LOCK_VALID_UNTIL:-}" ] && [ "$LOCK_VALID_UNTIL" -lt "$initial_deadline" ]; then
    initial_deadline=$LOCK_VALID_UNTIL
  fi
  record=$(lock_record "$initial_deadline") || return 1
  verify_lock_record "$record" || return 1
  acquired=$(printf '%s' "$record" | cut -f6)
  uid=$(printf '%s' "$record" | cut -f9)
  rv=$(printf '%s' "$record" | cut -f10)
  [ -n "$acquired" ] && [ -n "$rv" ] || return 1
  deadline=$(lock_record_valid_until "$record") || return 1
  [ "$deadline" -gt "$(date -u '+%s')" ] || return 1
  now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  render_lock "$acquired" "$now" "$uid" "$rv" | lock_kube_mutation "$deadline" replace -f - >/dev/null || true
  current=$(lock_record "$deadline") || return 1
  verify_lock_record "$current" || return 1
  [ "$(printf '%s' "$current" | cut -f9)" = "$uid" ] || return 1
  [ "$(printf '%s' "$current" | cut -f10)" != "$rv" ] || return 1
  [ "$(printf '%s' "$current" | cut -f7)" = "$now" ] || return 1
  LOCK_RV=$(printf '%s' "$current" | cut -f10)
  LOCK_VALID_UNTIL=$(lock_record_valid_until "$current") || return 1
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
  local record identity holder uid rv after after_holder after_uid deadline
  stop_lock_renewal
  [ -n "$LOCK_UID" ] || return 0
  deadline=$(lock_default_deadline)
  if ! record=$(lock_record "$deadline"); then
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
    lock_kube_mutation "$deadline" delete --raw "/apis/coordination.k8s.io/v1/namespaces/$LOCK_NAMESPACE/leases/$LOCK" -f - >/dev/null; then
    after=$(lock_record "$deadline") || {
      echo "error: lifecycle Lease '$LOCK' release result is ambiguous; retained" >&2
      return 1
    }
    if [ -n "$after" ] && [ "$(printf '%s' "$after" | cut -f9)" = "$uid" ] && \
      [ "$(printf '%s' "$after" | cut -f5)" = "$OPERATION_ID" ]; then
      echo "error: lifecycle Lease '$LOCK' release precondition failed; retained" >&2
      return 1
    fi
    LOCK_UID=
    LOCK_RV=
    return 0
  fi
  after=$(lock_record "$deadline") || return 1
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
  local record identity holder now deadline acquired uid rv current mutation_ok
  now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  deadline=$(($(date -u '+%s') + LOCK_ACQUIRE_SECONDS))
  holder=unknown
  while :; do
    if [ "$(date -u '+%s')" -ge "$deadline" ]; then
      echo "error: lifecycle operation '$holder' still holds Lease '$LOCK' after ${LOCK_ACQUIRE_SECONDS}s" >&2
      exit 3
    fi
    mutation_ok=0
    render_lock "$now" "$now" | lock_kube_mutation "$deadline" create -f - >/dev/null && mutation_ok=1
    record=$(lock_record "$deadline") || {
      echo "error: lifecycle Lease '$LOCK' create result could not be reconciled before the acquisition deadline" >&2
      exit 3
    }
    identity=$(printf '%s' "$record" | cut -f1-4)
    holder=$(printf '%s' "$record" | cut -f5)
    if [ -z "$record" ] || [ "$identity" != "$EXPECTED_LOCK" ]; then
      echo "error: lifecycle Lease '$LOCK' is absent or has foreign ownership after create conflict" >&2
      exit 2
    fi
    if verify_lock_record "$record" && [ "$(printf '%s' "$record" | cut -f6)" = "$now" ] && \
      [ "$(printf '%s' "$record" | cut -f7)" = "$now" ]; then
      break
    fi
    [ "$mutation_ok" -eq 0 ] || {
      echo "error: lifecycle Lease '$LOCK' create acknowledgement did not verify exact timestamps" >&2
      exit 3
    }
    if lease_is_expired "$record"; then
      uid=$(printf '%s' "$record" | cut -f9)
      rv=$(printf '%s' "$record" | cut -f10)
      if [ -z "$uid" ] || [ -z "$rv" ]; then
        echo "error: expired lifecycle Lease '$LOCK' lacks CAS identity" >&2
        exit 2
      fi
      now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
      mutation_ok=0
      render_lock "$now" "$now" "$uid" "$rv" | lock_kube_mutation "$deadline" replace -f - >/dev/null && mutation_ok=1
      record=$(lock_record "$deadline") || {
        echo "error: lifecycle Lease '$LOCK' takeover result could not be reconciled before the acquisition deadline" >&2
        exit 3
      }
      if verify_lock_record "$record" && [ "$(printf '%s' "$record" | cut -f9)" = "$uid" ] && \
        [ "$(printf '%s' "$record" | cut -f10)" != "$rv" ] && \
        [ "$(printf '%s' "$record" | cut -f7)" = "$now" ]; then
        break
      fi
      [ "$mutation_ok" -eq 0 ] || {
        echo "error: lifecycle Lease '$LOCK' takeover acknowledgement did not verify exact renewal evidence" >&2
        exit 3
      }
    fi
    if [ "$(date -u '+%s')" -ge "$deadline" ]; then
      echo "error: lifecycle operation '$holder' still holds Lease '$LOCK' after ${LOCK_ACQUIRE_SECONDS}s" >&2
      exit 3
    fi
    sleep 1
    now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  done
  record=$(lock_record "$deadline")
  if ! verify_lock_record "$record"; then
    LOCK_UID=
    echo "error: lifecycle Lease '$LOCK' did not verify after acquisition" >&2
    exit 2
  fi
  acquired=$(printf '%s' "$record" | cut -f6)
  LOCK_UID=$(printf '%s' "$record" | cut -f9)
  LOCK_RV=$(printf '%s' "$record" | cut -f10)
  LOCK_VALID_UNTIL=$(lock_record_valid_until "$record") || {
    LOCK_UID=
    echo "error: lifecycle Lease '$LOCK' lacks a valid renewal deadline" >&2
    exit 2
  }
  if [ -z "$acquired" ] || [ -z "$LOCK_RV" ]; then
    LOCK_UID=
    echo "error: lifecycle Lease '$LOCK' lacks complete renewal evidence" >&2
    exit 2
  fi
  current=$(lock_record "$deadline")
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
