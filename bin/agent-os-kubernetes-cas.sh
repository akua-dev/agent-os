#!/usr/bin/env bash

agent_os_identity_token() {
  local identity=$1 expected=$2 resource=$3 name=$4 uid rest resource_version ownership
  uid=${identity%%|*}
  [ -n "$uid" ] || return 0
  rest=${identity#*|}
  resource_version=${rest%%|*}
  ownership=${rest#*|}
  if [ -z "$resource_version" ] || [ "$ownership" != "$expected" ]; then
    echo "error: refusing to operate on unowned $resource/$name (identity: $ownership)" >&2
    return 1
  fi
  printf '%s|%s\n' "$uid" "$resource_version"
}

agent_os_cas_manifest() {
  local source=$1 target=$2 token=$3 uid resource_version
  uid=${token%%|*}
  resource_version=${token#*|}
  awk -v uid="$uid" -v resource_version="$resource_version" '
    /^metadata:$/ {
      print
      print "  uid: \"" uid "\""
      print "  resourceVersion: \"" resource_version "\""
      metadata = 1
      found = 1
      next
    }
    metadata && /^  (uid|resourceVersion):/ { next }
    metadata && !/^  / && !/^[[:space:]]*$/ { metadata = 0 }
    { print }
    END { if (!found) exit 1 }
  ' "$source" > "$target"
}

agent_os_reconcile() {
  local scope=$1 resource=$2 name=$3 manifest=$4 token=$5 cas_manifest
  if [ -z "$token" ]; then
    if [ "$scope" = namespaced ]; then
      "$KUBECTL" "${KUBECTL_ARGS[@]}" -n "$NAMESPACE" create -f "$manifest"
    else
      "$KUBECTL" "${KUBECTL_ARGS[@]}" create -f "$manifest"
    fi
    return
  fi
  cas_manifest="$OUT/cas-${resource}-${name}.yaml"
  agent_os_cas_manifest "$manifest" "$cas_manifest" "$token"
  if [ "$scope" = namespaced ]; then
    "$KUBECTL" "${KUBECTL_ARGS[@]}" -n "$NAMESPACE" patch "$resource" "$name" \
      --type=merge --patch-file="$cas_manifest"
  else
    "$KUBECTL" "${KUBECTL_ARGS[@]}" patch "$resource" "$name" \
      --type=merge --patch-file="$cas_manifest"
  fi
}

agent_os_resource_uri() {
  local scope=$1 resource=$2 name=$3
  if [ "$scope" = namespaced ]; then
    case "$resource" in
      pod) printf '/api/v1/namespaces/%s/pods/%s\n' "$NAMESPACE" "$name" ;;
      pvc) printf '/api/v1/namespaces/%s/persistentvolumeclaims/%s\n' "$NAMESPACE" "$name" ;;
      service) printf '/api/v1/namespaces/%s/services/%s\n' "$NAMESPACE" "$name" ;;
      serviceaccount) printf '/api/v1/namespaces/%s/serviceaccounts/%s\n' "$NAMESPACE" "$name" ;;
      statefulset) printf '/apis/apps/v1/namespaces/%s/statefulsets/%s\n' "$NAMESPACE" "$name" ;;
      role) printf '/apis/rbac.authorization.k8s.io/v1/namespaces/%s/roles/%s\n' "$NAMESPACE" "$name" ;;
      rolebinding) printf '/apis/rbac.authorization.k8s.io/v1/namespaces/%s/rolebindings/%s\n' "$NAMESPACE" "$name" ;;
      *) echo "error: unsupported namespaced resource: $resource" >&2; return 2 ;;
    esac
  else
    case "$resource" in
      namespace) printf '/api/v1/namespaces/%s\n' "$name" ;;
      clusterrolebinding) printf '/apis/rbac.authorization.k8s.io/v1/clusterrolebindings/%s\n' "$name" ;;
      *) echo "error: unsupported cluster resource: $resource" >&2; return 2 ;;
    esac
  fi
}

agent_os_delete_preconditioned() {
  local scope=$1 resource=$2 name=$3 token=$4 uid resource_version uri timeout
  [ -n "$token" ] || return 0
  timeout=${AGENT_OS_DELETE_TIMEOUT_SECONDS:-120}
  case "$timeout" in
    ''|*[!0-9]*)
      echo "error: AGENT_OS_DELETE_TIMEOUT_SECONDS must be a non-negative integer" >&2
      return 2
      ;;
  esac
  uid=${token%%|*}
  resource_version=${token#*|}
  uri=$(agent_os_resource_uri "$scope" "$resource" "$name")
  printf '{"apiVersion":"v1","kind":"DeleteOptions","preconditions":{"uid":"%s","resourceVersion":"%s"}}\n' \
    "$uid" "$resource_version" | "$KUBECTL" "${KUBECTL_ARGS[@]}" delete --raw="$uri" -f -
  agent_os_wait_for_uid_gone "$scope" "$resource" "$name" "$uid" "$timeout"
}

agent_os_current_uid() {
  local scope=$1 resource=$2 name=$3
  if [ "$scope" = namespaced ]; then
    "$KUBECTL" "${KUBECTL_ARGS[@]}" -n "$NAMESPACE" get "$resource" "$name" --ignore-not-found \
      -o 'jsonpath={.metadata.uid}'
  else
    "$KUBECTL" "${KUBECTL_ARGS[@]}" get "$resource" "$name" --ignore-not-found \
      -o 'jsonpath={.metadata.uid}'
  fi
}

agent_os_wait_for_uid_gone() {
  local scope=$1 resource=$2 name=$3 uid=$4 timeout=$5 deadline current_uid
  deadline=$((SECONDS + timeout))
  while :; do
    current_uid=$(agent_os_current_uid "$scope" "$resource" "$name")
    [ "$current_uid" = "$uid" ] || return 0
    if [ "$SECONDS" -ge "$deadline" ]; then
      echo "error: timed out waiting for $resource/$name UID $uid to disappear" >&2
      return 1
    fi
    sleep 1
  done
}
