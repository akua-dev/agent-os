#!/usr/bin/env bash
# Render contracts for the one portable Agent OS package.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FIRSTMATE="$ROOT/tools/agent-os/packages/firstmate"
MATE="$ROOT/tools/agent-os/packages/mate"
TMP=$(fm_test_tmproot agent-os-packages)
INPUTS="$TMP/inputs.yaml"
OUT="$TMP/rendered"
MUTABLE_INPUTS="$TMP/mutable-image.yaml"
CLUSTER_ADMIN_INPUTS="$TMP/cluster-admin.yaml"

mkdir -p "$TMP"

[ -f "$FIRSTMATE/package.k" ] || fail "firstmate package must exist"
[ -f "$FIRSTMATE/inputs.example.yaml" ] || fail "firstmate example inputs must exist"

assert_grep 'kind = "StatefulSet"' "$FIRSTMATE/package.k" \
  "firstmate package must create a restartable controller"
assert_grep 'kind = "PersistentVolumeClaim"' "$FIRSTMATE/package.k" \
  "firstmate package must persist its home"
assert_grep 'kind = "ServiceAccount"' "$FIRSTMATE/package.k" \
  "firstmate package must create its cluster identity"
assert_grep 'herdr", "status", "--json"' "$FIRSTMATE/package.k" \
  "Firstmate readiness must prove the Herdr server is responsive"
assert_no_grep 'mountPath = "/usr/local"' "$FIRSTMATE/package.k" \
  "image-owned Firstmate tools must remain immutable"

assert_no_grep 'image: str = ' "$FIRSTMATE/package.k" \
  "the portable package must require an explicit immutable image digest"
assert_grep 'allowMutableImage: bool = False' "$FIRSTMATE/package.k" \
  "only an explicit local profile may allow a mutable image"
assert_grep 'rbac: "namespace" | "cluster-admin" | "none" = "namespace"' "$FIRSTMATE/package.k" \
  "the portable package must default to namespace-scoped runtime RBAC"
assert_grep 'kind = "Role"' "$FIRSTMATE/package.k" \
  "the portable package must render the namespace runtime Role"
assert_grep 'kind = "RoleBinding"' "$FIRSTMATE/package.k" \
  "the portable package must bind its explicit ServiceAccount to that Role"
assert_grep '"app.kubernetes.io/managed-by" = "agent-os"' "$FIRSTMATE/package.k" \
  "package resources must carry the Agent OS ownership label"
assert_grep '"agent-os.dev/installation-id"' "$FIRSTMATE/package.k" \
  "cluster and namespace resources must carry the installation identity"
assert_grep '"agent-os.dev/rbac-mode" = input.rbac' "$FIRSTMATE/package.k" \
  "the workload must record the applied RBAC mode for safe reconciliation"
assert_grep 'resources = ["pods", "persistentvolumeclaims"]' "$FIRSTMATE/package.k" \
  "runtime apply authority must exclude Pod subresources from patch access"
assert_grep 'verbs = ["get", "list", "watch", "create", "delete", "patch"]' "$FIRSTMATE/package.k" \
  "runtime RBAC must allow checkpoint updates on retained crewmate PVCs"
assert_grep 'resources = ["leases"]' "$FIRSTMATE/package.k" \
  "runtime RBAC must permit serialized crewmate lifecycle operations"
assert_grep 'verbs = ["get", "create", "update", "delete"]' "$FIRSTMATE/package.k" \
  "runtime Lease authority must be exact and permit CAS renewal"
assert_no_grep 'akuaAuthSecret' "$FIRSTMATE/package.k" \
  "the portable package must not require Akua authorization"
assert_no_grep 'agent-os.akua.dev' "$FIRSTMATE/package.k" \
  "the portable package must not depend on Akua-owned resource annotations"
[ -f "$ROOT/deploy/akua/firstmate-auth-grant.yaml" ] || \
  fail "Akua authorization must use a separate integration grant overlay"
[ -f "$ROOT/deploy/akua/firstmate-auth-revoke.yaml" ] || \
  fail "Akua authorization overlay must own explicit mount cleanup"
assert_grep 'name: AKUA_AUTH_HEADER_FILE' "$ROOT/deploy/akua/firstmate-auth-grant.yaml" \
  "Akua overlay must set the authorization header file path"
assert_grep 'mountPath: /var/run/secrets/agent-os/akua' "$ROOT/deploy/akua/firstmate-auth-grant.yaml" \
  "Akua overlay must mount only the Akua authorization path"
assert_grep 'secretName: __AKUA_AUTH_SECRET__' "$ROOT/deploy/akua/firstmate-auth-grant.yaml" \
  "Akua overlay must reference a namespace-local Secret by name"
assert_grep "\$patch: delete" "$ROOT/deploy/akua/firstmate-auth-revoke.yaml" \
  "Akua overlay must define explicit authorization mount cleanup"
assert_grep 'mountPath: /var/run/secrets/agent-os/akua' "$ROOT/deploy/akua/firstmate-auth-revoke.yaml" \
  "Akua overlay cleanup must use the strategic merge key for volume mounts"
