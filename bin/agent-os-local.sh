#!/usr/bin/env bash
# agent-os-local.sh - build and operate the local OrbStack Agent OS demo.
# Usage: bin/agent-os-local.sh build|deploy|status|shell|attach|destroy [--yes]
set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CONTEXT=${AGENT_OS_CONTEXT:-orbstack}
NAMESPACE=${AGENT_OS_NAMESPACE:-agent-os-demo}
IMAGE=${AGENT_OS_IMAGE:-agent-os:dev}
IMAGE_IS_OVERRIDE=
[ -z "${AGENT_OS_IMAGE:-}" ] || IMAGE_IS_OVERRIDE=1
COMMAND=${1:-}
PROFILE="$ROOT/deploy/orbstack/inputs.yaml"

case "$NAMESPACE" in
  ''|*[!a-z0-9.-]*|[.-]*|*[-.])
    echo "error: AGENT_OS_NAMESPACE must be a valid Kubernetes namespace" >&2
    exit 2
    ;;
esac

if [ "$CONTEXT" != orbstack ] && [ "${AGENT_OS_ALLOW_NON_ORBSTACK:-0}" != 1 ]; then
  echo "error: refusing Kubernetes context '$CONTEXT'; set AGENT_OS_ALLOW_NON_ORBSTACK=1 to opt in" >&2
  exit 2
fi

local_image_tag() {
  local image_id
  image_id=$(docker image inspect --format '{{.Id}}' "$IMAGE")
  printf 'agent-os:local-%s\n' "${image_id#sha256:}"
}

render_profile_inputs() {
  local image=$1 inputs=$2
  awk -v image="$image" -v namespace="$NAMESPACE" '
    $1 == "image:" { print "image: " image; next }
    $1 == "namespace:" { print "namespace: " namespace; next }
    { print }
  ' "$PROFILE" > "$inputs"
}

render_profile() {
  local image=$1 inputs lifecycle
  inputs=$(mktemp)
  trap 'rm -f "$inputs"' RETURN
  render_profile_inputs "$image" "$inputs"
  lifecycle=install
  if [ -n "$(kubectl --context "$CONTEXT" -n "$NAMESPACE" get statefulset agent-os-firstmate --ignore-not-found -o name)" ]; then
    lifecycle=upgrade
  fi
  AGENT_OS_CONTEXT="$CONTEXT" AGENT_OS_NAMESPACE="$NAMESPACE" AGENT_OS_INPUTS="$inputs" \
    "$ROOT/bin/agent-os-kubernetes.sh" "$lifecycle"
}

cd "$ROOT"

case "$COMMAND" in
  build)
    source_metadata=$("$ROOT/bin/agent-os-source-bundle.sh")
    source_commit=$(printf '%s\n' "$source_metadata" | awk -F= '$1 == "commit" { print $2 }')
    source_tree=$(printf '%s\n' "$source_metadata" | awk -F= '$1 == "tree" { print $2 }')
    source_branch=$(printf '%s\n' "$source_metadata" | awk -F= '$1 == "branch" { print $2 }')
    source_origin=$(printf '%s\n' "$source_metadata" | awk -F= '$1 == "origin" { sub(/^[^=]*=/, ""); print }')
    [ -n "$source_commit" ] && [ -n "$source_tree" ] && [ -n "$source_branch" ] && [ -n "$source_origin" ] || {
      echo "error: exact-source bootstrap metadata is incomplete" >&2
      exit 2
    }
    docker build \
      --build-arg "AGENT_OS_SOURCE_COMMIT=$source_commit" \
      --build-arg "AGENT_OS_SOURCE_TREE=$source_tree" \
      --build-arg "AGENT_OS_SOURCE_BRANCH=$source_branch" \
      --build-arg "AGENT_OS_SOURCE_ORIGIN=$source_origin" \
      -t "$IMAGE" .
    if [ -z "$IMAGE_IS_OVERRIDE" ]; then
      docker tag "$IMAGE" "$(local_image_tag)"
    fi
    ;;
  deploy)
    if [ "$CONTEXT" = orbstack ]; then
      orbctl start k8s
      kubectl --context "$CONTEXT" wait --for=condition=Ready node/orbstack --timeout=120s
    fi
    if [ -z "$IMAGE_IS_OVERRIDE" ]; then
      IMAGE=$(local_image_tag)
    fi
    render_profile "$IMAGE"
    ;;
  status)
    kubectl --context "$CONTEXT" -n "$NAMESPACE" get statefulset agent-os-firstmate
    ;;
  shell)
    kubectl --context "$CONTEXT" -n "$NAMESPACE" exec -it statefulset/agent-os-firstmate -- bash
    ;;
  attach)
    kubectl --context "$CONTEXT" -n "$NAMESPACE" exec -it statefulset/agent-os-firstmate -- herdr
    ;;
  destroy)
    if [ "${2:-}" != --yes ]; then
      echo "error: destroy requires --yes and removes only namespaced Agent OS resources from '$NAMESPACE'" >&2
      exit 2
    fi
    inputs=$(mktemp)
    trap 'rm -f "$inputs"' EXIT
    render_profile_inputs "$IMAGE" "$inputs"
    AGENT_OS_CONTEXT="$CONTEXT" AGENT_OS_NAMESPACE="$NAMESPACE" AGENT_OS_INPUTS="$inputs" \
      "$ROOT/bin/agent-os-kubernetes.sh" uninstall --yes
    ;;
  *)
    echo "usage: $0 build|deploy|status|shell|attach|destroy [--yes]" >&2
    exit 2
    ;;
esac
