FROM node:24-trixie-slim

ARG TARGETARCH
ARG HERDR_VERSION=0.7.3
ARG KUBECTL_VERSION=1.34.8
ARG GH_VERSION=2.96.0
ARG TREEHOUSE_VERSION=2.0.0
ARG NO_MISTAKES_VERSION=1.34.0
ARG BUN_VERSION=1.3.14
ARG AKUA_VERSION=0.8.25
ARG K9S_VERSION=0.51.0

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
  chmod 0755 /usr/local/bin/kubectl

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

RUN npm install --global \
  @earendil-works/pi-coding-agent@0.80.6 \
  gh-axi@0.1.27 \
  chrome-devtools-axi@0.1.26 \
  lavish-axi@0.1.40 \
  tasks-axi@0.2.2 \
  quota-axi@0.1.5

ENV FM_HOME=/home/agent \
    HOME=/home/agent \
    XDG_CONFIG_HOME=/home/agent/.config \
    XDG_DATA_HOME=/home/agent/.local/share \
    XDG_CACHE_HOME=/home/agent/.cache \
    NPM_CONFIG_PREFIX=/usr/local \
    BUN_INSTALL=/home/agent/.bun \
    CARGO_HOME=/home/agent/.cargo \
    PATH=/home/agent/.local/bin:/home/agent/.bun/bin:/home/agent/.cargo/bin:/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin \
    HERDR_SESSION=default

RUN mkdir -p /home/agent /opt/agent-os /opt/image-usr-local

COPY . /opt/agent-os

RUN install -D -m 0644 /opt/agent-os/THIRD_PARTY_NOTICES.md /usr/share/doc/agent-os/THIRD_PARTY_NOTICES.md \
  && install -D -m 0644 /opt/agent-os/THIRD_PARTY_SOURCES.md /usr/share/doc/agent-os/THIRD_PARTY_SOURCES.md

RUN cd /opt/agent-os/tools/agent-os \
  && bun install --frozen-lockfile --production --ignore-scripts \
  && ln -s /opt/agent-os/tools/agent-os/src/cli.ts /usr/local/bin/agent-os \
  && cp -a /usr/local/. /opt/image-usr-local/

WORKDIR /opt/agent-os
ENTRYPOINT ["/opt/agent-os/bin/agent-os-container-entrypoint.sh"]
