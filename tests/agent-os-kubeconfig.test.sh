#!/usr/bin/env bash
# Behavioral regression tests for automatic in-cluster kubeconfig creation.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

tmp=$(fm_test_tmproot agent-os-kubeconfig-tests)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/serviceaccount" "$tmp/home"
printf '%s\n' demo-token > "$tmp/serviceaccount/token"
printf '%s\n' demo-ca > "$tmp/serviceaccount/ca.crt"

HOME="$tmp/home" \
AGENT_OS_SERVICE_ACCOUNT_DIR="$tmp/serviceaccount" \
KUBERNETES_SERVICE_HOST=kubernetes.default.svc \
KUBERNETES_SERVICE_PORT_HTTPS=443 \
AGENT_OS_NAMESPACE=agent-os-eval \
  "$ROOT/bin/agent-os-kubeconfig.sh"

config="$tmp/home/.kube/config"
[ -f "$config" ] || fail "in-cluster kubeconfig was not created"
assert_grep 'current-context: in-cluster' "$config" "kubeconfig must select the local cluster alias"
assert_grep 'namespace: agent-os-eval' "$config" "kubeconfig must select the Agent OS namespace"
assert_grep "tokenFile: $tmp/serviceaccount/token" "$config" "kubeconfig must follow the rotating token file"
assert_no_grep 'demo-token' "$config" "kubeconfig must not copy token contents"
case $(uname -s) in
  Darwin) mode=$(stat -f '%Lp' "$config") ;;
  *) mode=$(stat -c '%a' "$config") ;;
esac
[ "$mode" = 600 ] || fail "kubeconfig must be mode 600"

printf '%s\n' sentinel > "$config"
HOME="$tmp/home" \
AGENT_OS_SERVICE_ACCOUNT_DIR="$tmp/serviceaccount" \
KUBERNETES_SERVICE_HOST=kubernetes.default.svc \
  "$ROOT/bin/agent-os-kubeconfig.sh"
[ "$(cat "$config")" = sentinel ] || fail "existing kubeconfig must not be overwritten"

pass "Agent OS creates a rotation-safe in-cluster kubeconfig without exposing token contents"
