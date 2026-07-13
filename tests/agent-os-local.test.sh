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
cat > "$FAKEBIN/akua" <<'SH'
#!/usr/bin/env bash
printf '%s' "$(basename "$0")" >> "$AGENT_OS_TEST_LOG"
printf ' %s' "$@" >> "$AGENT_OS_TEST_LOG"
printf '\n' >> "$AGENT_OS_TEST_LOG"
inputs=''
out=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --inputs) inputs=$2; shift 2 ;;
    --out) out=$2; shift 2 ;;
    *) shift ;;
  esac
done
printf 'akua-input-image %s\n' "$(awk '/^image:/{print $2}' "$inputs")" >> "$AGENT_OS_TEST_LOG"
mkdir -p "$out"
printf 'apiVersion: v1\nkind: ConfigMap\n' > "$out/rendered.yaml"
SH
chmod +x "$FAKEBIN/akua"

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

test_deploy_starts_local_kubernetes_and_renders_the_orbstack_profile() {
  : > "$LOG"
  run_cli deploy
  assert_call 'orbctl start k8s' "deploy must start OrbStack Kubernetes"
  assert_call 'kubectl --context orbstack wait --for=condition=Ready node/orbstack --timeout=120s' \
    "deploy must wait for the explicit OrbStack node"
  grep -Fq -- "akua render --no-agent-mode --package $ROOT/tools/agent-os/packages/firstmate/package.k --inputs " "$LOG" || \
    fail "deploy must render the canonical portable package"
  assert_call 'akua-input-image agent-os:local-default' \
    "OrbStack must derive its manifest from the rebuilt local image"
  grep -Fq 'kubectl --context orbstack apply -f ' "$LOG" || \
    fail "deploy must apply only the freshly rendered OrbStack profile"
  if grep -F 'kubectl --context orbstack apply -k' "$LOG" >/dev/null; then
    fail "OrbStack must not maintain a second static installer"
  fi
  pass "deploy starts OrbStack and applies the canonical package profile"
}

test_rebuild_deploy_uses_a_new_immutable_local_tag() {
  : > "$LOG"
  AGENT_OS_TEST_IMAGE_ID=sha256:stale run_cli build
  AGENT_OS_TEST_IMAGE_ID=sha256:rebuilt run_cli build
  AGENT_OS_TEST_IMAGE_ID=sha256:rebuilt run_cli deploy

  assert_call 'docker build -t agent-os:dev .' "build must retain the local demo image tag"
  assert_call 'docker tag agent-os:dev agent-os:local-rebuilt' \
    "build must assign the rebuilt image a unique local tag"
  assert_call 'akua-input-image agent-os:local-rebuilt' \
    "the rendered OrbStack profile must select the rebuilt local image"
  pass "rebuild deploy renders the rebuilt local image instead of a stale mutable tag"
}

test_explicit_image_override_is_used_without_retagging() {
  : > "$LOG"
  AGENT_OS_IMAGE=example.test/agent-os:custom run_cli build
  AGENT_OS_IMAGE=example.test/agent-os:custom run_cli deploy

  assert_call 'docker build -t example.test/agent-os:custom .' \
    "build must preserve an explicit image override"
  assert_call 'akua-input-image example.test/agent-os:custom' \
    "the rendered OrbStack profile must preserve an explicit image override"
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
  grep -Fq 'kubectl --context orbstack delete --ignore-not-found -f ' "$LOG" || \
    fail "confirmed destroy must delete only resources from the rendered OrbStack profile"
  pass "destroy requires confirmation and remains package-scoped"
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
test_deploy_starts_local_kubernetes_and_renders_the_orbstack_profile
test_rebuild_deploy_uses_a_new_immutable_local_tag
test_explicit_image_override_is_used_without_retagging
test_destroy_requires_exact_confirmation
test_non_orbstack_context_is_fail_closed
