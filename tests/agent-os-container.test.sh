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
assert_grep '"@akua-dev/sdk": "0.8.24"' "$ROOT/tools/agent-os/package.json" "tool must pin the Akua SDK"
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
assert_grep 'XDG_CONFIG_HOME=/home/agent/.config' "$ROOT/Dockerfile" "image must persist XDG configuration"
assert_grep 'NPM_CONFIG_PREFIX=/usr/local' "$ROOT/Dockerfile" "global npm installs must use persistent /usr/local"
assert_grep 'PATH=/home/agent/.local/bin:/home/agent/.bun/bin:/home/agent/.cargo/bin:/usr/local/bin' "$ROOT/Dockerfile" \
  "persistent tool prefixes must lead PATH"
assert_grep '/opt/image-usr-local' "$ROOT/Dockerfile" "image must retain a seed copy of /usr/local"
assert_grep 'akua-dev/akua/releases/download/v${AKUA_VERSION}' "$ROOT/Dockerfile" "image must install Akua from its release"
assert_grep 'ln -s /opt/agent-os/tools/agent-os/src/cli.ts /usr/local/bin/agent-os' "$ROOT/Dockerfile" \
  "image must expose the Agent OS tool"
assert_grep 'bun install --frozen-lockfile --production --ignore-scripts' "$ROOT/Dockerfile" \
  "image install must not clone development source checkouts"
assert_no_grep 'USER node' "$ROOT/Dockerfile" "Agent OS containers must start as container root"
assert_grep 'exec herdr server' "$ROOT/bin/agent-os-container-entrypoint.sh" "entrypoint must keep Herdr as PID 1"
assert_grep 'setup hooks' "$ROOT/bin/agent-os-container-entrypoint.sh" "entrypoint must install persistent AXI hooks"
assert_grep '.git' "$ROOT/.dockerignore" "git metadata must stay out of the build context"
assert_grep '.pi' "$ROOT/.dockerignore" "Pi credentials must stay out of the build context"
assert_grep '.codex' "$ROOT/.dockerignore" "Codex credentials must stay out of the build context"
assert_grep 'node_modules' "$ROOT/.dockerignore" "host dependencies must stay out of the build context"
assert_grep '.repos' "$ROOT/.dockerignore" "development source checkouts must stay out of the build context"
assert_grep 'https://github.com/ogulcancelik/herdr/tree/v0.7.3' "$ROOT/THIRD_PARTY_NOTICES.md" \
  "Herdr's exact corresponding source must be named"
assert_grep 'https://github.com/akua-dev/akua/tree/v0.8.25' "$ROOT/THIRD_PARTY_NOTICES.md" \
  "Akua's exact source must be named"

bash -n "$ROOT/bin/agent-os-container-entrypoint.sh"
pass "container files pin dependencies and exclude host credentials"
