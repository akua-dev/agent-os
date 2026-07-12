#!/usr/bin/env bash
# agent-os-crewmate.sh - create, inspect, or delete one isolated crewmate Pod.
# Usage: bin/agent-os-crewmate.sh create|status|delete <crewmate-id>
set -eu

COMMAND=${1:-}
ID=${2:-}
NAMESPACE=${AGENT_OS_NAMESPACE:-agent-os-demo}
IMAGE=${AGENT_OS_IMAGE:-agent-os:dev}
KUBECTL=${AGENT_OS_KUBECTL:-kubectl}

case "$ID" in
  ''|*[!a-z0-9-]*|-*|*-) echo "error: invalid crewmate id '$ID'" >&2; exit 2 ;;
esac

KUBECTL_ARGS=()
if [ -n "${AGENT_OS_CONTEXT:-}" ]; then
  KUBECTL_ARGS=(--context "$AGENT_OS_CONTEXT")
elif [ "${AGENT_OS_IN_CLUSTER:-0}" != 1 ] && [ ! -f /var/run/secrets/kubernetes.io/serviceaccount/token ]; then
  echo "error: set AGENT_OS_CONTEXT outside Kubernetes; ambient contexts are refused" >&2
  exit 2
fi

POD="agent-os-crewmate-$ID"
PVC="$POD-home"

case "$COMMAND" in
  create)
    "$KUBECTL" "${KUBECTL_ARGS[@]}" -n "$NAMESPACE" apply -f - <<YAML
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $PVC
  namespace: $NAMESPACE
  labels:
    app.kubernetes.io/name: agent-os
    app.kubernetes.io/component: crewmate
    agent-os.akua.dev/crewmate: $ID
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: $POD
  namespace: $NAMESPACE
  labels:
    app.kubernetes.io/name: agent-os
    app.kubernetes.io/component: crewmate
    agent-os.akua.dev/crewmate: $ID
spec:
  automountServiceAccountToken: false
  securityContext:
    fsGroup: 1000
    runAsGroup: 1000
    runAsNonRoot: true
    runAsUser: 1000
  containers:
    - name: crewmate
      image: $IMAGE
      imagePullPolicy: Never
      env:
        - name: FM_HOME
          value: /home/agent
        - name: HOME
          value: /home/agent
      resources:
        requests:
          cpu: 250m
          memory: 512Mi
        limits:
          cpu: "2"
          memory: 4Gi
      volumeMounts:
        - name: home
          mountPath: /home/agent
  volumes:
    - name: home
      persistentVolumeClaim:
        claimName: $PVC
YAML
    ;;
  status)
    "$KUBECTL" "${KUBECTL_ARGS[@]}" -n "$NAMESPACE" get pod "$POD"
    ;;
  delete)
    "$KUBECTL" "${KUBECTL_ARGS[@]}" -n "$NAMESPACE" delete pod "$POD" --ignore-not-found
    "$KUBECTL" "${KUBECTL_ARGS[@]}" -n "$NAMESPACE" delete pvc "$PVC" --ignore-not-found
    ;;
  *)
    echo "usage: $0 create|status|delete <crewmate-id>" >&2
    exit 2
    ;;
esac
