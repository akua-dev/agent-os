#!/usr/bin/env bash
# Source-closure, clean-context, license, mode, and OCI provenance invariants.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MANIFEST="$ROOT/SOURCE_PROVENANCE.json"
CONTEXT_TOOL="$ROOT/bin/agent-os-source-context.sh"

assert_present "$MANIFEST" "source closure must ship a machine-readable source manifest"
jq -e . "$MANIFEST" >/dev/null || fail "source manifest must be valid JSON"

[ "$(jq -r '.schema_version' "$MANIFEST")" = "1" ] || fail "source manifest schema must be version 1"
[ "$(jq -r '.package.repository' "$MANIFEST")" = "https://github.com/akua-dev/agent-os" ] \
  || fail "source manifest must name the Agent OS repository"
[ "$(jq -r '.package.license' "$MANIFEST")" = "MIT" ] || fail "Agent OS source package must remain MIT"
[ "$(jq -r '.inputs | length' "$MANIFEST")" = "6" ] || fail "source manifest must record the precursor and five ordered merge inputs"

expected_inputs=$(cat <<'EOF'
0|package-precursor|https://github.com/akua-dev/agent-os|07c48eeeee162bdd40b5a43537c21b989a65b260|base|MIT
1|agent-os-firstmate-sync|https://github.com/akua-dev/agent-os|a318580a88c08c0aa2e270ae8ea0f0f02b5ea640|merge|MIT
2|firstmate-upstream|https://github.com/kunchenguid/firstmate|8c0d9eb878bc8c2ec4c11bf71dd819f626875bf6|merge|MIT
3|firstmate-pr-442|https://github.com/kunchenguid/firstmate/pull/442|9b4d65da33b7a14a2ad77c2048186f1e6d7a56e1|merge|MIT
4|firstmate-pr-521|https://github.com/kunchenguid/firstmate/pull/521|86cc8769d1c34251cae821059b79fbdc1e5fc5e4|merge|MIT
5|zellij-superseder|https://github.com/robinbraemer/firstmate|d47b44c8ed5b966f425ddd5e6a0dcbc1b9714e9a|merge|MIT
EOF
)
actual_inputs=$(jq -r '.inputs | to_entries[] | [.key, .value.name, .value.repository, .value.commit, .value.integration, .value.license] | join("|")' "$MANIFEST")
[ "$actual_inputs" = "$expected_inputs" ] || fail "source manifest input order or exact provenance changed"

while IFS= read -r commit; do
  git -C "$ROOT" merge-base --is-ancestor "$commit" HEAD \
    || fail "selected source input is not an ancestor of HEAD: $commit"
done <<EOF
$(jq -r '.inputs[].commit' "$MANIFEST")
EOF

jq -e '.exclusions.commits[] | select(.commit == "e204ec1671fa698a3d8a0eb9a0ac8c8bd87f47fa" and .reason == "test-only; not an ancestor, dependency, or blocker")' "$MANIFEST" >/dev/null \
  || fail "source manifest must explicitly exclude Firstmate PR 528 without treating it as a dependency"
if git -C "$ROOT" cat-file -e 'e204ec1671fa698a3d8a0eb9a0ac8c8bd87f47fa^{commit}' 2>/dev/null \
  && git -C "$ROOT" merge-base --is-ancestor e204ec1671fa698a3d8a0eb9a0ac8c8bd87f47fa HEAD; then
  fail "excluded Firstmate PR 528 must not become an ancestor"
fi

for path in .env config data state projects worktrees .worktrees .no-mistakes .repos node_modules; do
  jq -e --arg path "$path" '.exclusions.paths | index($path) != null' "$MANIFEST" >/dev/null \
    || fail "source manifest must record excluded path: $path"
done

for path in \
  .pi/extensions/fm-primary-pi-watch.ts \
  .codex/hooks.json \
  .claude/settings.json \
  .claude/skills \
  .grok/hooks/fm-primary-turnend-guard.json \
  .grok/hooks/fm-primary-pretool-check.json \
  .grok/hooks/fm-primary-cd-check.json \
  .opencode/plugins/fm-primary-watch-arm.js \
  .opencode/plugins/fm-primary-turnend-guard.js \
  .opencode/plugins/fm-primary-pretool-check.js \
  .opencode/plugins/fm-primary-cd-check.js; do
  git -C "$ROOT" ls-files --error-unmatch "$path" >/dev/null 2>&1 \
    || fail "required tracked harness integration is missing: $path"
done

assert_grep '**' "$ROOT/.dockerignore" "Docker context must default-deny local paths"
assert_grep '!image/agent-os-source.tar' "$ROOT/.dockerignore" \
  "Docker context must admit the verified tracked source archive"

for path in LICENSE THIRD_PARTY_NOTICES.md THIRD_PARTY_SOURCES.md docs/herdr-compliance.md; do
  assert_present "$ROOT/$path" "source package must preserve $path"
