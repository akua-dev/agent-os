#!/usr/bin/env bash
# Static reproducibility and credential-boundary tests for the Agent OS image.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

IMAGE_WORKFLOW="$ROOT/.github/workflows/agent-os-image.yml"

assert_grep 'FROM node:24-trixie-slim@sha256:366fdef91728b1b7fa18c84fba63b6e79ed77b7e10cc206878e9705da4d7b169' \
  "$ROOT/Dockerfile" "image must pin the multi-architecture Node 24 Trixie base"
assert_grep 'sha256:366fdef91728b1b7fa18c84fba63b6e79ed77b7e10cc206878e9705da4d7b169' \
  "$ROOT/THIRD_PARTY_NOTICES.md" "base image provenance must record the reviewed index digest"
assert_grep 'ARG HERDR_VERSION=0.7.3' "$ROOT/Dockerfile" "image must pin Herdr 0.7.3"
assert_grep 'ARG KUBECTL_VERSION=1.34.8' "$ROOT/Dockerfile" "image must pin kubectl 1.34.8"
assert_grep 'ARG GH_VERSION=2.96.0' "$ROOT/Dockerfile" "image must pin GitHub CLI 2.96.0"
assert_grep 'ARG TREEHOUSE_VERSION=2.0.0' "$ROOT/Dockerfile" "image must pin treehouse 2.0.0"
assert_grep 'ARG NO_MISTAKES_VERSION=1.34.0' "$ROOT/Dockerfile" "image must pin no-mistakes 1.34.0"
assert_grep 'ARG BUN_VERSION=1.3.14' "$ROOT/Dockerfile" "image must pin stable Bun 1.3.14"
assert_grep 'ARG AKUA_VERSION=0.8.25' "$ROOT/Dockerfile" "image must pin Akua 0.8.25"
assert_grep 'ARG K9S_VERSION=0.51.0' "$ROOT/Dockerfile" "image must pin K9s 0.51.0"
assert_present "$ROOT/image/debian.sources" "image must commit immutable Debian snapshot inputs"
assert_grep 'snapshot.debian.org/archive/debian/20260624T235959Z' "$ROOT/image/debian.sources" \
  "image must use the reviewed immutable Debian snapshot"
assert_grep 'snapshot.debian.org/archive/debian-security/20260624T235959Z' "$ROOT/image/debian.sources" \
  "image must pin the matching Debian security snapshot"
assert_grep 'debian.sources' "$ROOT/Dockerfile" \
  "image build must install and checksum the committed Debian source input"
assert_present "$ROOT/image/npm/package.json" "image runtime npm dependencies must have a committed manifest"
assert_present "$ROOT/image/npm/package-lock.json" "image runtime npm dependencies must have a committed lockfile"
assert_grep '"lockfileVersion": 3' "$ROOT/image/npm/package-lock.json" \
  "image runtime npm lock must use the reproducible current lock format"
assert_grep '"integrity": "sha512-' "$ROOT/image/npm/package-lock.json" \
  "image runtime npm lock must checksum resolved artifacts"
node - "$ROOT/image/npm/package-lock.json" <<'NODE' || fail "every fetched npm artifact must have committed integrity"
const fs = require("fs");
const lock = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const missing = Object.entries(lock.packages)
  .filter(([, value]) => value.resolved && !value.integrity)
  .map(([name]) => name);
if (missing.length) {
  console.error(`missing npm integrity: ${missing.join(", ")}`);
  process.exit(1);
}
NODE
assert_grep 'npm ci --omit=dev --ignore-scripts' "$ROOT/Dockerfile" \
  "image runtime npm installation must consume only the committed lock"
assert_no_grep 'npm install --global' "$ROOT/Dockerfile" \
  "image build must not resolve mutable global npm dependency graphs"
