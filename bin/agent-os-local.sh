#!/usr/bin/env bash
# agent-os-local.sh - build and operate the local OrbStack Agent OS demo.
# Usage: bin/agent-os-local.sh build|deploy|status|shell|attach|destroy [--yes]
set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CONTEXT=${AGENT_OS_CONTEXT:-orbstack}
NAMESPACE=${AGENT_OS_NAMESPACE:-agent-os-demo}
IMAGE=${AGENT_OS_IMAGE:-agent-os:dev}
IMAGE_IS_OVERRIDE=${AGENT_OS_IMAGE+x}
COMMAND=${1:-}
PROFILE="$ROOT/deploy/orbstack/inputs.yaml"

if [ "$CONTEXT" != orbstack ] && [ "${AGENT_OS_ALLOW_NON_ORBSTACK:-0}" != 1 ]; then
  echo "error: refusing Kubernetes context '$CONTEXT'; set AGENT_OS_ALLOW_NON_ORBSTACK=1 to opt in" >&2
  exit 2
fi

local_image_tag() {
  local image_id
  image_id=$(docker image inspect --format '{{.Id}}' "$IMAGE")
  printf 'agent-os:local-%s\n' "${image_id#sha256:}"
}

render_profile() {
  local image=$1 inputs
  inputs=$(mktemp)
  trap 'rm -f "$inputs"' RETURN
  sed "s|^image: .*|image: $image|" "$PROFILE" > "$inputs"
  AGENT_OS_CONTEXT="$CONTEXT" AGENT_OS_NAMESPACE="$NAMESPACE" AGENT_OS_INPUTS="$inputs" \
    "$ROOT/bin/agent-os-kubernetes.sh" install
}

cd "$ROOT"

case "$COMMAND" in
  build)
    docker build -t "$IMAGE" .
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
      echo "error: destroy requires --yes and deletes only namespace '$NAMESPACE'" >&2
      exit 2
    fi
    AGENT_OS_CONTEXT="$CONTEXT" AGENT_OS_NAMESPACE="$NAMESPACE" AGENT_OS_INPUTS="$PROFILE" \
      "$ROOT/bin/agent-os-kubernetes.sh" uninstall --yes
    ;;
  *)
    echo "usage: $0 build|deploy|status|shell|attach|destroy [--yes]" >&2
    exit 2
    ;;
esac
