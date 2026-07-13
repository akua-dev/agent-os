# Third-party notices

## Node.js base image

The Agent OS image uses the official multi-architecture `node:24-trixie-slim` base image pinned to index digest `sha256:366fdef91728b1b7fa18c84fba63b6e79ed77b7e10cc206878e9705da4d7b169`.
The reviewed Docker Node source revision is <https://github.com/nodejs/docker-node/tree/303e6c3be0be8010403376712d3018fb99809f86>.

## Herdr

The Agent OS image includes an unmodified Herdr 0.7.3 executable as a separate program under AGPL-3.0-or-later.
The image includes Herdr's license at `/usr/share/licenses/herdr/LICENSE`.
The source offer is available in the image at `/usr/share/doc/agent-os/THIRD_PARTY_SOURCES.md` and in this repository at [THIRD_PARTY_SOURCES.md](THIRD_PARTY_SOURCES.md).
The exact upstream source is available at <https://github.com/ogulcancelik/herdr/tree/v0.7.3>.
Agent OS invokes Herdr through its documented CLI and socket interfaces.

## Akua

The Agent OS demo image includes an unmodified Akua 0.8.25 executable as a separate program.
Akua is available under the Apache License 2.0.
The image includes Akua's license at `/usr/share/licenses/akua/LICENSE`.
The exact source is available at <https://github.com/akua-dev/akua/tree/v0.8.25>.
Agent OS invokes Akua through its documented CLI.

## K9s

The Agent OS demo image includes an unmodified K9s 0.51.0 executable as a separate program.
K9s is available under the Apache License 2.0.
The image includes K9s's license at `/usr/share/licenses/k9s/LICENSE`.
The exact source is available at <https://github.com/derailed/k9s/tree/v0.51.0>.

## kubectl

The Agent OS image includes the unmodified kubectl 1.34.8 executable from Kubernetes.
Kubernetes is available under the Apache License 2.0.
The image includes the license at `/usr/share/licenses/kubectl/LICENSE`.
The exact source commit is <https://github.com/kubernetes/kubernetes/tree/1f328c5e9dd683d0c5e69f3d7d58f8371278dec2>.

## GitHub CLI

The Agent OS image includes the unmodified GitHub CLI 2.96.0 executable.
GitHub CLI is available under the MIT License.
The image includes the license at `/usr/share/licenses/gh/LICENSE`.
The exact source commit is <https://github.com/cli/cli/tree/b300f2ec7ec9dc9addc39b2ad88c54097ded7ca0>.

## Bun

The Agent OS image includes the unmodified Bun 1.3.14 executable.
Bun and its bundled components use the licenses recorded in the upstream `LICENSE.md` file.
The image includes that complete license record at `/usr/share/licenses/bun/LICENSE.md`.
The exact source commit is <https://github.com/oven-sh/bun/tree/0d9b296af33f2b851fcbf4df3e9ec89751734ba4>.

## Treehouse

The Agent OS image includes the unmodified Treehouse 2.0.0 executable.
Treehouse is available under the MIT License.
The image includes the license at `/usr/share/licenses/treehouse/LICENSE`.
The exact source commit is <https://github.com/kunchenguid/treehouse/tree/68fa3d2556542add76bf80255787b8625a5041a6>.

## no-mistakes

The Agent OS image includes the unmodified no-mistakes 1.34.0 executable.
no-mistakes is available under the MIT License.
The image includes the license at `/usr/share/licenses/no-mistakes/LICENSE`.
The exact source commit is <https://github.com/kunchenguid/no-mistakes/tree/dc5a80059d3c0f1abbf28f20f43d994b8399bee6>.