assert_grep 'sha256sum -c -' "$ROOT/Dockerfile" "downloaded runtime binaries must be checksum verified"
assert_grep '"@earendil-works/pi-coding-agent": "0.80.6"' "$ROOT/image/npm/package.json" "image must pin Pi 0.80.6"
assert_grep '"gh-axi": "0.1.27"' "$ROOT/image/npm/package.json" "image must pin gh-axi 0.1.27"
assert_grep '"chrome-devtools-axi": "0.1.26"' "$ROOT/image/npm/package.json" "image must pin chrome-devtools-axi 0.1.26"
assert_grep '"lavish-axi": "0.1.40"' "$ROOT/image/npm/package.json" "image must pin lavish-axi 0.1.40"
assert_grep '"tasks-axi": "0.2.2"' "$ROOT/image/npm/package.json" "image must pin tasks-axi 0.2.2"
assert_grep '"quota-axi": "0.1.5"' "$ROOT/image/npm/package.json" "image must pin quota-axi 0.1.5"
assert_grep 'ripgrep' "$ROOT/Dockerfile" "image must install ripgrep"
assert_grep 'fd-find' "$ROOT/Dockerfile" "image must install fd"
assert_grep 'FM_HOME=/home/agent' "$ROOT/Dockerfile" "image must declare the persistent firstmate home"
assert_grep 'never create or read operational state through repo-relative' "$ROOT/AGENTS.md" \
  "Firstmate must anchor operational state to FM_HOME"
assert_grep 'pass a provider-qualified model id' "$ROOT/.agents/skills/harness-adapters/SKILL.md" \
  "Pi dispatch must preserve the selected provider route"
assert_grep 'XDG_CONFIG_HOME=/home/agent/.config' "$ROOT/Dockerfile" "image must persist XDG configuration"
assert_grep 'NPM_CONFIG_PREFIX=/home/agent/.local' "$ROOT/Dockerfile" "global npm installs must use the persistent user prefix"
assert_grep 'PATH=/home/agent/.local/bin:/home/agent/.bun/bin:/home/agent/.cargo/bin:/usr/local/bin' "$ROOT/Dockerfile" \
  "persistent tool prefixes must lead PATH"
assert_grep 'agent-os-image-usr-local.manifest.sha256' "$ROOT/Dockerfile" "image must authenticate immutable /usr/local ownership"
assert_no_grep 'mountPath = "/usr/local"' "$ROOT/tools/agent-os/packages/firstmate/package.k" \
  "image-owned /usr/local must not be overlaid by persistent state"
# shellcheck disable=SC2016 # Match the literal Docker build argument reference.
assert_grep 'akua-dev/akua/releases/download/v${AKUA_VERSION}' "$ROOT/Dockerfile" "image must install Akua from its release"
# shellcheck disable=SC2016 # Match the literal Docker build argument reference.
assert_grep 'derailed/k9s/releases/download/v${K9S_VERSION}' "$ROOT/Dockerfile" "image must install K9s from its release"
assert_grep 'ln -s /opt/agent-os/tools/agent-os/src/cli.ts /usr/local/bin/agent-os' "$ROOT/Dockerfile" \
  "image must expose the Agent OS tool"
assert_grep 'bun install --frozen-lockfile --production --ignore-scripts' "$ROOT/Dockerfile" \
  "image install must not clone development source checkouts"
assert_no_grep 'USER node' "$ROOT/Dockerfile" "Agent OS containers must start as container root"
assert_grep 'exec herdr server' "$ROOT/bin/agent-os-container-entrypoint.sh" "entrypoint must keep Herdr as PID 1"
assert_grep 'setup hooks' "$ROOT/bin/agent-os-container-entrypoint.sh" "entrypoint must install persistent AXI hooks"
assert_grep 'agent-os-kubeconfig.sh' "$ROOT/bin/agent-os-container-entrypoint.sh" "entrypoint must prepare in-cluster kubectl access"
assert_grep 'AGENT_OS_TEST_PI_MODEL' "$ROOT/bin/agent-os-container-entrypoint.sh" \
  "test-mode Pods must converge the Pi model policy"
assert_grep 'defaultThinkingLevel' "$ROOT/bin/agent-os-container-entrypoint.sh" \
  "test-mode Pods must also pin direct Pi sessions"
# shellcheck disable=SC2016 # Match literal entrypoint variables.
assert_grep 'ln -sfn -- "$AGENT_OS_PI_AUTH_FILE" "$HOME/.pi/agent/auth.json"' \
  "$ROOT/bin/agent-os-container-entrypoint.sh" \
  "entrypoint must link projected authorization without copying Secret bytes"
assert_no_grep 'cp .*AGENT_OS_PI_AUTH_FILE' "$ROOT/bin/agent-os-container-entrypoint.sh" \
  "entrypoint must never persist projected Secret bytes"
