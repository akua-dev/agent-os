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
assert_grep 'mountPath = "/usr/local"' "$FIRSTMATE/package.k" \
  "Firstmate-installed tools must persist"

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
assert_grep 'resources = ["pods", "persistentvolumeclaims"]' "$FIRSTMATE/package.k" \
  "runtime apply authority must exclude Pod subresources from patch access"
assert_grep 'verbs = ["get", "list", "watch", "create", "delete", "patch"]' "$FIRSTMATE/package.k" \
  "runtime RBAC must allow kubectl apply to patch retained crewmate PVCs"
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
assert_contains "$rendered" 'kind: ServiceAccount' "rendered topology must create a ServiceAccount"
assert_contains "$rendered" 'kind: Role' "rendered topology must create namespace-scoped runtime RBAC"
assert_contains "$rendered" 'kind: RoleBinding' "rendered topology must bind namespace runtime RBAC"
assert_contains "$rendered" 'kind: PersistentVolumeClaim' "rendered topology must persist Firstmate home"
assert_contains "$rendered" 'kind: StatefulSet' "rendered topology must run Firstmate as a StatefulSet"
assert_contains "$rendered" 'ghcr.io/akua-dev/agent-os@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  "rendered topology must retain the immutable image digest"
assert_not_contains "$rendered" 'kind: ClusterRoleBinding' \
  "the default portable topology must not grant cluster-admin"
assert_not_contains "$rendered" 'AKUA_' \
  "the portable rendered topology must not require Akua configuration"
assert_not_contains "$rendered" 'agent-os.akua.dev' \
  "the portable rendered topology must not use Akua-owned annotations"

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