done
[ ! -e "$ROOT/tools/agent-os/skills-lock.json" ] \
  || fail "unlicensed vendored Effect skill lock must not be published"
[ -z "$(find "$ROOT/tools/agent-os/.agents/skills/effect-ts" -type f -print 2>/dev/null)" ] \
  || fail "unlicensed vendored Effect skill files must not be published"

[ "$(git -C "$ROOT" ls-files -s CLAUDE.md | awk '{print $1}')" = "120000" ] \
  || fail "CLAUDE.md must remain a symlink in Git"
[ "$(git -C "$ROOT" ls-files -s .claude/skills | awk '{print $1}')" = "120000" ] \
  || fail ".claude/skills must remain a symlink in Git"
for path in bin/fm-spawn.sh bin/agent-os-container-entrypoint.sh bin/agent-os-source-context.sh tests/fm-backend-zellij-smoke.test.sh; do
  [ "$(git -C "$ROOT" ls-files -s "$path" | awk '{print $1}')" = "100755" ] \
    || fail "executable bit must be preserved for $path"
done

assert_grep 'ARG SOURCE_REPOSITORY=https://github.com/akua-dev/agent-os' "$ROOT/Dockerfile" \
  "Dockerfile must declare the OCI source repository input"
assert_grep 'ARG SOURCE_REVISION' "$ROOT/Dockerfile" "Dockerfile must declare the OCI source revision input"
assert_grep 'ARG SOURCE_VERSION=dev' "$ROOT/Dockerfile" "Dockerfile must declare the OCI source version input"
# shellcheck disable=SC2016 # Match literal Docker ARG references.
assert_grep 'org.opencontainers.image.source=$SOURCE_REPOSITORY' "$ROOT/Dockerfile" "image must carry the OCI source label"
# shellcheck disable=SC2016 # Match literal Docker ARG references.
assert_grep 'org.opencontainers.image.revision=$SOURCE_REVISION' "$ROOT/Dockerfile" "image must carry the OCI revision label"
# shellcheck disable=SC2016 # Match literal Docker ARG references.
assert_grep 'org.opencontainers.image.version=$SOURCE_VERSION' "$ROOT/Dockerfile" "image must carry the OCI version label"
# shellcheck disable=SC2016 # Match literal GitHub expression.
assert_grep 'SOURCE_REVISION=${{ github.sha }}' "$ROOT/.github/workflows/agent-os-image.yml" \
  "image workflow must bind the OCI revision label to the checked-out commit"
# shellcheck disable=SC2016 # Match literal GitHub expression.
assert_grep 'SOURCE_VERSION=${{ steps.metadata.outputs.version }}' "$ROOT/.github/workflows/agent-os-image.yml" \
  "image workflow must bind the OCI version label to metadata-action"
assert_grep 'workflows: ["CI"]' "$ROOT/.github/workflows/agent-os-image.yml" \
  "image publication must run only after the full CI workflow"
assert_grep "github.event.workflow_run.conclusion == 'success'" "$ROOT/.github/workflows/agent-os-image.yml" \
  "image publication must require successful CI"
assert_grep "github.event.workflow_run.event == 'push'" "$ROOT/.github/workflows/agent-os-image.yml" \
  "image publication must reject non-push CI runs"
assert_grep "github.event.workflow_run.head_branch == 'main'" "$ROOT/.github/workflows/agent-os-image.yml" \
  "image publication must require protected main"
# shellcheck disable=SC2016 # Match literal GitHub expression.
assert_grep 'ref: ${{ github.event.workflow_run.head_sha }}' "$ROOT/.github/workflows/agent-os-image.yml" \
  "publication checkout must use the exact CI-approved commit"
# shellcheck disable=SC2016 # Match literal GitHub expression.
assert_grep 'SOURCE_REVISION=${{ github.event.workflow_run.head_sha }}' "$ROOT/.github/workflows/agent-os-image.yml" \
  "published OCI provenance must use the exact CI-approved commit"
assert_grep "github.event_name == 'workflow_run' && 'publish-main'" "$ROOT/.github/workflows/agent-os-image.yml" \
  "protected-main publications must share one canceling concurrency group"
assert_grep 'git fetch --no-tags origin +refs/heads/main:refs/remotes/origin/main' \
  "$ROOT/.github/workflows/agent-os-image.yml" \
  "publication must refresh protected main immediately before publishing"
# shellcheck disable=SC2016 # Match literal shell source.
assert_grep 'current_main=$(git rev-parse refs/remotes/origin/main)' \
  "$ROOT/.github/workflows/agent-os-image.yml" \
  "publication must resolve the current protected-main commit"
# shellcheck disable=SC2016 # Match literal shell source.
assert_grep 'if [ "$CI_HEAD_SHA" != "$current_main" ]; then' "$ROOT/.github/workflows/agent-os-image.yml" \
  "publication must reject an out-of-order stale CI run"