assert_grep 'image: agent-os:dev' "$ROOT/deploy/orbstack/inputs.yaml" \
  "the OrbStack profile must define its local image source"
assert_grep 'imagePullPolicy: Never' "$ROOT/deploy/orbstack/inputs.yaml" \
  "the OrbStack profile must use its local image store"
assert_grep 'rbac: cluster-admin' "$ROOT/deploy/orbstack/inputs.yaml" \
  "the OrbStack profile must make its local-demo grant explicit"
assert_grep 'tokenFile:' "$ROOT/bin/agent-os-kubeconfig.sh" "kubeconfig must follow the projected token file"
assert_no_grep 'set-credentials.*--token' "$ROOT/bin/agent-os-kubeconfig.sh" "kubeconfig must not copy a bearer token"
assert_grep 'automountServiceAccountToken: false' "$ROOT/tools/agent-os/packages/firstmate/crewmate.yaml" \
  "runtime mate template must deny ambient Kubernetes credentials"
assert_grep 'agent-os.dev/crewmate' "$ROOT/tools/agent-os/packages/firstmate/crewmate.yaml" \
  "runtime mate template must use the portable Agent OS label"
assert_grep 'AGENT_OS_CREWMATE_TEMPLATE' "$ROOT/bin/agent-os-crewmate.sh" \
  "mate runtime must render the canonical package template"
assert_absent "$ROOT/tools/agent-os/packages/mate/package.k" \
  "mate creation must not remain a separately installable package"
assert_grep '**' "$ROOT/.dockerignore" "the Docker context must default-deny every local path"
assert_grep '!image/agent-os-source.tar' "$ROOT/.dockerignore" "the Docker context must admit only the tracked source export"
assert_grep '!image/agent-os-bootstrap.tar' "$ROOT/.dockerignore" "the Docker context must admit only the shallow bootstrap export"
assert_no_grep '!.pi/' "$ROOT/.dockerignore" "local harness homes must never be admitted directly"
assert_grep 'agent-os-source.tar' "$ROOT/Dockerfile" "image must consume the tracked exact-source export"
assert_grep 'agent-os-bootstrap.tar' "$ROOT/Dockerfile" "image must consume the shallow sanitized bootstrap"
assert_grep 'rev-parse "$AGENT_OS_SOURCE_COMMIT^{tree}"' "$ROOT/Dockerfile" "image source bootstrap must verify its exact tree"
assert_grep 'cmp /tmp/verified-source.tar /tmp/agent-os-source.tar' "$ROOT/Dockerfile" \
  "image source must be byte-identical to the archive materialized from the verified commit"
assert_grep 'AS source-bootstrap' "$ROOT/Dockerfile" "source processing must stay in an isolated build stage"
assert_no_grep 'COPY \. /opt/agent-os' "$ROOT/Dockerfile" "the image must never copy the ambient workspace"
assert_grep 'fetch --depth=1 --no-tags' "$ROOT/bin/agent-os-source-bundle.sh" \
  "source preparation must fetch an allowlisted remote ref freshly"
assert_grep 'GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null' "$ROOT/bin/agent-os-source-bundle.sh" \
  "source preparation must isolate trusted Git operations from ambient configuration"
assert_grep 'AGENT_OS_SOURCE_MODE=event AGENT_OS_SOURCE_EVENT_COMMIT' "$IMAGE_WORKFLOW" \
  "pull requests must build their exact event head without publication credentials"
assert_no_grep 'git clone --depth=1 --branch main' "$IMAGE_WORKFLOW" \
  "pull-request validation must not substitute protected main for the reviewed source"
assert_grep 'release-record-commit=' "$IMAGE_WORKFLOW" \
  "historical releases must name an immutable allowlisted release record"
assert_grep 'tag_ruleset_sha256' "$ROOT/bin/agent-os-source-bundle.sh" \
  "release records must bind the protected tag ruleset"
assert_grep 'source_archive_sha256' "$ROOT/bin/agent-os-source-bundle.sh" \
  "release records must bind the exact archived source"
assert_grep 'GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null' "$ROOT/bin/agent-os-container-entrypoint.sh" \
  "runtime provenance must isolate trusted Git operations"
assert_grep 'canonical FM_ROOT Git config contains untrusted' "$ROOT/bin/agent-os-container-entrypoint.sh" \
  "runtime provenance must reject persistent transport and execution overrides"
