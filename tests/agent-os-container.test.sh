#!/usr/bin/env bash
# Static reproducibility and credential-boundary tests for the Agent OS image.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

assert_grep 'FROM node:24-bookworm-slim' "$ROOT/Dockerfile" "image must pin Node 24 Bookworm"
assert_grep 'ARG HERDR_VERSION=0.7.3' "$ROOT/Dockerfile" "image must pin Herdr 0.7.3"
assert_grep 'ARG KUBECTL_VERSION=1.34.8' "$ROOT/Dockerfile" "image must pin kubectl 1.34.8"
assert_grep 'ARG GH_VERSION=2.96.0' "$ROOT/Dockerfile" "image must pin GitHub CLI 2.96.0"
assert_grep 'ARG TREEHOUSE_VERSION=2.0.0' "$ROOT/Dockerfile" "image must pin treehouse 2.0.0"
assert_grep 'ARG NO_MISTAKES_VERSION=1.34.0' "$ROOT/Dockerfile" "image must pin no-mistakes 1.34.0"
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
assert_grep 'exec herdr server' "$ROOT/bin/agent-os-container-entrypoint.sh" "entrypoint must keep Herdr as PID 1"
assert_grep '.git' "$ROOT/.dockerignore" "git metadata must stay out of the build context"
assert_grep '.pi' "$ROOT/.dockerignore" "Pi credentials must stay out of the build context"
assert_grep '.codex' "$ROOT/.dockerignore" "Codex credentials must stay out of the build context"
assert_grep 'https://github.com/ogulcancelik/herdr/tree/v0.7.3' "$ROOT/THIRD_PARTY_NOTICES.md" \
  "Herdr's exact corresponding source must be named"

bash -n "$ROOT/bin/agent-os-container-entrypoint.sh"
pass "container files pin dependencies and exclude host credentials"