assert_grep 'bin/agent-os-akua-auth.sh grant "$secret_name"' \
  "$ROOT/.agents/skills/akua-intelligence-bootstrap/SKILL.md" \
  "Akua authorization grant must use serialized exact-target integration"
assert_grep 'bin/agent-os-akua-auth.sh revoke "$secret_name"' \
  "$ROOT/.agents/skills/akua-intelligence-bootstrap/SKILL.md" \
  "Akua authorization revocation must use the same serialized integration"
assert_grep 'agent-os.dev/akua-auth-secret' "$ROOT/deploy/akua/firstmate-auth-grant.yaml" \
  "Akua authorization overlays must carry a verifiable non-secret reference marker"
[ -x "$ROOT/bin/agent-os-akua-auth.sh" ] || \
  fail "Akua authorization mutations must use the shipped serialized helper"
assert_grep 'resourceVersion:' "$ROOT/bin/agent-os-akua-auth.sh" \
  "Akua authorization mutations must carry StatefulSet CAS evidence"
assert_grep 'get pod agent-os-firstmate-0 -o json' "$ROOT/bin/agent-os-akua-auth.sh" \
  "Akua authorization mutations must verify the exact-owned rollout Pod"
assert_grep 'a missing credential grant is rejected before any mate resource is created' "$ROOT/docs/agent-evals.md" \
  "the eval contract must match fail-closed runtime authorization"
assert_grep '@sha256:' "$FIRSTMATE/inputs.example.yaml" \
  "the example must use an immutable image digest"
[ ! -f "$MATE/package.k" ] || fail "mate creation must not remain a separately installable package"

cat > "$INPUTS" <<'YAML'
namespace: portable-agent-os
image: ghcr.io/akua-dev/agent-os@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
imagePullPolicy: IfNotPresent
rbac: namespace
storage: 20Gi
YAML

akua render --no-agent-mode --package "$FIRSTMATE/package.k" --inputs "$INPUTS" --out "$OUT" >/dev/null || \
  fail "the portable package must render without an Akua account or credential"