assert_grep 'status --porcelain --untracked-files=all' "$ROOT/bin/agent-os-source-bundle.sh" \
  "source preparation must reject a dirty workspace"
assert_no_grep 'bundle create.*HEAD' "$ROOT/bin/agent-os-source-bundle.sh" \
  "source bootstrap must not retain reachable deleted history"
assert_grep 'merge --ff-only' "$ROOT/bin/agent-os-container-entrypoint.sh" "persistent source transitions must be fast-forward only"
assert_grep 'refs/remotes/agent-os-verified' "$ROOT/bin/agent-os-container-entrypoint.sh" \
  "canonical runtime source must use a freshly fetched verification ref"
assert_grep 'trusted_git -C "$FM_ROOT" fetch --no-tags --prune "$SOURCE_ORIGIN"' "$ROOT/bin/agent-os-container-entrypoint.sh" \
  "runtime provenance must fail closed unless the trusted remote is reachable"
assert_no_grep 'checkout --detach' "$ROOT/bin/agent-os-container-entrypoint.sh" \
  "canonical runtime source must remain on the declared default branch"
assert_grep 'FM_ROOT_OVERRIDE=' "$ROOT/bin/agent-os-container-entrypoint.sh" "runtime must use the persistent canonical Firstmate repository"
assert_grep 'agent-os-kubernetes-control.sh' "$ROOT/bin/agent-os-kubernetes.sh" \
  "primary lifecycle paths must share the stable control-namespace lock identity"
assert_grep 'agent-os-kubernetes-control.sh' "$ROOT/bin/agent-os-akua-auth.sh" \
  "authorization mutations must share the stable control-namespace lock identity"
assert_grep 'require_no_active_rollback_checkpoint' "$ROOT/bin/agent-os-akua-auth.sh" \
  "authorization mutations must reject unresolved rollback checkpoints"
auth_lock_line=$(grep -n '^acquire_lock$' "$ROOT/bin/agent-os-akua-auth.sh" | tail -n 1 | cut -d: -f1)
auth_secret_line=$(grep -n '^SECRET_RECORD=' "$ROOT/bin/agent-os-akua-auth.sh" | cut -d: -f1)
[ -n "$auth_lock_line" ] && [ -n "$auth_secret_line" ] && [ "$auth_lock_line" -lt "$auth_secret_line" ] || \
  fail "authorization mutation must acquire the control lock before Secret metadata"
assert_grep 'https://github.com/ogulcancelik/herdr/tree/v0.7.3' "$ROOT/THIRD_PARTY_NOTICES.md" \
  "Herdr's exact corresponding source must be named"
assert_present "$ROOT/THIRD_PARTY_SOURCES.md" \
  "the image must ship an operator-visible Herdr source offer"
assert_present "$ROOT/docs/herdr-compliance.md" \
  "the repository must record the Herdr distribution boundary"
assert_grep '299dd4163a96381ec2d8e5bde13d7ba6d6432373' "$ROOT/THIRD_PARTY_SOURCES.md" \
  "the Herdr source offer must pin the v0.7.3 commit"
assert_grep '4e4a536fff8cd74019a1f8b4f1eef7fce556042f2b3e389eb6f9a155c1a7c6d5' "$ROOT/THIRD_PARTY_SOURCES.md" \
  "the Herdr source offer must checksum the source archive"
assert_grep 'cargo build --release' "$ROOT/THIRD_PARTY_SOURCES.md" \
  "the Herdr source offer must name its build command"
assert_grep 'unmodified executable' "$ROOT/THIRD_PARTY_SOURCES.md" \
  "the Herdr source offer must state the modification boundary"
assert_grep 'install -D -m 0644 /opt/agent-os/THIRD_PARTY_NOTICES.md /usr/share/doc/agent-os/THIRD_PARTY_NOTICES.md' "$ROOT/Dockerfile" \
  "the image must expose third-party notices to operators"
assert_grep 'install -D -m 0644 /opt/agent-os/THIRD_PARTY_SOURCES.md /usr/share/doc/agent-os/THIRD_PARTY_SOURCES.md' "$ROOT/Dockerfile" \
  "the image must expose Herdr's source offer to operators"
assert_grep '/usr/share/doc/agent-os/THIRD_PARTY_SOURCES.md' "$ROOT/THIRD_PARTY_NOTICES.md" \
  "the Herdr notice must direct image recipients to the bundled source offer"
