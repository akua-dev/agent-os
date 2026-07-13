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
cat > "$FAKEBIN/docker" <<'SH'
#!/usr/bin/env bash
printf '%s' "$(basename "$0")" >> "$AGENT_OS_TEST_LOG"
printf ' %s' "$@" >> "$AGENT_OS_TEST_LOG"
printf '\n' >> "$AGENT_OS_TEST_LOG"
if [ "${1:-}" = image ] && [ "${2:-}" = inspect ]; then
  printf '%s\n' "${AGENT_OS_TEST_IMAGE_ID:?AGENT_OS_TEST_IMAGE_ID is required for image inspection}"
fi
SH
chmod +x "$FAKEBIN/docker"
make_fake kubectl
make_fake orbctl

run_cli() {
  PATH="$FAKEBIN:$PATH" AGENT_OS_TEST_LOG="$LOG" \
    AGENT_OS_TEST_IMAGE_ID="${AGENT_OS_TEST_IMAGE_ID:-sha256:default}" "$CLI" "$@"
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

test_rebuild_deploy_uses_a_new_immutable_local_tag() {
  : > "$LOG"
  AGENT_OS_TEST_IMAGE_ID=sha256:stale run_cli build
  AGENT_OS_TEST_IMAGE_ID=sha256:rebuilt run_cli build
  AGENT_OS_TEST_IMAGE_ID=sha256:rebuilt run_cli deploy

  assert_call 'docker build -t agent-os:dev .' "build must retain the local demo image tag"
  assert_call 'docker tag agent-os:dev agent-os:local-rebuilt' \
    "build must assign the rebuilt image a unique local tag"
  assert_call 'kubectl --context orbstack -n agent-os-demo set image statefulset/agent-os-firstmate agent-os-init=agent-os:local-rebuilt firstmate=agent-os:local-rebuilt' \
    "deploy must replace the stale mutable tag with the rebuilt local tag"
  pass "rebuild deploy selects the rebuilt local image instead of a stale mutable tag"
}

test_explicit_image_override_is_used_without_retagging() {
  : > "$LOG"
  AGENT_OS_IMAGE=example.test/agent-os:custom run_cli build
  AGENT_OS_IMAGE=example.test/agent-os:custom run_cli deploy

  assert_call 'docker build -t example.test/agent-os:custom .' \
    "build must preserve an explicit image override"
  assert_call 'kubectl --context orbstack -n agent-os-demo set image statefulset/agent-os-firstmate agent-os-init=example.test/agent-os:custom firstmate=example.test/agent-os:custom' \
    "deploy must preserve an explicit image override"
  if grep -F 'docker tag example.test/agent-os:custom' "$LOG" >/dev/null; then
    fail "explicit image overrides must not be retagged"
  fi
  pass "explicit image override remains intact"
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
test_rebuild_deploy_uses_a_new_immutable_local_tag
test_explicit_image_override_is_used_without_retagging
test_destroy_requires_exact_confirmation
test_non_orbstack_context_is_fail_closed
