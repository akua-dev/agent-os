#!/usr/bin/env bash
# Static reproducibility and credential-boundary tests for the Agent OS image.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

assert_grep 'FROM node:24-trixie-slim' "$ROOT/Dockerfile" "image must pin Node 24 Trixie"
assert_grep 'ARG HERDR_VERSION=0.7.3' "$ROOT/Dockerfile" "image must pin Herdr 0.7.3"
assert_grep 'ARG KUBECTL_VERSION=1.34.8' "$ROOT/Dockerfile" "image must pin kubectl 1.34.8"
assert_grep 'ARG GH_VERSION=2.96.0' "$ROOT/Dockerfile" "image must pin GitHub CLI 2.96.0"
assert_grep 'ARG TREEHOUSE_VERSION=2.0.0' "$ROOT/Dockerfile" "image must pin treehouse 2.0.0"
assert_grep 'ARG NO_MISTAKES_VERSION=1.34.0' "$ROOT/Dockerfile" "image must pin no-mistakes 1.34.0"
assert_grep 'ARG BUN_VERSION=1.3.14' "$ROOT/Dockerfile" "image must pin stable Bun 1.3.14"
assert_grep 'ARG AKUA_VERSION=0.8.25' "$ROOT/Dockerfile" "image must pin Akua 0.8.25"
assert_grep 'ARG K9S_VERSION=0.51.0' "$ROOT/Dockerfile" "image must pin K9s 0.51.0"
assert_grep 'sha256sum -c -' "$ROOT/Dockerfile" "downloaded runtime binaries must be checksum verified"
assert_grep '@earendil-works/pi-coding-agent@0.80.6' "$ROOT/Dockerfile" "image must pin Pi 0.80.6"
assert_grep 'gh-axi@0.1.27' "$ROOT/Dockerfile" "image must pin gh-axi 0.1.27"
assert_grep 'chrome-devtools-axi@0.1.26' "$ROOT/Dockerfile" "image must pin chrome-devtools-axi 0.1.26"
assert_grep 'lavish-axi@0.1.40' "$ROOT/Dockerfile" "image must pin lavish-axi 0.1.40"
assert_grep 'tasks-axi@0.2.2' "$ROOT/Dockerfile" "image must pin tasks-axi 0.2.2"
assert_grep 'quota-axi@0.1.5' "$ROOT/Dockerfile" "image must pin quota-axi 0.1.5"
assert_grep 'ripgrep' "$ROOT/Dockerfile" "image must install ripgrep"
assert_grep 'fd-find' "$ROOT/Dockerfile" "image must install fd"
assert_grep 'FM_HOME=/home/agent' "$ROOT/Dockerfile" "image must declare the persistent firstmate home"
assert_grep 'never create or read operational state through repo-relative' "$ROOT/AGENTS.md" \
  "Firstmate must anchor operational state to FM_HOME"
assert_grep 'pass a provider-qualified model id' "$ROOT/.agents/skills/harness-adapters/SKILL.md" \
  "Pi dispatch must preserve the selected provider route"
assert_grep 'XDG_CONFIG_HOME=/home/agent/.config' "$ROOT/Dockerfile" "image must persist XDG configuration"
assert_grep 'NPM_CONFIG_PREFIX=/usr/local' "$ROOT/Dockerfile" "global npm installs must use persistent /usr/local"
assert_grep 'PATH=/home/agent/.local/bin:/home/agent/.bun/bin:/home/agent/.cargo/bin:/usr/local/bin' "$ROOT/Dockerfile" \
  "persistent tool prefixes must lead PATH"
assert_grep '/opt/image-usr-local' "$ROOT/Dockerfile" "image must retain a seed copy of /usr/local"
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
assert_grep '.git' "$ROOT/.dockerignore" "git metadata must stay out of the build context"
assert_grep '.pi' "$ROOT/.dockerignore" "Pi credentials must stay out of the build context"
assert_grep '.codex' "$ROOT/.dockerignore" "Codex credentials must stay out of the build context"
assert_grep 'node_modules' "$ROOT/.dockerignore" "host dependencies must stay out of the build context"
assert_grep '.repos' "$ROOT/.dockerignore" "development source checkouts must stay out of the build context"
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
assert_grep 'Section 13' "$ROOT/docs/herdr-compliance.md" \
  "the Herdr audit must account for the network-interaction clause"
assert_grep 'https://github.com/akua-dev/akua/tree/v0.8.25' "$ROOT/THIRD_PARTY_NOTICES.md" \
  "Akua's exact source must be named"
assert_grep 'https://github.com/derailed/k9s/tree/v0.51.0' "$ROOT/THIRD_PARTY_NOTICES.md" \
  "K9s's exact source must be named"
assert_grep 'ghcr.io/akua-dev/agent-os' "$ROOT/.github/workflows/agent-os-image.yml" \
  "release workflow must publish the image expected by the portable package"
assert_grep 'linux/amd64,linux/arm64' "$ROOT/.github/workflows/agent-os-image.yml" \
  "release workflow must build the two supported container architectures"
assert_grep "push: \${{ github.event_name != 'pull_request' }}" "$ROOT/.github/workflows/agent-os-image.yml" \
  "pull requests must build but never publish images"
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
