#!/usr/bin/env bash
# Create a token-file-backed kubeconfig when this container has a ServiceAccount.
set -eu

HOME=${HOME:-/home/agent}
service_account_dir=${AGENT_OS_SERVICE_ACCOUNT_DIR:-/var/run/secrets/kubernetes.io/serviceaccount}
kubeconfig=${AGENT_OS_KUBECONFIG_PATH:-$HOME/.kube/config}

[ -r "$service_account_dir/token" ] || exit 0
[ -r "$service_account_dir/ca.crt" ] || exit 0
[ -e "$kubeconfig" ] && exit 0

: "${KUBERNETES_SERVICE_HOST:?KUBERNETES_SERVICE_HOST is required with a ServiceAccount token}"
mkdir -p "$(dirname "$kubeconfig")"
umask 077
cat > "$kubeconfig" <<YAML
apiVersion: v1
kind: Config
clusters:
  - name: in-cluster
    cluster:
      server: https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT_HTTPS:-443}
      certificate-authority: $service_account_dir/ca.crt
users:
  - name: in-cluster
    user:
      tokenFile: $service_account_dir/token
contexts:
  - name: in-cluster
    context:
      cluster: in-cluster
      user: in-cluster
      namespace: ${AGENT_OS_NAMESPACE:-agent-os-demo}
current-context: in-cluster
YAML
