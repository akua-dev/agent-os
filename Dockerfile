FROM node:24-trixie-slim@sha256:366fdef91728b1b7fa18c84fba63b6e79ed77b7e10cc206878e9705da4d7b169

ARG TARGETARCH
ARG HERDR_VERSION=0.7.3
ARG KUBECTL_VERSION=1.34.8
ARG GH_VERSION=2.96.0
ARG TREEHOUSE_VERSION=2.0.0
ARG NO_MISTAKES_VERSION=1.34.0
ARG BUN_VERSION=1.3.14
ARG AKUA_VERSION=0.8.25
ARG K9S_VERSION=0.51.0
ARG AGENT_OS_SOURCE_COMMIT
ARG AGENT_OS_SOURCE_TREE
ARG AGENT_OS_SOURCE_ORIGIN=https://github.com/akua-dev/agent-os.git

COPY image/debian.sources /etc/apt/sources.list.d/debian.sources

RUN echo "9767ac71230276e282fdb39a087c889a277835b47751a0c0e5a9da0e8352e289  /etc/apt/sources.list.d/debian.sources" | sha256sum -c -

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    curl \
    fd-find \
    git \
    jq \
    openssh-client \
    procps \
    ripgrep \
    rsync \
    tmux \
    unzip \
  && ln -s /usr/bin/fdfind /usr/local/bin/fd \
  && rm -rf /var/lib/apt/lists/*

RUN set -eu; \
  case "$TARGETARCH" in \
    amd64) asset=herdr-linux-x86_64; sha=043ef43ecbabda28465dcff1eec3184518150d567b8b8f20cda9c6c88770641d ;; \
    arm64) asset=herdr-linux-aarch64; sha=ea490094f2c7c39099870857d00c64c628ef7b5eba1967df4258033455ee2cb1 ;; \
    *) echo "unsupported TARGETARCH: $TARGETARCH" >&2; exit 1 ;; \
  esac; \
  curl -fsSL "https://github.com/ogulcancelik/herdr/releases/download/v${HERDR_VERSION}/${asset}" -o /usr/local/bin/herdr; \
  echo "$sha  /usr/local/bin/herdr" | sha256sum -c -; \
  chmod 0755 /usr/local/bin/herdr; \
  mkdir -p /usr/share/licenses/herdr; \
  curl -fsSL "https://raw.githubusercontent.com/ogulcancelik/herdr/v${HERDR_VERSION}/LICENSE" -o /usr/share/licenses/herdr/LICENSE

RUN set -eu; \
  case "$TARGETARCH" in \
    amd64) sha=f6249132865c13abe3c9dd5038f5da65849cb86eee1608c001831504e481aa8c ;; \
    arm64) sha=4c9fe1f717738950c638c38056130a8db5075e6413ae36d8687221a240cdf88b ;; \
    *) echo "unsupported TARGETARCH: $TARGETARCH" >&2; exit 1 ;; \
  esac; \
  curl -fsSL "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" -o /usr/local/bin/kubectl; \
  echo "$sha  /usr/local/bin/kubectl" | sha256sum -c -; \
  chmod 0755 /usr/local/bin/kubectl; \
  mkdir -p /usr/share/licenses/kubectl; \
  curl -fsSL "https://raw.githubusercontent.com/kubernetes/kubernetes/1f328c5e9dd683d0c5e69f3d7d58f8371278dec2/LICENSE" -o /usr/share/licenses/kubectl/LICENSE; \
  echo "cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30  /usr/share/licenses/kubectl/LICENSE" | sha256sum -c -

RUN set -eu; \
  case "$TARGETARCH" in \
    amd64) sha=83d5c2ccad5498f58bf6368acb1ab32588cf43ab3a4b1c301bf36328b1c8bd60 ;; \
    arm64) sha=06f86ec7103d41993b76cd78072f43595c34aaa56506d971d9860e67140bf909 ;; \
    *) echo "unsupported TARGETARCH: $TARGETARCH" >&2; exit 1 ;; \
  esac; \
  asset="gh_${GH_VERSION}_linux_${TARGETARCH}.tar.gz"; \
  curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/${asset}" -o "/tmp/${asset}"; \
  echo "$sha  /tmp/${asset}" | sha256sum -c -; \
  tar -xzf "/tmp/${asset}" -C /tmp; \
  install -m 0755 "/tmp/gh_${GH_VERSION}_linux_${TARGETARCH}/bin/gh" /usr/local/bin/gh; \
  mkdir -p /usr/share/licenses/gh; \
  curl -fsSL "https://raw.githubusercontent.com/cli/cli/b300f2ec7ec9dc9addc39b2ad88c54097ded7ca0/LICENSE" -o /usr/share/licenses/gh/LICENSE; \
  echo "6da4adc42392c8485e40b4251c7e332fc3352df1947c9ffade71dd60b14a7a4f  /usr/share/licenses/gh/LICENSE" | sha256sum -c -; \
  rm -rf "/tmp/${asset}" "/tmp/gh_${GH_VERSION}_linux_${TARGETARCH}"

RUN set -eu; \
  case "$TARGETARCH" in \
    amd64) treehouse_sha=b7926c19633ee94582b7f1b58369f22b304ae7228a47253c2148e3a8176f03b0; no_mistakes_sha=449d0276e1b35369ea332dae0eddb5be326c2d4fc9643270af98858cf3906536 ;; \
    arm64) treehouse_sha=91bca451bab84df685ee17975c8a9d8cf671b3e95c96b7fc6ff0121ea0aae991; no_mistakes_sha=f157df3e18350edea8abdaa065681bd115a9d321fca86f51e9a0184b3a9d8756 ;; \
    *) echo "unsupported TARGETARCH: $TARGETARCH" >&2; exit 1 ;; \
  esac; \
  treehouse_asset="treehouse-v${TREEHOUSE_VERSION}-linux-${TARGETARCH}.tar.gz"; \
  curl -fsSL "https://github.com/kunchenguid/treehouse/releases/download/v${TREEHOUSE_VERSION}/${treehouse_asset}" -o "/tmp/${treehouse_asset}"; \
  echo "$treehouse_sha  /tmp/${treehouse_asset}" | sha256sum -c -; \
  tar -xzf "/tmp/${treehouse_asset}" -C /usr/local/bin; \
  no_mistakes_asset="no-mistakes-v${NO_MISTAKES_VERSION}-linux-${TARGETARCH}.tar.gz"; \
  curl -fsSL "https://github.com/kunchenguid/no-mistakes/releases/download/v${NO_MISTAKES_VERSION}/${no_mistakes_asset}" -o "/tmp/${no_mistakes_asset}"; \
  echo "$no_mistakes_sha  /tmp/${no_mistakes_asset}" | sha256sum -c -; \
  tar -xzf "/tmp/${no_mistakes_asset}" -C /usr/local/bin; \
  chmod 0755 /usr/local/bin/treehouse /usr/local/bin/no-mistakes; \
  mkdir -p /usr/share/licenses/treehouse /usr/share/licenses/no-mistakes; \
  curl -fsSL "https://raw.githubusercontent.com/kunchenguid/treehouse/68fa3d2556542add76bf80255787b8625a5041a6/LICENSE" -o /usr/share/licenses/treehouse/LICENSE; \
  echo "1b962d20f826f6a758c737f8aa4e8e76dc719b8aa78fcfacdfb46681bb36c2f4  /usr/share/licenses/treehouse/LICENSE" | sha256sum -c -; \
  curl -fsSL "https://raw.githubusercontent.com/kunchenguid/no-mistakes/dc5a80059d3c0f1abbf28f20f43d994b8399bee6/LICENSE" -o /usr/share/licenses/no-mistakes/LICENSE; \
  echo "945016bd37e1ba7211622ef60ee1d23ab727896ba7710edd21e8fbe983863969  /usr/share/licenses/no-mistakes/LICENSE" | sha256sum -c -; \
  rm -f "/tmp/${treehouse_asset}" "/tmp/${no_mistakes_asset}"

RUN set -eu; \
  case "$TARGETARCH" in \
    amd64) bun_arch=x64; sha=951ee2aee855f08595aeec6225226a298d3fea83a3dcd6465c09cbccdf7e848f ;; \
    arm64) bun_arch=aarch64; sha=a27ffb63a8310375836e0d6f668ae17fa8d8d18b88c37c821c65331973a19a3b ;; \
    *) echo "unsupported TARGETARCH: $TARGETARCH" >&2; exit 1 ;; \
  esac; \
  asset="bun-linux-${bun_arch}.zip"; \
  curl -fsSL "https://github.com/oven-sh/bun/releases/download/bun-v${BUN_VERSION}/${asset}" -o "/tmp/${asset}"; \
  echo "$sha  /tmp/${asset}" | sha256sum -c -; \
  unzip -q "/tmp/${asset}" -d /tmp/bun; \
  install -m 0755 "/tmp/bun/bun-linux-${bun_arch}/bun" /usr/local/bin/bun; \
  mkdir -p /usr/share/licenses/bun; \
  curl -fsSL "https://raw.githubusercontent.com/oven-sh/bun/0d9b296af33f2b851fcbf4df3e9ec89751734ba4/LICENSE.md" -o /usr/share/licenses/bun/LICENSE.md; \
  echo "2c6160ec8fb853f7e8f97d9b249e756c9b0ac44860a68b6bf4f1b0bcbc5c3741  /usr/share/licenses/bun/LICENSE.md" | sha256sum -c -; \
  rm -rf "/tmp/${asset}" /tmp/bun

RUN set -eu; \
  case "$TARGETARCH" in \
    amd64) triple=x86_64-unknown-linux-gnu; sha=bc57afbffe7e18aacd2146e2cd67151c56e7a3c279fe659312ff7ffb359cd03a ;; \
    arm64) triple=aarch64-unknown-linux-gnu; sha=3a3c6bae72764cbd85a6e4e0877a05e5def8f7aeee8563b7918099214a1a313a ;; \
    *) echo "unsupported TARGETARCH: $TARGETARCH" >&2; exit 1 ;; \
  esac; \
  asset="akua-v${AKUA_VERSION}-${triple}.tar.gz"; \
  curl -fsSL "https://github.com/akua-dev/akua/releases/download/v${AKUA_VERSION}/${asset}" -o "/tmp/${asset}"; \
  echo "$sha  /tmp/${asset}" | sha256sum -c -; \
  tar -xzf "/tmp/${asset}" -C /tmp; \
  install -m 0755 /tmp/akua /usr/local/bin/akua; \
  rm -f "/tmp/${asset}" /tmp/akua; \
  mkdir -p /usr/share/licenses/akua; \
  curl -fsSL "https://raw.githubusercontent.com/akua-dev/akua/v${AKUA_VERSION}/LICENSE" -o /usr/share/licenses/akua/LICENSE

RUN set -eu; \
  case "$TARGETARCH" in \
    amd64) sha=c3752ad51a5a4015a113819c4eeb6e55a4d0e4b8e652494797532f6fc8161dd7 ;; \
    arm64) sha=3ee05c82e5f9198928a4e86133608ba6a2c10a2244d6a7789e820f78319d640c ;; \
    *) echo "unsupported TARGETARCH: $TARGETARCH" >&2; exit 1 ;; \
  esac; \
  asset="k9s_Linux_${TARGETARCH}.tar.gz"; \
  curl -fsSL "https://github.com/derailed/k9s/releases/download/v${K9S_VERSION}/${asset}" -o "/tmp/${asset}"; \
  echo "$sha  /tmp/${asset}" | sha256sum -c -; \
  tar -xzf "/tmp/${asset}" -C /tmp k9s; \
  install -m 0755 /tmp/k9s /usr/local/bin/k9s; \
  rm -f "/tmp/${asset}" /tmp/k9s; \
  mkdir -p /usr/share/licenses/k9s; \
  curl -fsSL "https://raw.githubusercontent.com/derailed/k9s/v${K9S_VERSION}/LICENSE" -o /usr/share/licenses/k9s/LICENSE

COPY image/npm/package.json image/npm/package-lock.json /opt/agent-os-npm/

RUN echo "3646e31389155fbce155c828d8db46bc60ff2976c2d8d29e6633f260f56fd06d  /opt/agent-os-npm/package.json" | sha256sum -c - \
  && echo "f77f31c67455d6f72e6411d5fa82669b9cc95306d518ff655b7c7795cfd41ca2  /opt/agent-os-npm/package-lock.json" | sha256sum -c - \
  && npm ci --omit=dev --ignore-scripts --no-audit --no-fund --prefix /opt/agent-os-npm \
  && mkdir -p /usr/local/lib/node_modules \
  && cp -a /opt/agent-os-npm/node_modules/. /usr/local/lib/node_modules/ \
  && for command in pi gh-axi chrome-devtools-axi lavish-axi tasks-axi quota-axi; do \
    ln -s "/usr/local/lib/node_modules/.bin/$command" "/usr/local/bin/$command"; \
  done \
  && rm -rf /opt/agent-os-npm

ENV FM_HOME=/home/agent \
    HOME=/home/agent \
    XDG_CONFIG_HOME=/home/agent/.config \
    XDG_DATA_HOME=/home/agent/.local/share \
    XDG_CACHE_HOME=/home/agent/.cache \
    NPM_CONFIG_PREFIX=/home/agent/.local \
    BUN_INSTALL=/home/agent/.bun \
    CARGO_HOME=/home/agent/.cargo \
    PATH=/home/agent/.local/bin:/home/agent/.bun/bin:/home/agent/.cargo/bin:/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin \
    HERDR_SESSION=default

RUN mkdir -p /home/agent /opt/agent-os

COPY . /opt/agent-os
COPY image/agent-os-source.bundle /opt/agent-os-source.bundle

RUN set -eu; \
  test -n "$AGENT_OS_SOURCE_COMMIT"; \
  test -n "$AGENT_OS_SOURCE_TREE"; \
  git bundle verify /opt/agent-os-source.bundle; \
  git clone --no-local /opt/agent-os-source.bundle /opt/agent-os-bootstrap; \
  git -C /opt/agent-os-bootstrap checkout --detach "$AGENT_OS_SOURCE_COMMIT"; \
  test "$(git -C /opt/agent-os-bootstrap rev-parse HEAD)" = "$AGENT_OS_SOURCE_COMMIT"; \
  test "$(git -C /opt/agent-os-bootstrap rev-parse HEAD^{tree})" = "$AGENT_OS_SOURCE_TREE"; \
  test -z "$(git -C /opt/agent-os-bootstrap status --porcelain)"; \
  test -z "$(git -C /opt/agent-os-bootstrap ls-files -- config data projects state .no-mistakes)"; \
  rm -rf /opt/agent-os-bootstrap/.git/hooks; \
  git -C /opt/agent-os-bootstrap remote set-url origin "$AGENT_OS_SOURCE_ORIGIN"; \
  test "$(git -C /opt/agent-os-bootstrap remote get-url origin)" = "$AGENT_OS_SOURCE_ORIGIN"; \
  printf '%s\n' "$AGENT_OS_SOURCE_COMMIT" > /opt/agent-os-source.commit; \
  printf '%s\n' "$AGENT_OS_SOURCE_TREE" > /opt/agent-os-source.tree; \
  printf '%s\n' "$AGENT_OS_SOURCE_ORIGIN" > /opt/agent-os-source.origin

RUN install -D -m 0644 /opt/agent-os/THIRD_PARTY_NOTICES.md /usr/share/doc/agent-os/THIRD_PARTY_NOTICES.md \
  && install -D -m 0644 /opt/agent-os/THIRD_PARTY_SOURCES.md /usr/share/doc/agent-os/THIRD_PARTY_SOURCES.md

RUN cd /opt/agent-os/tools/agent-os \
  && bun install --frozen-lockfile --production --ignore-scripts \
  && ln -s /opt/agent-os/tools/agent-os/src/cli.ts /usr/local/bin/agent-os \
  && cd /usr/local \
  && find . \( -type f -o -type l \) -print | LC_ALL=C sort | while IFS= read -r path; do sha256sum "$path"; done > /opt/agent-os-image-usr-local.manifest \
  && cd /opt \
  && sha256sum agent-os-image-usr-local.manifest > agent-os-image-usr-local.manifest.sha256

WORKDIR /home/agent/firstmate
ENTRYPOINT ["/opt/agent-os/bin/agent-os-container-entrypoint.sh"]