assert_no_grep 'publication is gated on a compliant license path' "$ROOT/THIRD_PARTY_NOTICES.md" \
  "the Herdr notice must state the selected compliance path"
if grep -Eq '^  packages: write$' "$IMAGE_WORKFLOW"; then
  fail "workflow defaults must keep pull-request validation read-only"
fi
[ "$(grep -c '^      packages: write$' "$IMAGE_WORKFLOW")" -eq 1 ] || \
  fail "only the protected publication job may receive packages write"
assert_grep '  validate:' "$IMAGE_WORKFLOW" \
  "pull requests must use a distinct read-only validation job"
assert_grep '  publish:' "$IMAGE_WORKFLOW" \
  "push and tag publication must use a distinct privileged job"
assert_grep 'needs: [behavior, provenance, validate]' "$IMAGE_WORKFLOW" \
  "the packages-write job must require exact behavior, provenance, and image gates"
assert_grep 'github.ref_protected' "$IMAGE_WORKFLOW" \
  "main publication must require GitHub protected-ref provenance"
assert_grep 'release tag ruleset differs from immutable record' "$IMAGE_WORKFLOW" \
  "tag publication must require its recorded protected-tag ruleset"
assert_grep 'Section 13' "$ROOT/docs/herdr-compliance.md" \
  "the Herdr audit must account for the network-interaction clause"
assert_grep 'https://github.com/akua-dev/akua/tree/v0.8.25' "$ROOT/THIRD_PARTY_NOTICES.md" \
  "Akua's exact source must be named"
assert_grep 'https://github.com/derailed/k9s/tree/v0.51.0' "$ROOT/THIRD_PARTY_NOTICES.md" \
  "K9s's exact source must be named"
assert_grep '1f328c5e9dd683d0c5e69f3d7d58f8371278dec2/LICENSE' "$ROOT/Dockerfile" \
  "the image must bundle kubectl's license from the immutable Kubernetes source commit"
assert_grep 'b300f2ec7ec9dc9addc39b2ad88c54097ded7ca0/LICENSE' "$ROOT/Dockerfile" \
  "the image must bundle GitHub CLI's license from its immutable source commit"
assert_grep '0d9b296af33f2b851fcbf4df3e9ec89751734ba4/LICENSE.md' "$ROOT/Dockerfile" \
  "the image must bundle Bun's complete license from its immutable source commit"
assert_grep '68fa3d2556542add76bf80255787b8625a5041a6/LICENSE' "$ROOT/Dockerfile" \
  "the image must bundle Treehouse's license from its immutable source commit"
assert_grep 'dc5a80059d3c0f1abbf28f20f43d994b8399bee6/LICENSE' "$ROOT/Dockerfile" \
  "the image must bundle no-mistakes' license from its immutable source commit"
assert_grep '/usr/share/licenses/kubectl/LICENSE' "$ROOT/Dockerfile" \
  "kubectl's license must be installed in the image license bundle"
assert_grep '/usr/share/licenses/gh/LICENSE' "$ROOT/Dockerfile" \
  "GitHub CLI's license must be installed in the image license bundle"
assert_grep '/usr/share/licenses/bun/LICENSE.md' "$ROOT/Dockerfile" \
  "Bun's complete license must be installed in the image license bundle"
assert_grep '/usr/share/licenses/treehouse/LICENSE' "$ROOT/Dockerfile" \
  "Treehouse's license must be installed in the image license bundle"
assert_grep '/usr/share/licenses/no-mistakes/LICENSE' "$ROOT/Dockerfile" \
  "no-mistakes' license must be installed in the image license bundle"
assert_grep '## kubectl' "$ROOT/THIRD_PARTY_NOTICES.md" "third-party notices must cover kubectl"
assert_grep '## GitHub CLI' "$ROOT/THIRD_PARTY_NOTICES.md" "third-party notices must cover GitHub CLI"
assert_grep '## Bun' "$ROOT/THIRD_PARTY_NOTICES.md" "third-party notices must cover Bun"
assert_grep '## Treehouse' "$ROOT/THIRD_PARTY_NOTICES.md" "third-party notices must cover Treehouse"
assert_grep '## no-mistakes' "$ROOT/THIRD_PARTY_NOTICES.md" "third-party notices must cover no-mistakes"
assert_grep 'actions/checkout@df4cb1c069e1874edd31b4311f1884172cec0e10' "$ROOT/.github/workflows/ci.yml" \
  "CI checkout actions must be pinned to the reviewed full SHA"