# shellcheck disable=SC2016 # Match literal GitHub expression.
assert_grep 'outputs: type=oci,dest=${{ runner.temp }}/agent-os-image.tar' \
  "$ROOT/.github/workflows/agent-os-image.yml" \
  "publication must stage a verified multi-architecture OCI archive"
assert_grep 'skopeo copy --all --preserve-digests' "$ROOT/.github/workflows/agent-os-image.yml" \
  "publication must copy only the staged OCI archive after the freshness gate"
assert_no_grep 'push: true' "$ROOT/.github/workflows/agent-os-image.yml" \
  "publication must not combine a long build with its registry mutation"
build_line=$(grep -n 'name: Build verified OCI archive' "$ROOT/.github/workflows/agent-os-image.yml" | cut -d: -f1)
freshness_line=$(grep -n 'name: Reject stale protected-main runs' "$ROOT/.github/workflows/agent-os-image.yml" | cut -d: -f1)
publish_line=$(grep -n 'skopeo copy --all --preserve-digests' "$ROOT/.github/workflows/agent-os-image.yml" | head -1 | cut -d: -f1)
[ "$build_line" -lt "$freshness_line" ] && [ "$freshness_line" -lt "$publish_line" ] \
  || fail "protected-main freshness must be checked after build and immediately before publication"
assert_no_grep 'tags: ["v*"]' "$ROOT/.github/workflows/agent-os-image.yml" \
  "arbitrary tag pushes must not trigger publication"
for action in \
  'actions/checkout@df4cb1c069e1874edd31b4311f1884172cec0e10' \
  'actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02' \
  'docker/setup-qemu-action@c7c53464625b32c7a7e944ae62b3e17d2b600130' \
  'docker/setup-buildx-action@8d2750c68a42422c14e847fe6c8ac0403b4cbd6f' \
  'docker/login-action@c94ce9fb468520275223c153574b00df6fe4bcc9' \
  'docker/metadata-action@c299e40c65443455700f0fdfc63efafe5b349051' \
  'docker/build-push-action@10e90e3645eae34f1e60eeb005ba3a3d33f178e8'; do
  assert_grep "$action" "$ROOT/.github/workflows/agent-os-image.yml" \
    "publication actions must be pinned to reviewed full commit SHAs"
done

assert_present "$CONTEXT_TOOL" "clean tracked-file source context tool must exist"
fixture=$(fm_test_tmproot agent-os-source-fixture)
repo="$fixture/repo"
context="$fixture/context"
mkdir -p "$repo"
git -C "$ROOT" archive --format=tar HEAD | tar -xf - -C "$repo"
git -C "$repo" init -q
git -C "$repo" add -A
git -C "$repo" -c user.name='Source Context Test' -c user.email='source-context@example.invalid' commit -qm fixture
mkdir -p "$repo/.pi" "$repo/.codex" "$repo/.claude" "$repo/.grok" "$repo/.opencode" "$repo/data" "$repo/state" "$repo/config"
printf 'secret\n' > "$repo/.pi/credentials.json"
printf 'secret\n' > "$repo/.codex/auth.json"
printf 'secret\n' > "$repo/.claude/credentials.json"
printf 'secret\n' > "$repo/.grok/auth.json"
printf 'secret\n' > "$repo/.opencode/credentials.json"
printf 'private\n' > "$repo/data/captain.md"
printf 'private\n' > "$repo/state/task.meta"
printf 'private\n' > "$repo/config/backend"
AGENT_OS_SOURCE_REPO="$repo" "$CONTEXT_TOOL" "$context" HEAD

for path in \
  .pi/extensions/fm-primary-pi-watch.ts \
  .codex/hooks.json \
  .claude/settings.json \
  .claude/skills \
  .grok/hooks/fm-primary-turnend-guard.json \
  .opencode/plugins/fm-primary-watch-arm.js \
  LICENSE THIRD_PARTY_NOTICES.md THIRD_PARTY_SOURCES.md; do
  [ -e "$context/$path" ] || [ -L "$context/$path" ] || fail "clean tracked context omitted $path"
done
for path in \
  .pi/credentials.json .codex/auth.json .claude/credentials.json .grok/auth.json .opencode/credentials.json \
  data/captain.md state/task.meta config/backend .git; do
  [ ! -e "$context/$path" ] || fail "clean tracked context included untracked/private path: $path"
done
[ "$(readlink "$context/CLAUDE.md")" = "AGENTS.md" ] || fail "clean source context must preserve CLAUDE.md symlink"
[ "$(readlink "$context/.claude/skills")" = "../.agents/skills" ] || fail "clean source context must preserve tracked skill symlink"
[ -x "$context/bin/fm-spawn.sh" ] || fail "clean source context must preserve executable bits"

pass "source closure preserves exact ancestry, clean tracked context, license boundaries, modes, and OCI labels"