rendered=$(cat "$OUT"/*.yaml)
statefulset_rendered=$(cat "$(grep -Rl '^kind: StatefulSet$' "$OUT")")
assert_contains "$rendered" 'kind: ServiceAccount' "rendered topology must create a ServiceAccount"
assert_contains "$rendered" 'kind: Role' "rendered topology must create namespace-scoped runtime RBAC"
assert_contains "$rendered" 'kind: RoleBinding' "rendered topology must bind namespace runtime RBAC"
assert_contains "$rendered" 'kind: PersistentVolumeClaim' "rendered topology must persist Firstmate home"
assert_contains "$rendered" 'kind: StatefulSet' "rendered topology must run Firstmate as a StatefulSet"
assert_contains "$rendered" 'ghcr.io/akua-dev/agent-os@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  "rendered topology must retain the immutable image digest"
assert_contains "$rendered" 'app.kubernetes.io/managed-by: agent-os' \
  "rendered resources must carry the Agent OS ownership label"
assert_contains "$rendered" 'agent-os.dev/installation-id: agent-os-firstmate:portable-agent-os' \
  "rendered resources must carry the exact installation identity"
for resource_file in "$OUT"/*.yaml; do
  assert_grep 'app.kubernetes.io/managed-by: agent-os' "$resource_file" \
    "every rendered resource must carry the Agent OS ownership label"
  assert_grep 'agent-os.dev/installation-id: agent-os-firstmate:portable-agent-os' "$resource_file" \
    "every rendered resource must carry the exact installation identity"
done
assert_contains "$statefulset_rendered" 'agent-os.dev/rbac-mode: namespace' \
  "the rendered StatefulSet must record its RBAC mode"
assert_not_contains "$rendered" 'kind: ClusterRoleBinding' \
  "the default portable topology must not grant cluster-admin"
assert_not_contains "$rendered" 'AKUA_' \
  "the portable rendered topology must not require Akua configuration"
assert_not_contains "$rendered" 'agent-os.akua.dev' \
  "the portable rendered topology must not use Akua-owned annotations"

sed 's/^rbac: namespace/rbac: cluster-admin/' "$INPUTS" > "$CLUSTER_ADMIN_INPUTS"
akua render --no-agent-mode --package "$FIRSTMATE/package.k" --inputs "$CLUSTER_ADMIN_INPUTS" \
  --out "$TMP/cluster-admin-rendered" >/dev/null || \
  fail "the reviewed cluster-admin package profile must render"
cluster_binding=$(cat "$(grep -Rl '^kind: ClusterRoleBinding$' "$TMP/cluster-admin-rendered")")
assert_contains "$cluster_binding" 'name: agent-os-firstmate-portable-agent-os' \
  "cluster-admin RBAC must use the deterministic installation binding name"
assert_contains "$cluster_binding" 'app.kubernetes.io/managed-by: agent-os' \
  "cluster-admin RBAC must carry the exact ownership label"
assert_contains "$cluster_binding" 'agent-os.dev/installation-id: agent-os-firstmate:portable-agent-os' \
  "cluster-admin RBAC must carry the exact installation annotation"

cat > "$MUTABLE_INPUTS" <<'YAML'
namespace: portable-agent-os
image: ghcr.io/akua-dev/agent-os:latest
imagePullPolicy: IfNotPresent
rbac: namespace
storage: 20Gi
YAML

if akua render --no-agent-mode --package "$FIRSTMATE/package.k" --inputs "$MUTABLE_INPUTS" --out "$TMP/mutable-rendered" >/dev/null 2>&1; then
  fail "the portable package must reject a mutable image tag"
fi
pass "the portable package rejects mutable image tags"

for invalid_image in \
  'ghcr.io/akua-dev/agent-os@sha256:abc' \
  'ghcr.io/akua-dev/agent-os@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaextra' \
  'invalid@@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  'registry.example/org:123/image@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  '[2001:db8::1]:5000/org:123/image@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  '[2001:db8::g]:5000/org/image@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  '[1]:5000/org/image@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  '[::::]:5000/org/image@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  '[1::2::3]:5000/org/image@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  '[::ffff:999.0.2.1]:5000/org/image@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  'prefix@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:suffix'; do
  invalid_inputs="$TMP/invalid-$(printf '%s' "$invalid_image" | tr '/:@' '---').yaml"
  sed "s|^image: .*|image: \"$invalid_image\"|" "$INPUTS" > "$invalid_inputs"
  if akua render --no-agent-mode --package "$FIRSTMATE/package.k" --inputs "$invalid_inputs" \
    --out "$TMP/invalid-rendered" >/dev/null 2>&1; then
    fail "the portable package accepted malformed digest reference '$invalid_image'"
  fi
done
pass "the portable package requires one complete 64-hex SHA-256 digest"

PORT_INPUTS="$TMP/registry-port.yaml"
sed 's|^image: .*|image: registry.example:5000/org/agent-os@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa|' \
  "$INPUTS" > "$PORT_INPUTS"
akua render --no-agent-mode --package "$FIRSTMATE/package.k" --inputs "$PORT_INPUTS" \
  --out "$TMP/registry-port-rendered" >/dev/null || \
  fail "the portable package must allow a registry authority port"
pass "OCI reference ports are confined to registry authority"

IPV6_INPUTS="$TMP/registry-ipv6.yaml"
sed 's|^image: .*|image: "[2001:db8::1]:5000/org/agent-os@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"|' \
  "$INPUTS" > "$IPV6_INPUTS"
akua render --no-agent-mode --package "$FIRSTMATE/package.k" --inputs "$IPV6_INPUTS" \
  --out "$TMP/registry-ipv6-rendered" >/dev/null || \
  fail "the portable package must allow a bracketed IPv6 registry authority"
for ipv6_registry in '::' '::1' '1::' '1:2:3:4:5:6:7:8' '::ffff:192.0.2.1'; do
  ipv6_inputs="$TMP/registry-ipv6-$(printf '%s' "$ipv6_registry" | tr ':' '-').yaml"
  sed "s|^image: .*|image: \"[$ipv6_registry]:5000/org/agent-os@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"|" \
    "$INPUTS" > "$ipv6_inputs"
  akua render --no-agent-mode --package "$FIRSTMATE/package.k" --inputs "$ipv6_inputs" \
    --out "$TMP/registry-ipv6-$(printf '%s' "$ipv6_registry" | tr ':' '-')-rendered" >/dev/null || \
    fail "the portable package rejected valid IPv6 registry '$ipv6_registry'"
done
pass "OCI references accept bracketed IPv6 registry authorities"

assert_grep 'bin/agent-os-kubernetes.sh install' "$ROOT/docs/kubernetes.md" \
  "Kubernetes docs must make the generic installer the default quickstart"
assert_grep 'bin/agent-os-kubernetes.sh rollback' "$ROOT/docs/kubernetes.md" \
  "Kubernetes docs must document bounded rollback"
assert_grep 'bin/agent-os-kubernetes.sh uninstall --yes' "$ROOT/docs/kubernetes.md" \
  "Kubernetes docs must document confirmed bounded uninstall"
assert_grep 'No Kubernetes Secret is required' "$ROOT/docs/kubernetes.md" \
  "Kubernetes docs must state the portable secret requirement"
assert_grep 'OrbStack profile' "$ROOT/docs/kubernetes.md" \
  "Kubernetes docs must describe OrbStack as a profile of the canonical package"
assert_grep '[Agent OS Kubernetes quickstart](docs/kubernetes.md)' "$ROOT/README.md" \
  "README must point to the portable Kubernetes quickstart"
assert_no_grep 'Firstmate Akua package' "$ROOT/README.md" \
  "README must not present a separate Akua package as the portable install path"
assert_grep 'Install Akua renderer' "$ROOT/.github/workflows/ci.yml" \
  "CI behavior tests must install the renderer used by package contracts"

pass "the portable Agent OS package renders a digest-pinned topology without Akua"