assert_grep 'oven-sh/setup-bun@0c5077e51419868618aeaa5fe8019c62421857d6' "$ROOT/.github/workflows/ci.yml" \
  "CI must pin Bun setup to a reviewed full SHA"
assert_grep 'bun-version-file: tools/agent-os/.bun-version' "$ROOT/.github/workflows/ci.yml" \
  "CI must use the repository-pinned Bun version"
assert_grep 'bun run check' "$ROOT/.github/workflows/ci.yml" \
  "CI behavior tests must execute the Agent OS tool check"
assert_grep "mkdir -p \"\$RUNNER_TEMP/bin\"" "$ROOT/.github/workflows/ci.yml" \
  "CI must create its local verified-tool destination before install"
assert_grep 'bc57afbffe7e18aacd2146e2cd67151c56e7a3c279fe659312ff7ffb359cd03a' "$ROOT/.github/workflows/ci.yml" \
  "CI must authenticate the x86_64 Akua release artifact"
assert_grep '3a3c6bae72764cbd85a6e4e0877a05e5def8f7aeee8563b7918099214a1a313a' "$ROOT/.github/workflows/ci.yml" \
  "CI must authenticate the aarch64 Akua release artifact"
assert_no_grep 'https://cli.akua.dev/install' "$ROOT/.github/workflows/ci.yml" \
  "CI must not execute the mutable remote Akua installer"
assert_grep 'ghcr.io/akua-dev/agent-os' "$ROOT/.github/workflows/agent-os-image.yml" \
  "release workflow must publish the image expected by the portable package"
assert_grep 'linux/amd64,linux/arm64' "$ROOT/.github/workflows/agent-os-image.yml" \
  "release workflow must build the two supported container architectures"
[ "$(grep -c '^          push: false$' "$IMAGE_WORKFLOW")" -eq 1 ] || \
  fail "the read-only pull-request job must build without publishing"
[ "$(grep -c '^          push: true$' "$IMAGE_WORKFLOW")" -eq 1 ] || \
  fail "only the protected publication job may push images"
assert_grep 'id: build' "$ROOT/.github/workflows/agent-os-image.yml" \
  "release workflow must expose its build result"
assert_grep 'steps.build.outputs.digest' "$ROOT/.github/workflows/agent-os-image.yml" \
  "release workflow must record the immutable published digest"
assert_grep 'actions/checkout@df4cb1c069e1874edd31b4311f1884172cec0e10' "$ROOT/.github/workflows/agent-os-image.yml" \
  "release checkout action must be pinned to the reviewed full SHA"
assert_grep 'docker/setup-qemu-action@c7c53464625b32c7a7e944ae62b3e17d2b600130' "$ROOT/.github/workflows/agent-os-image.yml" \
  "release QEMU action must be pinned to the reviewed full SHA"
assert_grep 'docker/setup-buildx-action@8d2750c68a42422c14e847fe6c8ac0403b4cbd6f' "$ROOT/.github/workflows/agent-os-image.yml" \
  "release Buildx action must be pinned to the reviewed full SHA"
assert_grep 'docker/login-action@c94ce9fb468520275223c153574b00df6fe4bcc9' "$ROOT/.github/workflows/agent-os-image.yml" \
  "release login action must be pinned to the reviewed full SHA"
assert_grep 'docker/metadata-action@c299e40c65443455700f0fdfc63efafe5b349051' "$ROOT/.github/workflows/agent-os-image.yml" \
  "release metadata action must be pinned to the reviewed full SHA"
assert_grep 'docker/build-push-action@10e90e3645eae34f1e60eeb005ba3a3d33f178e8' "$ROOT/.github/workflows/agent-os-image.yml" \
  "release build action must be pinned to the reviewed full SHA"
if grep -E 'uses: (actions/checkout|docker/[^@]+)@v[0-9]+' "$ROOT/.github/workflows/agent-os-image.yml" >/dev/null; then
  fail "release workflow must not use mutable major action tags"
fi
bash -n "$ROOT/bin/agent-os-container-entrypoint.sh"
bash -n "$ROOT/bin/agent-os-kubeconfig.sh"
pass "container files pin dependencies and exclude host credentials"
