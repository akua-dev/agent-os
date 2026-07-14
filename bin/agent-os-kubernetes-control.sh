#!/usr/bin/env bash

control_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}

configure_control_lock() {
  local digest
  CONTROL_NAMESPACE=${AGENT_OS_CONTROL_NAMESPACE:-kube-system}
  case "$CONTROL_NAMESPACE" in ''|*[!a-z0-9-]*|-*|*-) echo "error: invalid lifecycle control namespace" >&2; exit 2 ;; esac
  [ "${#CONTROL_NAMESPACE}" -le 63 ] || { echo "error: lifecycle control namespace is too long" >&2; exit 2; }
  digest=$(printf 'agent-os-installation:%s' "$NAMESPACE" | control_sha256)
  CONTROL_INSTALLATION_UUID="${digest:0:8}-${digest:8:4}-5${digest:13:3}-8${digest:17:3}-${digest:20:12}"
  CONTROL_LOCK="agent-os-lifecycle-${digest:0:16}"
  CONTROL_LOCK_INSTALLATION_ID="agent-os-control:$CONTROL_INSTALLATION_UUID"
}
