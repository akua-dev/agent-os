#!/usr/bin/env bash
# Safety and command-contract tests for the local OrbStack Agent OS CLI.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CLI="$ROOT/bin/agent-os-local.sh"
TMP=$(fm_test_tmproot agent-os-local)
FAKEBIN=$(fm_fakebin "$TMP")
LOG="$TMP/calls.log"

make_fake() {
  local name=$1
  cat > "$FAKEBIN/$name" <<'SH'
#!/usr/bin/env bash
printf '%s' "$(basename "$0")" >> "$AGENT_OS_TEST_LOG"
printf ' %s' "$@" >> "$AGENT_OS_TEST_LOG"
printf '\n' >> "$AGENT_OS_TEST_LOG"
SH
  chmod +x "$FAKEBIN/$name"
}

make_fake docker
make_fake kubectl
make_fake orbctl

run_cli() {
  PATH="$FAKEBIN:$PATH" AGENT_OS_TEST_LOG="$LOG" "$CLI" "$@"
}

assert_call() {
  grep -Fqx -- "$1" "$LOG" || fail "$2 (missing exact call: $1)"
}

test_status_pins_context_and_namespace() {
  : > "$LOG"
  run_cli status
  assert_call 'kubectl --context orbstack -n agent-os-demo get statefulset agent-os-firstmate' \
    "status must target only the OrbStack Agent OS StatefulSet"
  pass "status pins the OrbStack context and Agent OS namespace"
}

test_deploy_starts_local_kubernetes_and_applies_kustomize() {
  : > "$LOG"
  run_cli deploy
  assert_call 'orbctl start k8s' "deploy must start OrbStack Kubernetes"
  assert_call 'kubectl --context orbstack wait --for=condition=Ready node/orbstack --timeout=120s' \
    "deploy must wait for the explicit OrbStack node"
  assert_call 'kubectl --context orbstack apply -k deploy/orbstack' \
    "deploy must apply only the checked-in OrbStack kustomization"
  pass "deploy starts and targets only OrbStack"
}

test_build_uses_local_image_name() {
  : > "$LOG"
  run_cli build
  assert_call 'docker build -t agent-os:dev .' "build must use the local demo image tag"
  pass "build uses the deterministic local image tag"
}

test_destroy_requires_exact_confirmation() {
  local out rc=0
  : > "$LOG"
  out=$(run_cli destroy 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || fail "destroy without --yes must exit 2, got $rc: $out"
  [ ! -s "$LOG" ] || fail "destroy without --yes invoked an external command"

  run_cli destroy --yes
  assert_call 'kubectl --context orbstack delete namespace agent-os-demo' \
    "confirmed destroy must delete only agent-os-demo"
  pass "destroy requires confirmation and remains namespace-scoped"
}

test_non_orbstack_context_is_fail_closed() {
  local out rc=0
  : > "$LOG"
  out=$(PATH="$FAKEBIN:$PATH" AGENT_OS_TEST_LOG="$LOG" AGENT_OS_CONTEXT=minekube-prod "$CLI" status 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || fail "non-OrbStack context must exit 2, got $rc: $out"
  [ ! -s "$LOG" ] || fail "rejected non-OrbStack context invoked an external command"

  PATH="$FAKEBIN:$PATH" AGENT_OS_TEST_LOG="$LOG" AGENT_OS_CONTEXT=kind-agent-os \
    AGENT_OS_ALLOW_NON_ORBSTACK=1 "$CLI" status
  assert_call 'kubectl --context kind-agent-os -n agent-os-demo get statefulset agent-os-firstmate' \
    "explicit non-OrbStack opt-in must still pin the chosen context"
  pass "non-OrbStack contexts require an explicit opt-in"
}

test_status_pins_context_and_namespace
test_deploy_starts_local_kubernetes_and_applies_kustomize
test_build_uses_local_image_name
test_destroy_requires_exact_confirmation
test_non_orbstack_context_is_fail_closed
